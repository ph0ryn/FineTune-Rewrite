#pragma once

#include "AudioDSP/AudioDSP.hpp"

#include <array>
#include <cstddef>
#include <memory>
#include <span>

namespace finetune::dsp {

inline constexpr float limiterThreshold = 0.95F;
inline constexpr float limiterCeiling = 1.0F;
inline constexpr float limiterHeadroom = limiterCeiling - limiterThreshold;

// Stateless, zero-latency soft knee. IEEE NaN/Infinity results intentionally propagate.
float softLimit(float sample) noexcept;
void softLimitBuffer(float *samples, std::size_t sampleCount) noexcept;

struct LoudnessSettings {
    float targetLoudnessDB = -12;
    float maxBoostDB = 6;
    float maxCutDB = 4;
    float compressionThresholdOffsetDB = 6;
    float compressionRatio = 1.6F;
    float compressionKneeDB = 8;
    float analysisWindowMS = 400;
    float analysisHopMS = 100;
    float detectorAttackMS = 25;
    float detectorReleaseMS = 600;
    float gainAttackMS = 250;
    float gainReleaseMS = 3000;
    float noiseFloorThresholdDB = -40;
    float lowLevelMaxBoostDB = 0.5F;
    bool enabled = false;
};

float dbToLinear(float db) noexcept;
float linearToDB(float linear) noexcept;
float timeConstantCoefficient(float timeMS, float stepMS) noexcept;
float desiredLoudnessGain(const LoudnessSettings &settings, float levelDB) noexcept;
bool validLoudnessSettings(const LoudnessSettings &settings, float sampleRate) noexcept;

class KWeightingFilter {
  public:
    explicit KWeightingFilter(float sampleRate = 48000) noexcept;
    float processSample(float sample) noexcept;
    void reset() noexcept;

  private:
    std::array<BiquadCoefficients, 2> coefficients_{};
    std::array<std::array<double, 2>, 2> delays_{};
};

class LoudnessDetector {
  public:
    LoudnessDetector(const LoudnessSettings &settings, float sampleRate) noexcept;
    bool isValid() const noexcept { return window_ != nullptr; }
    bool ingest(float weightedSample, float &levelDB) noexcept;
    float updateEnvelope(float levelDB) noexcept;
    void reset() noexcept;

  private:
    std::unique_ptr<float[]> window_;
    std::size_t windowSize_ = 0;
    std::size_t hopSize_ = 0;
    std::size_t cursor_ = 0;
    std::size_t hopCount_ = 0;
    std::size_t filled_ = 0;
    double sumSquares_ = 0;
    float envelopeDB_ = -120;
    float attack_ = 0;
    float release_ = 0;
};

class GainSmoother {
  public:
    GainSmoother(const LoudnessSettings &settings, float sampleRate) noexcept;
    void reset(float initialGainDB = 0) noexcept { gainDB_ = initialGainDB; }
    float process(float targetGainDB) noexcept;

  private:
    float attack_;
    float release_;
    float gainDB_ = 0;
};

class LoudnessEqualizer {
  public:
    LoudnessEqualizer(const LoudnessSettings &settings, float sampleRate) noexcept;
    bool isValid() const noexcept { return detector_.isValid(); }
    const LoudnessSettings &settings() const noexcept { return settings_; }
    float sampleRate() const noexcept { return sampleRate_; }
    Status process(const float *input, float *output, std::size_t frameCount,
                   std::size_t channelCount) noexcept;

  private:
    LoudnessSettings settings_;
    float sampleRate_;
    std::array<KWeightingFilter, maxChannels> weighting_;
    LoudnessDetector detector_;
    GainSmoother smoother_;
    float targetGainDB_ = 0;
};

using LoudnessContour = std::array<double, 29>;
using LoudnessBandGains = std::array<double, 4>;
using LoudnessBandCoefficients = std::array<double, 20>;
Status iso226ReferenceData(std::size_t column, std::span<double> output) noexcept;
LoudnessContour iso226Contour(double phon) noexcept;
LoudnessContour iso226Compensation(double phon, double referencePhon = 80,
                                   double amount = 1) noexcept;
double estimatedPhon(float volume) noexcept;
double interpolateCompensation(std::span<const double> gains, double frequency) noexcept;
LoudnessBandGains fittedLoudnessGains(double phon, double sampleRate) noexcept;
LoudnessBandCoefficients loudnessBandCoefficients(const LoudnessBandGains &gains,
                                                  double sampleRate) noexcept;

class LoudnessCompensator {
  public:
    explicit LoudnessCompensator(double sampleRate) noexcept;
    Status updateVolume(float volume) noexcept;
    void setEnabled(bool enabled) noexcept { processor_.setEnabled(enabled); }
    bool isEnabled() const noexcept { return processor_.isEnabled(); }
    double sampleRate() const noexcept { return sampleRate_; }
    float volume() const noexcept { return volume_; }
    Status process(const float *input, float *output, std::size_t frameCount) noexcept;

  private:
    double sampleRate_;
    float volume_ = 1;
    BiquadProcessor processor_;
};

} // namespace finetune::dsp
