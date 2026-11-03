#include "AudioDSP/Dynamics.hpp"

#include <algorithm>
#include <cmath>
#include <new>
#include <numbers>

namespace finetune::dsp {
float dbToLinear(float db) noexcept { return std::pow(10.0F, db / 20.0F); }
float linearToDB(float linear) noexcept { return 20 * std::log10(std::max(linear, 1.0e-12F)); }
float timeConstantCoefficient(float timeMS, float stepMS) noexcept {
    return timeMS <= 0 ? 1 : -std::expm1(-stepMS / timeMS);
}

bool validLoudnessSettings(const LoudnessSettings &s, float sampleRate) noexcept {
    const std::array values{s.targetLoudnessDB,
                            s.maxBoostDB,
                            s.maxCutDB,
                            s.compressionThresholdOffsetDB,
                            s.compressionRatio,
                            s.compressionKneeDB,
                            s.analysisWindowMS,
                            s.analysisHopMS,
                            s.detectorAttackMS,
                            s.detectorReleaseMS,
                            s.gainAttackMS,
                            s.gainReleaseMS,
                            s.noiseFloorThresholdDB,
                            s.lowLevelMaxBoostDB};
    return std::all_of(values.begin(), values.end(), [](float x) { return std::isfinite(x); }) &&
           std::isfinite(sampleRate) && sampleRate > 0 && sampleRate <= 768000 &&
           s.maxBoostDB >= 0 && s.maxCutDB >= 0 && s.compressionRatio >= 1 &&
           s.compressionKneeDB >= 0 && s.analysisWindowMS > 0 && s.analysisWindowMS <= 10000 &&
           s.analysisHopMS > 0 && s.analysisHopMS <= 10000 && s.detectorAttackMS >= 0 &&
           s.detectorReleaseMS >= 0 && s.gainAttackMS >= 0 && s.gainReleaseMS >= 0 &&
           s.lowLevelMaxBoostDB >= 0;
}

float desiredLoudnessGain(const LoudnessSettings &s, float levelDB) noexcept {
    if (levelDB < s.targetLoudnessDB) {
        const float maximum = levelDB < s.noiseFloorThresholdDB
                                  ? std::min(s.lowLevelMaxBoostDB, s.maxBoostDB)
                                  : s.maxBoostDB;
        return std::min(s.targetLoudnessDB - levelDB, maximum);
    }
    const float threshold = s.targetLoudnessDB + s.compressionThresholdOffsetDB;
    const float distance = levelDB - threshold;
    const float slope = 1 / s.compressionRatio - 1;
    float reduction = 0;
    if (s.compressionKneeDB > 0 && std::abs(distance) < s.compressionKneeDB / 2) {
        const float kneePosition = distance + s.compressionKneeDB / 2;
        reduction = slope * kneePosition * kneePosition / (2 * s.compressionKneeDB);
    } else if (distance >= s.compressionKneeDB / 2) {
        reduction = slope * distance;
    }
    return std::max(-s.maxCutDB, reduction);
}

KWeightingFilter::KWeightingFilter(float sampleRate) noexcept {
    // BS.1770-style pre-emphasis plus the cookbook Butterworth approximation used
    // by the portable behavioral tests. This is not an exact conformance claim.
    coefficients_[0] =
        coefficients({FilterType::highShelf, 1681.974450955533, 4, 0.7071752369554196}, sampleRate);
    const double angle = 2 * std::numbers::pi * 38.0 / sampleRate;
    const double cosine = std::cos(angle);
    const double alpha = std::sin(angle) / std::sqrt(2.0);
    const double denominator = 1 + alpha;
    coefficients_[1] = {(1 + cosine) / (2 * denominator), -(1 + cosine) / denominator,
                        (1 + cosine) / (2 * denominator), -2 * cosine / denominator,
                        (1 - alpha) / denominator};
}

float KWeightingFilter::processSample(float sample) noexcept {
    double value = sample;
    for (std::size_t section = 0; section < coefficients_.size(); ++section) {
        const auto &c = coefficients_[section];
        auto &delay = delays_[section];
        const double filtered = c[0] * value + delay[0];
        delay[0] = c[1] * value - c[3] * filtered + delay[1];
        delay[1] = c[2] * value - c[4] * filtered;
        value = filtered;
    }
    return static_cast<float>(value);
}
void KWeightingFilter::reset() noexcept { delays_ = {}; }

LoudnessDetector::LoudnessDetector(const LoudnessSettings &settings, float sampleRate) noexcept {
    if (!validLoudnessSettings(settings, sampleRate)) {
        return;
    }
    windowSize_ = std::max<std::size_t>(
        1, static_cast<std::size_t>(sampleRate * static_cast<double>(settings.analysisWindowMS) /
                                    1000));
    hopSize_ = std::max<std::size_t>(
        1,
        static_cast<std::size_t>(sampleRate * static_cast<double>(settings.analysisHopMS) / 1000));
    window_.reset(new (std::nothrow) float[windowSize_]{});
    attack_ = timeConstantCoefficient(settings.detectorAttackMS, settings.analysisHopMS);
    release_ = timeConstantCoefficient(settings.detectorReleaseMS, settings.analysisHopMS);
}

bool LoudnessDetector::ingest(float weightedSample, float &levelDB) noexcept {
    if (!window_) {
        return false;
    }
    const float squared = weightedSample * weightedSample;
    sumSquares_ += static_cast<double>(squared) - window_[cursor_];
    window_[cursor_] = squared;
    cursor_ = (cursor_ + 1) % windowSize_;
    filled_ = std::min(filled_ + 1, windowSize_);
    if (++hopCount_ < hopSize_) {
        return false;
    }
    hopCount_ = 0;
    const float rawLevel =
        static_cast<float>(10 * std::log10(std::max(sumSquares_ / filled_, 1e-12)));
    levelDB = updateEnvelope(rawLevel);
    return true;
}

float LoudnessDetector::updateEnvelope(float levelDB) noexcept {
    const float coefficient = levelDB > envelopeDB_ ? attack_ : release_;
    envelopeDB_ += coefficient * (levelDB - envelopeDB_);
    return envelopeDB_;
}

void LoudnessDetector::reset() noexcept {
    if (window_) {
        std::fill_n(window_.get(), windowSize_, 0);
    }
    cursor_ = hopCount_ = filled_ = 0;
    sumSquares_ = 0;
    envelopeDB_ = -120;
}

GainSmoother::GainSmoother(const LoudnessSettings &settings, float sampleRate) noexcept
    : attack_(timeConstantCoefficient(settings.gainAttackMS, 1000 / sampleRate)),
      release_(timeConstantCoefficient(settings.gainReleaseMS, 1000 / sampleRate)) {}

float GainSmoother::process(float targetGainDB) noexcept {
    const float coefficient = targetGainDB < gainDB_ ? attack_ : release_;
    gainDB_ += coefficient * (targetGainDB - gainDB_);
    return gainDB_;
}

LoudnessEqualizer::LoudnessEqualizer(const LoudnessSettings &settings, float sampleRate) noexcept
    : settings_(settings), sampleRate_(sampleRate), detector_(settings, sampleRate),
      smoother_(settings, sampleRate) {
    for (auto &filter : weighting_) {
        filter = KWeightingFilter(sampleRate);
    }
}

Status LoudnessEqualizer::process(const float *input, float *output, std::size_t frameCount,
                                  std::size_t channelCount) noexcept {
    if (frameCount == 0) {
        return Status::ok;
    }
    if (!input || !output || channelCount == 0 || channelCount > maxChannels || !isValid()) {
        return Status::invalidArgument;
    }
    if (!settings_.enabled) {
        if (input != output) {
            std::copy_n(input, frameCount * channelCount, output);
        }
        return Status::ok;
    }
    for (std::size_t frame = 0; frame < frameCount; ++frame) {
        double weightedPower = 0;
        for (std::size_t channel = 0; channel < channelCount; ++channel) {
            const float weighted =
                weighting_[channel].processSample(input[frame * channelCount + channel]);
            weightedPower += static_cast<double>(weighted) * weighted;
        }
        float levelDB = 0;
        if (detector_.ingest(static_cast<float>(std::sqrt(weightedPower / channelCount)),
                             levelDB)) {
            targetGainDB_ = desiredLoudnessGain(settings_, levelDB);
        }
        const float gain = dbToLinear(smoother_.process(targetGainDB_));
        for (std::size_t channel = 0; channel < channelCount; ++channel) {
            const auto index = frame * channelCount + channel;
            output[index] = input[index] * gain;
        }
    }
    return Status::ok;
}
} // namespace finetune::dsp
