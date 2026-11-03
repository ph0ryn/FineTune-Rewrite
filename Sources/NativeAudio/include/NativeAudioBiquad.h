#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum FTBiquadStatus {
    FT_BIQUAD_OK = 0,
    FT_BIQUAD_INVALID_ARGUMENT = 1,
    FT_BIQUAD_INVALID_CONFIGURATION = 2,
    FT_BIQUAD_NONFINITE_SIGNAL = 3
} FTBiquadStatus;

typedef enum FTBiquadFilterType {
    FT_BIQUAD_PEAKING = 0,
    FT_BIQUAD_LOW_SHELF = 1,
    FT_BIQUAD_HIGH_SHELF = 2
} FTBiquadFilterType;

typedef struct FTBiquadFilter {
    FTBiquadFilterType type;
    double frequency;
    float gain_db;
    double q;
} FTBiquadFilter;

typedef struct FTBiquadProcessor FTBiquadProcessor;

// Non-RT, serialized control operations. The owner must quiesce processing before
// replacement/destruction. Coefficients are copied; no caller pointer is retained.
// Fixed storage supports 1..8 channels and 0..10 sections. Zero sections means bypass.
FTBiquadProcessor *ft_biquad_create(uint32_t channel_count);
void ft_biquad_destroy(FTBiquadProcessor *processor);
FTBiquadStatus ft_biquad_replace_coefficients(FTBiquadProcessor *processor,
                                              const double *coefficients, uint32_t section_count);
// Non-RT shared AutoEQ preparation using actual callback rate, never a device-rate guess.
// Empty active profiles apply one scaled-unity section only when preamp is enabled.
// Success resets history and preserves enabled state; failure preserves both and configuration.
// Borrows filters only for this call. At most ten filters; null is valid only for count zero.
FTBiquadStatus ft_biquad_prepare_autoeq(FTBiquadProcessor *processor, const FTBiquadFilter *filters,
                                        uint32_t filter_count, double actual_sample_rate,
                                        double profile_optimized_rate, float preamp_db,
                                        bool preamp_enabled);
// Copies immutable configuration and enabled state, never mutable delay history.
// Both instances must be quiescent and have matching channel counts.
FTBiquadStatus ft_biquad_copy_configuration(const FTBiquadProcessor *source,
                                            FTBiquadProcessor *destination);

// One execution path owns one processor; calls on an instance must not overlap.
// Disabled processing is bit-exact bypass and freezes, rather than clears, history.
void ft_biquad_set_enabled(FTBiquadProcessor *processor, bool enabled);
bool ft_biquad_is_enabled(const FTBiquadProcessor *processor);
void ft_biquad_reset(FTBiquadProcessor *processor);

// RT: no allocation, locks, throws, OS calls, or Swift callbacks. Interleaved Float32.
// Exact in-place processing is supported. No partial overlap. Zero frames is a no-op.
// Non-finite input/output mutes the whole block, resets history, and returns an error.
FTBiquadStatus ft_biquad_process(FTBiquadProcessor *processor, const float *input, float *output,
                                 uint32_t frame_count);

// Non-RT coefficient utilities. Output order is b0,b1,b2,a1,a2 with normalized a0=1.
FTBiquadStatus ft_biquad_coefficients(FTBiquadFilter filter, double sample_rate, double output[5]);
double ft_biquad_prewarp(double frequency, double source_rate, double target_rate);
// output must hold 50 doubles. Wrong gain_count intentionally yields ten unity sections.
FTBiquadStatus ft_biquad_graphic_coefficients(const float *gains, uint32_t gain_count,
                                              double sample_rate, double output[50]);
// output must hold filter_count*5 doubles. Up to ten filters. Empty input is valid.
FTBiquadStatus ft_biquad_autoeq_coefficients(const FTBiquadFilter *filters, uint32_t filter_count,
                                             double sample_rate, double profile_optimized_rate,
                                             double *output);

#ifdef __cplusplus
}
#endif
