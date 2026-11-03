#include "AudioDSP/Pipeline.hpp"
#include "NativeAudioDynamics.h"
#include "NativeAudioPipeline.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <memory>
#include <new>

using finetune::dsp::CrossfadePhase;
using finetune::dsp::CrossfadeState;
using finetune::dsp::Status;

struct FTPipeline {
    explicit FTPipeline(float gain) noexcept : mapping(gain) {}
    finetune::dsp::RoutePipeline mapping;
    std::unique_ptr<FTBiquadProcessor, decltype(&ft_biquad_destroy)> eq{nullptr, ft_biquad_destroy};
    std::unique_ptr<FTBiquadProcessor, decltype(&ft_biquad_destroy)> autoEQ{nullptr,
                                                                            ft_biquad_destroy};
    std::unique_ptr<FTLoudnessEqualizer, decltype(&ft_loudness_equalizer_destroy)> equalizer{
        nullptr, ft_loudness_equalizer_destroy};
    std::unique_ptr<FTLoudnessCompensator, decltype(&ft_loudness_compensator_destroy)> compensator{
        nullptr, ft_loudness_compensator_destroy};
};

namespace {
FTPipelineStatus convert(Status status) noexcept { return static_cast<FTPipelineStatus>(status); }
CrossfadeState load(const FTCrossfadeState &state) noexcept {
    return {state.progress, static_cast<CrossfadePhase>(state.phase), state.secondary_sample_count,
            state.total_samples, state.secondary_samples_processed};
}
FTCrossfadeState store(const CrossfadeState &state) noexcept {
    return {state.progress, static_cast<uint32_t>(state.phase), state.secondarySamples,
            state.totalSamples, state.processedSamples};
}
bool valid(const FTCrossfadeState &state) noexcept {
    return state.phase <= 2 && std::isfinite(state.progress) && state.progress >= 0 &&
           state.progress <= 1 && state.secondary_sample_count >= 0 && state.total_samples >= 0 &&
           state.secondary_samples_processed >= 0;
}
FTPipelineStatus mute(FTPipelineOutputBuffer output) noexcept {
    if (output.frame_count != 0) {
        std::fill_n(output.data,
                    static_cast<std::size_t>(output.frame_count) * output.channel_count, 0.0F);
    }
    return FT_PIPELINE_NONFINITE_SIGNAL;
}
} // namespace

extern "C" FTPipeline *ft_pipeline_create(float gain) {
    if (!std::isfinite(gain) || gain < 0) {
        return nullptr;
    }
    return new (std::nothrow) FTPipeline(gain);
}
extern "C" void ft_pipeline_destroy(FTPipeline *pipeline) { delete pipeline; }
extern "C" float ft_pipeline_current_gain(const FTPipeline *pipeline) {
    return pipeline ? pipeline->mapping.currentGain() : std::numeric_limits<float>::quiet_NaN();
}
extern "C" FTPipelineParameters ft_pipeline_default_parameters(void) { return {1, 1, 1, 1, 0, 1}; }
extern "C" FTPipelineStatus ft_pipeline_configure_biquad(FTPipeline *pipeline, uint32_t stage,
                                                         const FTBiquadProcessor *source) {
    if (!pipeline || stage > 1) {
        return FT_PIPELINE_INVALID_ARGUMENT;
    }
    auto &destination = stage == 0 ? pipeline->eq : pipeline->autoEQ;
    if (!source) {
        destination.reset();
        return FT_PIPELINE_OK;
    }
    std::unique_ptr<FTBiquadProcessor, decltype(&ft_biquad_destroy)> prepared(ft_biquad_create(2),
                                                                              ft_biquad_destroy);
    if (!prepared) {
        return FT_PIPELINE_INVALID_CONFIGURATION;
    }
    const auto status = ft_biquad_copy_configuration(source, prepared.get());
    if (status != FT_BIQUAD_OK) {
        return static_cast<FTPipelineStatus>(status);
    }
    destination = std::move(prepared);
    return FT_PIPELINE_OK;
}
extern "C" FTPipelineStatus ft_pipeline_configure_equalizer(FTPipeline *pipeline,
                                                            const FTLoudnessEqualizer *source) {
    if (!pipeline) {
        return FT_PIPELINE_INVALID_ARGUMENT;
    }
    if (!source) {
        pipeline->equalizer.reset();
        return FT_PIPELINE_OK;
    }
    auto *prepared = ft_loudness_equalizer_clone_configuration(source);
    if (!prepared) {
        return FT_PIPELINE_INVALID_CONFIGURATION;
    }
    pipeline->equalizer.reset(prepared);
    return FT_PIPELINE_OK;
}
extern "C" FTPipelineStatus ft_pipeline_configure_compensator(FTPipeline *pipeline,
                                                              const FTLoudnessCompensator *source) {
    if (!pipeline) {
        return FT_PIPELINE_INVALID_ARGUMENT;
    }
    if (!source) {
        pipeline->compensator.reset();
        return FT_PIPELINE_OK;
    }
    auto *prepared = ft_loudness_compensator_clone_configuration(source);
    if (!prepared) {
        return FT_PIPELINE_INVALID_CONFIGURATION;
    }
    pipeline->compensator.reset(prepared);
    return FT_PIPELINE_OK;
}
extern "C" FTPipelineStatus ft_pipeline_process(FTPipeline *pipeline, FTPipelineInputBuffer input,
                                                FTPipelineOutputBuffer output,
                                                FTPipelineParameters p) {
    if (!pipeline) {
        return FT_PIPELINE_INVALID_ARGUMENT;
    }
    const auto status = pipeline->mapping.mapAndGain(
        {input.data, input.frame_count, input.channel_count},
        {output.data, output.frame_count, output.channel_count},
        {p.target_gain, p.crossfade_multiplier, p.output_gate_multiplier, p.ramp_coefficient,
         p.preferred_left, p.preferred_right});
    if (status != Status::ok) {
        return convert(status);
    }
    const auto frames = std::min(input.frame_count, output.frame_count);
    if (frames == 0) {
        return FT_PIPELINE_OK;
    }
    if (input.channel_count == 2 && output.channel_count == 2) {
        for (auto *stage : {pipeline->eq.get(), pipeline->autoEQ.get()}) {
            if (stage &&
                ft_biquad_process(stage, output.data, output.data, frames) != FT_BIQUAD_OK) {
                return mute(output);
            }
        }
        if (pipeline->equalizer &&
            ft_loudness_equalizer_process(pipeline->equalizer.get(), output.data, output.data,
                                          frames, 2) != 0) {
            return mute(output);
        }
        if (pipeline->compensator &&
            ft_loudness_compensator_process(pipeline->compensator.get(), output.data, output.data,
                                            frames) != 0) {
            return mute(output);
        }
    }
    // Keep the scalar ABI's uint32 bound without imposing a block/frame limit. Iteration is
    // bounded by the caller's validated output size; there is no workspace allocation.
    for (std::size_t offset = 0, samples = static_cast<std::size_t>(frames) * output.channel_count;
         offset < samples;) {
        const auto count = static_cast<uint32_t>(
            std::min<std::size_t>(samples - offset, std::numeric_limits<uint32_t>::max()));
        ft_soft_limiter_process(output.data + offset, count);
        offset += count;
    }
    for (std::size_t i = 0; i < static_cast<std::size_t>(frames) * output.channel_count; ++i) {
        if (!std::isfinite(output.data[i])) {
            return mute(output);
        }
    }
    return FT_PIPELINE_OK;
}
extern "C" int64_t ft_pipeline_source_index(uint32_t inputs, uint32_t outputs, uint32_t index) {
    return finetune::dsp::mappedInputIndex(inputs, outputs, index);
}
extern "C" FTCrossfadeState ft_crossfade_initial_state(void) { return store({}); }
extern "C" FTPipelineStatus ft_crossfade_begin_warmup(FTCrossfadeState *state) {
    if (!state) {
        return FT_PIPELINE_INVALID_ARGUMENT;
    }
    CrossfadeState next;
    next.beginWarmup();
    *state = store(next);
    return FT_PIPELINE_OK;
}
extern "C" FTPipelineStatus ft_crossfade_begin_crossfading(FTCrossfadeState *state) {
    if (!state || !valid(*state)) {
        return FT_PIPELINE_INVALID_ARGUMENT;
    }
    auto next = load(*state);
    next.beginCrossfading();
    *state = store(next);
    return FT_PIPELINE_OK;
}
extern "C" FTPipelineStatus ft_crossfade_complete(FTCrossfadeState *state) {
    if (!state) {
        return FT_PIPELINE_INVALID_ARGUMENT;
    }
    *state = ft_crossfade_initial_state();
    return FT_PIPELINE_OK;
}
extern "C" FTPipelineStatus ft_crossfade_advance(FTCrossfadeState *state, int64_t samples) {
    if (!state || !valid(*state)) {
        return FT_PIPELINE_INVALID_ARGUMENT;
    }
    auto next = load(*state);
    const auto status = next.advance(samples);
    if (status == Status::ok) {
        *state = store(next);
    }
    return convert(status);
}
extern "C" float ft_crossfade_primary_multiplier(const FTCrossfadeState *state) {
    return state && valid(*state) ? load(*state).primaryMultiplier()
                                  : std::numeric_limits<float>::quiet_NaN();
}
extern "C" float ft_crossfade_secondary_multiplier(const FTCrossfadeState *state) {
    return state && valid(*state) ? load(*state).secondaryMultiplier()
                                  : std::numeric_limits<float>::quiet_NaN();
}
extern "C" int64_t ft_crossfade_minimum_warmup_samples(void) {
    return CrossfadeState::minimumWarmupSamples;
}
extern "C" FTPipelineStatus ft_output_gate_advance(FTOutputGateState *state, float peak,
                                                   uint32_t frames, float ramp, uint32_t hold,
                                                   float *multiplier) {
    if (!state || !multiplier) {
        return FT_PIPELINE_INVALID_ARGUMENT;
    }
    finetune::dsp::OutputGateState next{state->phase, state->progress, state->silent_frames};
    float result = 0;
    const auto status = finetune::dsp::advanceOutputGate(next, peak, frames, ramp, hold, result);
    if (status == Status::ok) {
        *state = {next.phase, next.progress, next.silentFrames};
        *multiplier = result;
    }
    return convert(status);
}
