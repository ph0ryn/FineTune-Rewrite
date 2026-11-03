#include "AudioDSP/Pipeline.hpp"
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <limits>
#include <numbers>

namespace finetune::dsp {
namespace {
bool overlaps(InputBuffer input, OutputBuffer output) noexcept {
    if (!input.data || !output.data || input.frames == 0 || output.frames == 0) {
        return false;
    }
    const auto source = reinterpret_cast<std::uintptr_t>(input.data);
    const auto destination = reinterpret_cast<std::uintptr_t>(output.data);
    const auto sourceBytes =
        static_cast<std::uint64_t>(input.frames) * input.channels * sizeof(float);
    const auto destinationBytes =
        static_cast<std::uint64_t>(output.frames) * output.channels * sizeof(float);
    if (sourceBytes > std::numeric_limits<std::uintptr_t>::max() - source ||
        destinationBytes > std::numeric_limits<std::uintptr_t>::max() - destination) {
        return true;
    }
    if (source == destination && input.channels == output.channels) {
        return false;
    }
    return source < destination + destinationBytes && destination < source + sourceBytes;
}
void silence(OutputBuffer output) noexcept {
    if (output.frames != 0) {
        std::fill_n(output.data, static_cast<std::size_t>(output.frames) * output.channels, 0.0F);
    }
}
bool validParameters(RouteParameters p) noexcept {
    return std::isfinite(p.targetGain) && p.targetGain >= 0 && std::isfinite(p.crossfade) &&
           p.crossfade >= 0 && p.crossfade <= 1 && std::isfinite(p.outputGate) &&
           p.outputGate >= 0 && p.outputGate <= 1 && std::isfinite(p.rampCoefficient) &&
           p.rampCoefficient >= 0 && p.rampCoefficient <= 1;
}
} // namespace

Status RoutePipeline::mapAndGain(InputBuffer input, OutputBuffer output,
                                 RouteParameters p) noexcept {
    if (input.channels == 0 || input.channels > maxChannels || output.channels == 0 ||
        output.channels > maxChannels || (input.frames != 0 && !input.data) ||
        (output.frames != 0 && !output.data) || !validParameters(p) || overlaps(input, output)) {
        return Status::invalidArgument;
    }
    const auto frames = std::min(input.frames, output.frames);
    if (frames == 0) {
        silence(output);
        return Status::ok;
    }
    for (std::size_t i = 0; i < static_cast<std::size_t>(frames) * input.channels; ++i) {
        if (!std::isfinite(input.data[i])) {
            silence(output);
            return Status::nonFiniteSignal;
        }
    }
    const auto left = std::min(p.preferredLeft, output.channels - 1);
    const auto right = std::min(p.preferredRight, output.channels - 1);
    for (std::size_t frame = 0; frame < frames; ++frame) {
        // An exponential, per-frame ramp. Initial gain is supplied before activation;
        // there is no implicit gain=1 first buffer or extra startup gate here.
        currentGain_ += (p.targetGain - currentGain_) * p.rampCoefficient;
        const float gain = currentGain_ * p.crossfade * p.outputGate;
        const float *source = input.data + frame * input.channels;
        float *destination = output.data + frame * output.channels;
        if (input.channels == output.channels) {
            for (std::size_t channel = 0; channel < output.channels; ++channel) {
                destination[channel] = source[channel] * gain;
            }
        } else if ((input.channels == 2 && output.channels > 2) || input.channels == 1) {
            const float first = source[0] * gain;
            const float second = source[input.channels == 1 ? 0 : 1] * gain;
            std::fill_n(destination, output.channels, 0.0F);
            destination[left] = first;
            destination[right] = second;
        } else {
            const auto copied = std::min(input.channels, output.channels);
            for (std::size_t channel = 0; channel < copied; ++channel) {
                destination[channel] = source[channel] * gain;
            }
            std::fill(destination + copied, destination + output.channels, 0.0F);
        }
    }
    const auto written = static_cast<std::size_t>(frames) * output.channels;
    const auto capacity = static_cast<std::size_t>(output.frames) * output.channels;
    std::fill(output.data + written, output.data + capacity, 0.0F);
    return Status::ok;
}

std::int64_t mappedInputIndex(std::uint32_t inputs, std::uint32_t outputs,
                              std::uint32_t outputIndex) noexcept {
    if (outputIndex >= outputs) {
        return -1;
    }
    const auto index = (inputs > outputs ? inputs - outputs : 0) + outputIndex;
    return index < inputs ? static_cast<std::int64_t>(index) : -1;
}

void CrossfadeState::beginWarmup() noexcept {
    *this = {};
    phase = CrossfadePhase::warmingUp;
}
void CrossfadeState::beginCrossfading() noexcept {
    secondarySamples = 0;
    progress = 0;
    phase = CrossfadePhase::crossfading;
}
void CrossfadeState::complete() noexcept { *this = {}; }
Status CrossfadeState::advance(std::int64_t samples) noexcept {
    if (samples < 0 || processedSamples < 0 ||
        samples > std::numeric_limits<std::int64_t>::max() - processedSamples ||
        (phase == CrossfadePhase::crossfading &&
         (secondarySamples < 0 ||
          samples > std::numeric_limits<std::int64_t>::max() - secondarySamples))) {
        return Status::invalidArgument;
    }
    processedSamples += samples;
    if (phase == CrossfadePhase::crossfading) {
        secondarySamples += samples;
        progress = std::min(1.0F, static_cast<float>(secondarySamples) /
                                      static_cast<float>(std::max<std::int64_t>(1, totalSamples)));
    }
    return Status::ok;
}
float CrossfadeState::primaryMultiplier() const noexcept {
    switch (phase) {
    case CrossfadePhase::idle:
        return progress >= 1 ? 0 : 1;
    case CrossfadePhase::warmingUp:
        return 1;
    case CrossfadePhase::crossfading:
        return std::cos(progress * std::numbers::pi_v<float> / 2);
    }
    return std::numeric_limits<float>::quiet_NaN();
}
float CrossfadeState::secondaryMultiplier() const noexcept {
    switch (phase) {
    case CrossfadePhase::idle:
        return 1;
    case CrossfadePhase::warmingUp:
        return 0;
    case CrossfadePhase::crossfading:
        return std::sin(progress * std::numbers::pi_v<float> / 2);
    }
    return std::numeric_limits<float>::quiet_NaN();
}

Status advanceOutputGate(OutputGateState &state, float peak, std::uint32_t frames, float rampFrames,
                         std::uint32_t silenceHoldFrames, float &multiplier) noexcept {
    if (state.phase > 2 || !std::isfinite(state.progress) || state.progress < 0 ||
        state.progress > 1 || state.silentFrames < 0 || !std::isfinite(peak) || peak < 0 ||
        !std::isfinite(rampFrames) || rampFrames <= 0 || silenceHoldFrames == 0 ||
        frames > std::numeric_limits<std::int64_t>::max() - state.silentFrames) {
        return Status::invalidArgument;
    }
    const bool silent = peak <= 0.0001F;
    switch (state.phase) {
    case 0:
        if (!silent) {
            state.phase = 1;
            state.progress = 0;
            state.silentFrames = 0;
        }
        multiplier = 0;
        break;
    case 1:
        state.progress = std::min(1.0F, state.progress + static_cast<float>(frames) / rampFrames);
        if (state.progress >= 1) {
            state.phase = 2;
            state.silentFrames = 0;
            multiplier = 1;
        } else {
            multiplier = 0.5F * (1 - std::cos(std::numbers::pi_v<float> * state.progress));
        }
        break;
    case 2:
        state.silentFrames = silent ? state.silentFrames + frames : 0;
        if (state.silentFrames >= silenceHoldFrames) {
            state.phase = 0;
            state.silentFrames = 0;
        }
        multiplier = 1;
        break;
    }
    return Status::ok;
}

} // namespace finetune::dsp
