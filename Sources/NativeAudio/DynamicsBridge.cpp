#include "AudioDSP/Dynamics.hpp"
#include "NativeAudioDynamics.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <new>
#include <span>

namespace dsp = finetune::dsp;
namespace {
dsp::LoudnessSettings settingsValue(const FTLoudnessSettings &s) noexcept {
    return {s.target_loudness_db,
            s.max_boost_db,
            s.max_cut_db,
            s.compression_threshold_offset_db,
            s.compression_ratio,
            s.compression_knee_db,
            s.analysis_window_ms,
            s.analysis_hop_ms,
            s.detector_attack_ms,
            s.detector_release_ms,
            s.gain_attack_ms,
            s.gain_release_ms,
            s.noise_floor_threshold_db,
            s.low_level_max_boost_db,
            s.enabled};
}
constexpr float invalidScalar = std::numeric_limits<float>::quiet_NaN();
bool validSampleRate(double rate) noexcept {
    return std::isfinite(rate) && rate >= 8000 && rate <= 768000;
}
} // namespace

struct FTLoudnessEqualizer {
    dsp::LoudnessEqualizer processor;
    FTLoudnessEqualizer(dsp::LoudnessSettings settings, float rate) noexcept
        : processor(settings, rate) {}
};
struct FTLoudnessCompensator {
    dsp::LoudnessCompensator processor;
    explicit FTLoudnessCompensator(double rate) noexcept : processor(rate) {}
};
struct FTKWeightingFilter {
    dsp::KWeightingFilter filter;
    explicit FTKWeightingFilter(float rate) noexcept : filter(rate) {}
};
struct FTLoudnessDetector {
    dsp::LoudnessDetector detector;
    FTLoudnessDetector(dsp::LoudnessSettings settings, float rate) noexcept
        : detector(settings, rate) {}
};
struct FTGainSmoother {
    dsp::GainSmoother smoother;
    FTGainSmoother(dsp::LoudnessSettings settings, float rate) noexcept
        : smoother(settings, rate) {}
};

float ft_soft_limiter_apply(float sample) { return dsp::softLimit(sample); }
void ft_soft_limiter_process(float *samples, uint32_t sample_count) {
    dsp::softLimitBuffer(samples, sample_count);
}

FTLoudnessEqualizer *ft_loudness_equalizer_create(const FTLoudnessSettings *settings,
                                                  float sample_rate) {
    if (!settings || !validSampleRate(sample_rate) ||
        !dsp::validLoudnessSettings(settingsValue(*settings), sample_rate)) {
        return nullptr;
    }
    auto *result = new (std::nothrow) FTLoudnessEqualizer(settingsValue(*settings), sample_rate);
    if (result && !result->processor.isValid()) {
        delete result;
        return nullptr;
    }
    return result;
}
FTLoudnessEqualizer *ft_loudness_equalizer_clone_configuration(const FTLoudnessEqualizer *source) {
    if (!source) {
        return nullptr;
    }
    auto *result = new (std::nothrow)
        FTLoudnessEqualizer(source->processor.settings(), source->processor.sampleRate());
    if (result && !result->processor.isValid()) {
        delete result;
        return nullptr;
    }
    return result;
}
void ft_loudness_equalizer_destroy(FTLoudnessEqualizer *processor) { delete processor; }
int32_t ft_loudness_equalizer_process(FTLoudnessEqualizer *processor, const float *input,
                                      float *output, uint32_t frame_count, uint32_t channel_count) {
    return processor ? static_cast<int32_t>(
                           processor->processor.process(input, output, frame_count, channel_count))
                     : 1;
}

FTLoudnessCompensator *ft_loudness_compensator_create(double sample_rate) {
    return validSampleRate(sample_rate) ? new (std::nothrow) FTLoudnessCompensator(sample_rate)
                                        : nullptr;
}
FTLoudnessCompensator *
ft_loudness_compensator_clone_configuration(const FTLoudnessCompensator *source) {
    if (!source) {
        return nullptr;
    }
    auto *result = ft_loudness_compensator_create(source->processor.sampleRate());
    if (result && result->processor.updateVolume(source->processor.volume()) != dsp::Status::ok) {
        delete result;
        return nullptr;
    }
    if (result) {
        result->processor.setEnabled(source->processor.isEnabled());
    }
    return result;
}
void ft_loudness_compensator_destroy(FTLoudnessCompensator *processor) { delete processor; }
int32_t ft_loudness_compensator_update_volume(FTLoudnessCompensator *processor, float volume) {
    return processor ? static_cast<int32_t>(processor->processor.updateVolume(volume)) : 1;
}
void ft_loudness_compensator_set_enabled(FTLoudnessCompensator *processor, bool enabled) {
    if (processor) {
        processor->processor.setEnabled(enabled);
    }
}
bool ft_loudness_compensator_is_enabled(const FTLoudnessCompensator *processor) {
    return processor && processor->processor.isEnabled();
}
int32_t ft_loudness_compensator_process(FTLoudnessCompensator *processor, const float *input,
                                        float *output, uint32_t frame_count) {
    return processor
               ? static_cast<int32_t>(processor->processor.process(input, output, frame_count))
               : 1;
}

float ft_loudness_db_to_linear(float db) { return dsp::dbToLinear(db); }
float ft_loudness_linear_to_db(float linear) { return dsp::linearToDB(linear); }
float ft_loudness_time_coefficient(float time_ms, float step_ms) {
    return dsp::timeConstantCoefficient(time_ms, step_ms);
}
float ft_loudness_desired_gain(const FTLoudnessSettings *settings, float level_db) {
    return settings ? dsp::desiredLoudnessGain(settingsValue(*settings), level_db) : invalidScalar;
}

FTKWeightingFilter *ft_k_weighting_create(float sample_rate) {
    return validSampleRate(sample_rate) ? new (std::nothrow) FTKWeightingFilter(sample_rate)
                                        : nullptr;
}
void ft_k_weighting_destroy(FTKWeightingFilter *filter) { delete filter; }
void ft_k_weighting_reset(FTKWeightingFilter *filter) {
    if (filter) {
        filter->filter.reset();
    }
}
float ft_k_weighting_process_sample(FTKWeightingFilter *filter, float sample) {
    return filter ? filter->filter.processSample(sample) : invalidScalar;
}

FTLoudnessDetector *ft_loudness_detector_create(const FTLoudnessSettings *settings,
                                                float sample_rate) {
    if (!settings || !validSampleRate(sample_rate) ||
        !dsp::validLoudnessSettings(settingsValue(*settings), sample_rate)) {
        return nullptr;
    }
    auto *result = new (std::nothrow) FTLoudnessDetector(settingsValue(*settings), sample_rate);
    if (result && !result->detector.isValid()) {
        delete result;
        return nullptr;
    }
    return result;
}
void ft_loudness_detector_destroy(FTLoudnessDetector *detector) { delete detector; }
void ft_loudness_detector_reset(FTLoudnessDetector *detector) {
    if (detector) {
        detector->detector.reset();
    }
}
bool ft_loudness_detector_ingest(FTLoudnessDetector *detector, float sample, float *level_db) {
    return detector && level_db && detector->detector.ingest(sample, *level_db);
}
float ft_loudness_detector_update_envelope(FTLoudnessDetector *detector, float level_db) {
    return detector ? detector->detector.updateEnvelope(level_db) : invalidScalar;
}

FTGainSmoother *ft_gain_smoother_create(const FTLoudnessSettings *settings, float sample_rate) {
    return settings && validSampleRate(sample_rate) &&
                   dsp::validLoudnessSettings(settingsValue(*settings), sample_rate)
               ? new (std::nothrow) FTGainSmoother(settingsValue(*settings), sample_rate)
               : nullptr;
}
void ft_gain_smoother_destroy(FTGainSmoother *smoother) { delete smoother; }
void ft_gain_smoother_reset(FTGainSmoother *smoother, float initial_gain_db) {
    if (smoother) {
        smoother->smoother.reset(initial_gain_db);
    }
}
float ft_gain_smoother_process(FTGainSmoother *smoother, float target_gain_db) {
    return smoother ? smoother->smoother.process(target_gain_db) : invalidScalar;
}

int32_t ft_iso226_reference_data(uint32_t column, double *output) {
    if (!output) {
        return 1;
    }
    return static_cast<int32_t>(dsp::iso226ReferenceData(column, std::span(output, 29)));
}
void ft_iso226_contour(double phon, double *output) {
    if (!output) {
        return;
    }
    const auto result = dsp::iso226Contour(phon);
    std::copy(result.begin(), result.end(), output);
}
void ft_iso226_compensation(double phon, double reference_phon, double amount, double max_gain_db,
                            double *output) {
    if (!output) {
        return;
    }
    const auto result = dsp::iso226Compensation(phon, reference_phon, amount);
    std::transform(result.begin(), result.end(), output, [max_gain_db](double gain) {
        return std::clamp(gain, -max_gain_db, max_gain_db);
    });
}
double ft_iso226_estimated_phon(float volume) { return dsp::estimatedPhon(volume); }
double ft_iso226_interpolate(const double *gains, uint32_t count, double frequency) {
    return (!gains && count) ? 0 : dsp::interpolateCompensation(std::span(gains, count), frequency);
}
void ft_loudness_fitted_gains(double phon, double sample_rate, double output[4]) {
    if (!output) {
        return;
    }
    const auto result = dsp::fittedLoudnessGains(phon, sample_rate);
    std::copy(result.begin(), result.end(), output);
}
void ft_loudness_band_coefficients(const double gains[4], double sample_rate, double output[20]) {
    if (!gains || !output) {
        return;
    }
    dsp::LoudnessBandGains values;
    std::copy_n(gains, 4, values.begin());
    const auto result = dsp::loudnessBandCoefficients(values, sample_rate);
    std::copy(result.begin(), result.end(), output);
}
