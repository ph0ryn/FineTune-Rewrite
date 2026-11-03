#include "AudioDSP/AudioDSP.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <numbers>

namespace finetune::dsp {
namespace {
constexpr BiquadCoefficients unity{1, 0, 0, 0, 0};

bool validFilter(FilterSpec filter) noexcept {
    return (filter.type == FilterType::peaking || filter.type == FilterType::lowShelf ||
            filter.type == FilterType::highShelf) &&
           std::isfinite(filter.frequency) && filter.frequency >= 0 &&
           std::isfinite(filter.gainDB) && std::isfinite(filter.q) && filter.q > 0;
}

bool stable(const BiquadCoefficients &c) noexcept {
    return std::all_of(c.begin(), c.end(), [](double x) { return std::isfinite(x); }) &&
           std::abs(c[4]) < 1 && 1 + c[3] + c[4] > 0 && 1 - c[3] + c[4] > 0;
}
} // namespace

BiquadCoefficients coefficients(FilterSpec filter, double sampleRate) noexcept {
    if (!validFilter(filter) || !std::isfinite(sampleRate) || sampleRate <= 0) {
        BiquadCoefficients invalid;
        invalid.fill(std::numeric_limits<double>::quiet_NaN());
        return invalid;
    }
    // Independently expressed RBJ transfer functions from W3C Audio EQ Cookbook,
    // https://www.w3.org/TR/2021/NOTE-audio-eq-cookbook-20210608/#formulae
    const double amplitude = std::pow(10.0, static_cast<double>(filter.gainDB) / 40.0);
    const double angle = 2 * std::numbers::pi * filter.frequency / sampleRate;
    const double cosine = std::cos(angle);
    const double alpha = std::sin(angle) / (2 * filter.q);
    double b0, b1, b2, a0, a1, a2;
    if (filter.type == FilterType::peaking) {
        b0 = 1 + alpha * amplitude;
        b1 = -2 * cosine;
        b2 = 1 - alpha * amplitude;
        a0 = 1 + alpha / amplitude;
        a1 = -2 * cosine;
        a2 = 1 - alpha / amplitude;
    } else {
        const double sum = amplitude + 1;
        const double difference = amplitude - 1;
        const double width = 2 * std::sqrt(amplitude) * alpha;
        if (filter.type == FilterType::lowShelf) {
            b0 = amplitude * (sum - difference * cosine + width);
            b1 = 2 * amplitude * (difference - sum * cosine);
            b2 = amplitude * (sum - difference * cosine - width);
            a0 = sum + difference * cosine + width;
            a1 = -2 * (difference + sum * cosine);
            a2 = sum + difference * cosine - width;
        } else {
            b0 = amplitude * (sum + difference * cosine + width);
            b1 = -2 * amplitude * (difference + sum * cosine);
            b2 = amplitude * (sum + difference * cosine - width);
            a0 = sum - difference * cosine + width;
            a1 = 2 * (difference - sum * cosine);
            a2 = sum - difference * cosine - width;
        }
    }
    return {b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
}

double preWarpFrequency(double frequency, double sourceRate, double targetRate) noexcept {
    // Preserve the analogue frequency under inverse/forward bilinear substitution.
    return targetRate / std::numbers::pi *
           std::atan(sourceRate / targetRate * std::tan(std::numbers::pi * frequency / sourceRate));
}

GraphicEQCoefficients graphicEQCoefficients(std::span<const float> gains,
                                            double sampleRate) noexcept {
    GraphicEQCoefficients result{};
    for (std::size_t section = 0; section < graphicEQFrequencies.size(); ++section) {
        const auto c = gains.size() != graphicEQFrequencies.size() ||
                               graphicEQFrequencies[section] >= sampleRate / 2
                           ? unity
                           : coefficients({FilterType::peaking, graphicEQFrequencies[section],
                                           gains[section], graphicEQQ},
                                          sampleRate);
        std::copy(c.begin(), c.end(), result.begin() + section * 5);
    }
    return result;
}

Status autoEQCoefficients(std::span<const FilterSpec> filters, double sampleRate,
                          double profileOptimizedRate, std::span<double> output) noexcept {
    if (filters.size() > maxBiquadSections || output.size() < filters.size() * 5 ||
        !std::isfinite(sampleRate) || sampleRate <= 0 || !std::isfinite(profileOptimizedRate) ||
        profileOptimizedRate <= 0 || !std::all_of(filters.begin(), filters.end(), validFilter)) {
        return Status::invalidArgument;
    }
    std::array<double, maxBiquadSections * 5> completed{};
    for (std::size_t section = 0; section < filters.size(); ++section) {
        auto filter = filters[section];
        if (std::abs(sampleRate - profileOptimizedRate) >= 1) {
            filter.frequency = preWarpFrequency(filter.frequency, profileOptimizedRate, sampleRate);
        }
        const auto c = filter.frequency <= 0 || filter.frequency >= sampleRate / 2
                           ? unity
                           : coefficients(filter, sampleRate);
        if (!std::all_of(c.begin(), c.end(), [](double x) { return std::isfinite(x); })) {
            return Status::invalidConfiguration;
        }
        std::copy(c.begin(), c.end(), completed.begin() + section * 5);
    }
    std::copy_n(completed.begin(), filters.size() * 5, output.begin());
    return Status::ok;
}

Status prepareBiquad(std::span<const double> input, std::size_t channelCount,
                     PreparedBiquad &output) noexcept {
    if (channelCount == 0 || channelCount > maxChannels || input.size() % 5 != 0 ||
        input.size() / 5 > maxBiquadSections) {
        return Status::invalidArgument;
    }
    PreparedBiquad candidate;
    candidate.channelCount_ = channelCount;
    candidate.sectionCount_ = input.size() / 5;
    for (std::size_t section = 0; section < candidate.sectionCount_; ++section) {
        auto &c = candidate.sections_[section];
        std::copy_n(input.begin() + section * 5, 5, c.begin());
        if (!stable(c)) {
            return Status::invalidConfiguration;
        }
    }
    candidate.valid_ = true;
    output = candidate;
    return Status::ok;
}

Status BiquadProcessor::configure(const PreparedBiquad &prepared) noexcept {
    if (!prepared.valid_) {
        return Status::invalidConfiguration;
    }
    prepared_ = prepared;
    reset();
    return Status::ok;
}

void BiquadProcessor::reset() noexcept { delays_ = {}; }

Status BiquadProcessor::process(std::span<const ConstChannelView> input,
                                std::span<const ChannelView> output,
                                std::size_t frameCount) noexcept {
    if (frameCount == 0) {
        return Status::ok;
    }
    if (!prepared_.valid_ || input.size() != prepared_.channelCount_ ||
        output.size() != input.size()) {
        return Status::invalidArgument;
    }
    for (std::size_t channel = 0; channel < input.size(); ++channel) {
        if (!input[channel].data || !output[channel].data || input[channel].stride == 0 ||
            output[channel].stride == 0 ||
            frameCount - 1 > std::numeric_limits<std::size_t>::max() / input[channel].stride ||
            frameCount - 1 > std::numeric_limits<std::size_t>::max() / output[channel].stride) {
            return Status::invalidArgument;
        }
    }
    const auto failSignal = [&]() noexcept {
        for (const auto &channel : output) {
            for (std::size_t frame = 0; frame < frameCount; ++frame) {
                channel.data[frame * channel.stride] = 0;
            }
        }
        reset();
        return Status::nonFiniteSignal;
    };
    for (std::size_t frame = 0; frame < frameCount; ++frame) {
        for (std::size_t channel = 0; channel < input.size(); ++channel) {
            double sample = input[channel].data[frame * input[channel].stride];
            if (!std::isfinite(sample)) {
                return failSignal();
            }
            if (enabled_) {
                for (std::size_t section = 0; section < prepared_.sectionCount_; ++section) {
                    const auto &c = prepared_.sections_[section];
                    auto &delay = delays_[channel][section];
                    // Transposed direct form II: two double accumulators per channel/section.
                    const double filtered = c[0] * sample + delay.z1;
                    delay.z1 = c[1] * sample - c[3] * filtered + delay.z2;
                    delay.z2 = c[2] * sample - c[4] * filtered;
                    sample = filtered;
                }
            }
            const float result = static_cast<float>(sample);
            if (!std::isfinite(result)) {
                return failSignal();
            }
            output[channel].data[frame * output[channel].stride] = result;
        }
    }
    return Status::ok;
}

Status BiquadProcessor::processInterleaved(const float *input, float *output,
                                           std::size_t frameCount,
                                           std::size_t channelCount) noexcept {
    if (frameCount == 0) {
        return Status::ok;
    }
    if (!input || !output || channelCount == 0 || channelCount > maxChannels) {
        return Status::invalidArgument;
    }
    std::array<ConstChannelView, maxChannels> inputs{};
    std::array<ChannelView, maxChannels> outputs{};
    for (std::size_t channel = 0; channel < channelCount; ++channel) {
        inputs[channel] = {input + channel, channelCount};
        outputs[channel] = {output + channel, channelCount};
    }
    return process(std::span(inputs).first(channelCount), std::span(outputs).first(channelCount),
                   frameCount);
}
} // namespace finetune::dsp
