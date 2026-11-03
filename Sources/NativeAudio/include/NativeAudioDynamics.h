#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Stateless RT functions; non-finite scalar results retain IEEE behavior.
float ft_soft_limiter_apply(float sample);
void ft_soft_limiter_process(float *samples, uint32_t sample_count);

typedef struct FTLoudnessSettings {
    float target_loudness_db;
    float max_boost_db;
    float max_cut_db;
    float compression_threshold_offset_db;
    float compression_ratio;
    float compression_knee_db;
    float analysis_window_ms;
    float analysis_hop_ms;
    float detector_attack_ms;
    float detector_release_ms;
    float gain_attack_ms;
    float gain_release_ms;
    float noise_floor_threshold_db;
    float low_level_max_boost_db;
    bool enabled;
} FTLoudnessSettings;

typedef struct FTLoudnessEqualizer FTLoudnessEqualizer;
typedef struct FTLoudnessCompensator FTLoudnessCompensator;

// Non-RT preparation/destruction, copied settings, no caller pointer retention.
// Each handle belongs to one serialized execution route. Clones copy configuration
// only and initialize fresh detector, filter and gain history.
FTLoudnessEqualizer *ft_loudness_equalizer_create(const FTLoudnessSettings *settings,
                                                  float sample_rate);
FTLoudnessEqualizer *ft_loudness_equalizer_clone_configuration(const FTLoudnessEqualizer *source);
void ft_loudness_equalizer_destroy(FTLoudnessEqualizer *processor);
// RT interleaved Float32, exact in-place supported. Return 0 on success, 1 on invalid arguments.
// Caller supplies finite audio samples. This raw stage does not implement the Biquad
// non-finite mute/reset policy; the pipeline validates signal finiteness at its boundary.
int32_t ft_loudness_equalizer_process(FTLoudnessEqualizer *processor, const float *input,
                                      float *output, uint32_t frame_count, uint32_t channel_count);

FTLoudnessCompensator *ft_loudness_compensator_create(double sample_rate);
FTLoudnessCompensator *
ft_loudness_compensator_clone_configuration(const FTLoudnessCompensator *source);
void ft_loudness_compensator_destroy(FTLoudnessCompensator *processor);
// Non-RT coefficient calculation. A volume update restores enabled state even at the same value.
int32_t ft_loudness_compensator_update_volume(FTLoudnessCompensator *processor, float volume);
void ft_loudness_compensator_set_enabled(FTLoudnessCompensator *processor, bool enabled);
bool ft_loudness_compensator_is_enabled(const FTLoudnessCompensator *processor);
// RT stereo, exact in-place supported. Returns 0 on success, 1 on invalid arguments,
// or 3 (NONFINITE_SIGNAL) after muting the whole block and resetting filter history.
int32_t ft_loudness_compensator_process(FTLoudnessCompensator *processor, const float *input,
                                        float *output, uint32_t frame_count);

// Scalar math and analysis boundaries used by the production control adapter.
float ft_loudness_db_to_linear(float db);
float ft_loudness_linear_to_db(float linear);
float ft_loudness_time_coefficient(float time_ms, float step_ms);
float ft_loudness_desired_gain(const FTLoudnessSettings *settings, float level_db);

typedef struct FTKWeightingFilter FTKWeightingFilter;
FTKWeightingFilter *ft_k_weighting_create(float sample_rate);
void ft_k_weighting_destroy(FTKWeightingFilter *filter);
void ft_k_weighting_reset(FTKWeightingFilter *filter);
float ft_k_weighting_process_sample(FTKWeightingFilter *filter, float sample);

typedef struct FTLoudnessDetector FTLoudnessDetector;
FTLoudnessDetector *ft_loudness_detector_create(const FTLoudnessSettings *settings,
                                                float sample_rate);
void ft_loudness_detector_destroy(FTLoudnessDetector *detector);
void ft_loudness_detector_reset(FTLoudnessDetector *detector);
bool ft_loudness_detector_ingest(FTLoudnessDetector *detector, float sample, float *level_db);
float ft_loudness_detector_update_envelope(FTLoudnessDetector *detector, float level_db);

typedef struct FTGainSmoother FTGainSmoother;
FTGainSmoother *ft_gain_smoother_create(const FTLoudnessSettings *settings, float sample_rate);
void ft_gain_smoother_destroy(FTGainSmoother *smoother);
void ft_gain_smoother_reset(FTGainSmoother *smoother, float initial_gain_db);
float ft_gain_smoother_process(FTGainSmoother *smoother, float target_gain_db);

// Non-RT ISO 226:2023 data and approximation helpers. Reference columns:
// 0=frequency, 1=alpha_f, 2=L_U, 3=T_f; output holds 29 doubles.
int32_t ft_iso226_reference_data(uint32_t column, double *output);
void ft_iso226_contour(double phon, double *output);
void ft_iso226_compensation(double phon, double reference_phon, double amount, double max_gain_db,
                            double *output);
double ft_iso226_estimated_phon(float volume);
double ft_iso226_interpolate(const double *gains, uint32_t count, double frequency);
void ft_loudness_fitted_gains(double phon, double sample_rate, double output[4]);
void ft_loudness_band_coefficients(const double gains[4], double sample_rate, double output[20]);

#ifdef __cplusplus
}
#endif
