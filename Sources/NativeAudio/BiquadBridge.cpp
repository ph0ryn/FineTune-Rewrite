#include "AudioDSP/AudioDSP.hpp"
#include "AudioDSP/AutoEQ.hpp"
#include "NativeAudioBiquad.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <new>
#include <span>

namespace dsp = finetune::dsp;

struct FTBiquadProcessor {
    dsp::BiquadProcessor processor;
    std::size_t channelCount;
};

namespace {
FTBiquadStatus status(dsp::Status result) noexcept { return static_cast<FTBiquadStatus>(result); }

dsp::FilterSpec filterSpec(FTBiquadFilter filter) noexcept {
    return {static_cast<dsp::FilterType>(filter.type), filter.frequency, filter.gain_db, filter.q};
}
} // namespace

FTBiquadProcessor *ft_biquad_create(uint32_t channel_count) {
    dsp::PreparedBiquad prepared;
    if (dsp::prepareBiquad({}, channel_count, prepared) != dsp::Status::ok) {
        return nullptr;
    }
    auto *instance = new (std::nothrow) FTBiquadProcessor;
    if (!instance) {
        return nullptr;
    }
    instance->channelCount = channel_count;
    instance->processor.configure(prepared);
    return instance;
}

void ft_biquad_destroy(FTBiquadProcessor *processor) { delete processor; }

FTBiquadStatus ft_biquad_replace_coefficients(FTBiquadProcessor *processor,
                                              const double *coefficients, uint32_t section_count) {
    if (!processor || section_count > dsp::maxBiquadSections || (!coefficients && section_count)) {
        return FT_BIQUAD_INVALID_ARGUMENT;
    }
    dsp::PreparedBiquad prepared;
    const auto result =
        dsp::prepareBiquad(std::span(coefficients, static_cast<std::size_t>(section_count) * 5),
                           processor->channelCount, prepared);
    if (result != dsp::Status::ok) {
        return status(result);
    }
    return status(processor->processor.configure(prepared));
}

FTBiquadStatus ft_biquad_prepare_autoeq(FTBiquadProcessor *processor, const FTBiquadFilter *filters,
                                        uint32_t filter_count, double actual_sample_rate,
                                        double profile_optimized_rate, float preamp_db,
                                        bool preamp_enabled) {
    if (!processor || filter_count > dsp::maxBiquadSections || (!filters && filter_count)) {
        return FT_BIQUAD_INVALID_ARGUMENT;
    }
    std::array<dsp::FilterSpec, dsp::maxBiquadSections> specifications{};
    for (std::size_t i = 0; i < filter_count; ++i) {
        specifications[i] = filterSpec(filters[i]);
    }
    dsp::PreparedBiquad prepared;
    const auto result = dsp::prepareAutoEQ(std::span(specifications).first(filter_count),
                                           actual_sample_rate, profile_optimized_rate, preamp_db,
                                           preamp_enabled, processor->channelCount, prepared);
    if (result != dsp::Status::ok) {
        return status(result);
    }
    return status(processor->processor.configure(prepared));
}

FTBiquadStatus ft_biquad_copy_configuration(const FTBiquadProcessor *source,
                                            FTBiquadProcessor *destination) {
    if (!source || !destination || source->channelCount != destination->channelCount) {
        return FT_BIQUAD_INVALID_ARGUMENT;
    }
    if (source == destination) {
        return FT_BIQUAD_OK;
    }
    const auto result = destination->processor.configure(source->processor.configuration());
    if (result == dsp::Status::ok) {
        destination->processor.setEnabled(source->processor.isEnabled());
    }
    return status(result);
}

void ft_biquad_set_enabled(FTBiquadProcessor *processor, bool enabled) {
    if (processor) {
        processor->processor.setEnabled(enabled);
    }
}

bool ft_biquad_is_enabled(const FTBiquadProcessor *processor) {
    return processor && processor->processor.isEnabled();
}

void ft_biquad_reset(FTBiquadProcessor *processor) {
    if (processor) {
        processor->processor.reset();
    }
}

FTBiquadStatus ft_biquad_process(FTBiquadProcessor *processor, const float *input, float *output,
                                 uint32_t frame_count) {
    if (!processor) {
        return FT_BIQUAD_INVALID_ARGUMENT;
    }
    return status(processor->processor.processInterleaved(input, output, frame_count,
                                                          processor->channelCount));
}

FTBiquadStatus ft_biquad_coefficients(FTBiquadFilter filter, double sample_rate, double output[5]) {
    if (!output) {
        return FT_BIQUAD_INVALID_ARGUMENT;
    }
    const auto completed = dsp::coefficients(filterSpec(filter), sample_rate);
    if (!std::all_of(completed.begin(), completed.end(),
                     [](double x) { return std::isfinite(x); })) {
        return FT_BIQUAD_INVALID_ARGUMENT;
    }
    std::copy(completed.begin(), completed.end(), output);
    return FT_BIQUAD_OK;
}

double ft_biquad_prewarp(double frequency, double source_rate, double target_rate) {
    return dsp::preWarpFrequency(frequency, source_rate, target_rate);
}

FTBiquadStatus ft_biquad_graphic_coefficients(const float *gains, uint32_t gain_count,
                                              double sample_rate, double output[50]) {
    if (!output || (!gains && gain_count) || !std::isfinite(sample_rate) || sample_rate <= 0) {
        return FT_BIQUAD_INVALID_ARGUMENT;
    }
    const auto completed = dsp::graphicEQCoefficients(std::span(gains, gain_count), sample_rate);
    if (!std::all_of(completed.begin(), completed.end(),
                     [](double x) { return std::isfinite(x); })) {
        return FT_BIQUAD_INVALID_CONFIGURATION;
    }
    std::copy(completed.begin(), completed.end(), output);
    return FT_BIQUAD_OK;
}

FTBiquadStatus ft_biquad_autoeq_coefficients(const FTBiquadFilter *filters, uint32_t filter_count,
                                             double sample_rate, double profile_optimized_rate,
                                             double *output) {
    if (filter_count > dsp::maxBiquadSections || ((!filters || !output) && filter_count)) {
        return FT_BIQUAD_INVALID_ARGUMENT;
    }
    std::array<dsp::FilterSpec, dsp::maxBiquadSections> specifications{};
    for (std::size_t i = 0; i < filter_count; ++i) {
        specifications[i] = filterSpec(filters[i]);
    }
    return status(dsp::autoEQCoefficients(
        std::span(specifications).first(filter_count), sample_rate, profile_optimized_rate,
        std::span(output, static_cast<std::size_t>(filter_count) * 5)));
}
