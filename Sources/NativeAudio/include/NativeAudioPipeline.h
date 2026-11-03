#pragma once

#include "NativeAudioBiquad.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum FTPipelineStatus {
    FT_PIPELINE_OK = 0,
    FT_PIPELINE_INVALID_ARGUMENT = 1,
    FT_PIPELINE_INVALID_CONFIGURATION = 2,
    FT_PIPELINE_NONFINITE_SIGNAL = 3
} FTPipelineStatus;

typedef struct FTPipeline FTPipeline;
typedef struct FTLoudnessEqualizer FTLoudnessEqualizer;
typedef struct FTLoudnessCompensator FTLoudnessCompensator;

typedef struct FTPipelineInputBuffer {
    const float *data;
    uint32_t frame_count;
    uint32_t channel_count;
} FTPipelineInputBuffer;
typedef struct FTPipelineOutputBuffer {
    float *data;
    uint32_t frame_count;
    uint32_t channel_count;
} FTPipelineOutputBuffer;
typedef struct FTPipelineParameters {
    float target_gain;
    float crossfade_multiplier;
    float output_gate_multiplier;
    float ramp_coefficient;
    uint32_t preferred_left;
    uint32_t preferred_right;
} FTPipelineParameters;

// One native handle owns one route's gain and DSP histories. Control/configuration/destruction
// are non-RT, require a quiescent owner, and must not overlap process calls. No shared state.
FTPipeline *ft_pipeline_create(float initial_gain);
void ft_pipeline_destroy(FTPipeline *pipeline);
float ft_pipeline_current_gain(const FTPipeline *pipeline);
FTPipelineParameters ft_pipeline_default_parameters(void);
// stage 0 = app EQ, 1 = device AutoEQ. Configuration is copied; source is never retained.
// source=NULL removes that stage. Source and destination must be quiescent during copying.
FTPipelineStatus ft_pipeline_configure_biquad(FTPipeline *pipeline, uint32_t stage,
                                              const FTBiquadProcessor *source);
FTPipelineStatus ft_pipeline_configure_equalizer(FTPipeline *pipeline,
                                                 const FTLoudnessEqualizer *source);
FTPipelineStatus ft_pipeline_configure_compensator(FTPipeline *pipeline,
                                                   const FTLoudnessCompensator *source);

// RT: synchronous, no Swift callbacks, allocation, locks, OS/device calls, or exceptions.
// Interleaved Float32 only, 1..8 channels; caller guarantees frame_count*channel_count capacity.
// Zero-length input explicitly means silence, not an invalid null input. Exact in-place with
// equal channel counts is allowed; partial overlap is rejected. Invalid arguments leave all
// state/output unchanged. Non-finite signal mutes the block and reports NONFINITE_SIGNAL.
// The caller MUST inspect status: on any non-OK result a HAL/render caller must silence its
// known-valid output capacity and record the fault, never publish old/uninitialized output.
// Preferred pair is clamped for mono/stereo-to-surround mapping. Unused/tail output is zeroed.
// EQ/dynamics are stereo-only, preserving the currently ported pipeline's channel contract.
FTPipelineStatus ft_pipeline_process(FTPipeline *pipeline, FTPipelineInputBuffer input,
                                     FTPipelineOutputBuffer output,
                                     FTPipelineParameters parameters);
// Preparation helper, not a hardware stream discovery rule. -1 = no mapped source.
int64_t ft_pipeline_source_index(uint32_t input_count, uint32_t output_count,
                                 uint32_t output_index);

// Pure transition states. Owned/serialized by one execution path; these POD fields are not
// a cross-thread publication mechanism or proof of callback quiescence.
typedef struct FTCrossfadeState {
    float progress;
    uint32_t phase;
    int64_t secondary_sample_count;
    int64_t total_samples;
    int64_t secondary_samples_processed;
} FTCrossfadeState;
FTCrossfadeState ft_crossfade_initial_state(void);
FTPipelineStatus ft_crossfade_begin_warmup(FTCrossfadeState *state);
FTPipelineStatus ft_crossfade_begin_crossfading(FTCrossfadeState *state);
FTPipelineStatus ft_crossfade_complete(FTCrossfadeState *state);
FTPipelineStatus ft_crossfade_advance(FTCrossfadeState *state, int64_t samples);
float ft_crossfade_primary_multiplier(const FTCrossfadeState *state);
float ft_crossfade_secondary_multiplier(const FTCrossfadeState *state);
int64_t ft_crossfade_minimum_warmup_samples(void);

typedef struct FTOutputGateState {
    uint32_t phase;
    float progress;
    int64_t silent_frames;
} FTOutputGateState;
// Invalid arguments leave state/multiplier unchanged. The first non-silent armed buffer
// enters ramping but returns zero. Re-arming while open returns one for that final buffer.
FTPipelineStatus ft_output_gate_advance(FTOutputGateState *state, float peak, uint32_t frames,
                                        float ramp_frames, uint32_t silence_hold_frames,
                                        float *multiplier);

#ifdef __cplusplus
}
#endif
