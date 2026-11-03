// SPDX-License-Identifier: GPL-3.0-only
// Derived unit guarantees from ronitsingh10/FineTune at
// 2285279d36d3f8115c1c2d4aecd904f1bdf96a51.
// Original: FineTuneTests/LoudnessEqualizerTests.swift, eleven pure numerical scenarios.
// Adaptation: invoke the real C++ kernels directly; no legacy Swift/C test facade.
// License text: Tests/UpstreamCompatibilityTests/COPYING.
#include "AudioDSP/Dynamics.hpp"
#include "DSPTestUnits.hpp"

#include <array>
#include <cmath>
#include <numbers>

namespace finetune::test {
namespace {
using namespace finetune::dsp;

// Source: LoudnessEqualizerTests.dbLinearRoundTrip
void dbLinearRoundTrip() {
    for (float db : {-60.0F, -20.0F, -6.0F, 0.0F, 6.0F, 20.0F}) {
        const float result = linearToDB(dbToLinear(db));
        check(std::abs(result - db) < 0.001F, "dB round-trip error < 0.001", result, db);
    }
    const float unity = dbToLinear(0);
    check(std::abs(unity - 1) < 0.0001F, "zero dB maps to unity within 0.0001", unity, 1);
    const float zeroDB = linearToDB(0);
    check(zeroDB < -100, "linear zero maps below -100 dB", zeroDB, -100);
}

// Source: LoudnessEqualizerTests.smoothingCoefficientOrder
void smoothingCoefficientOrder() {
    const float fast = timeConstantCoefficient(10, 1), slow = timeConstantCoefficient(100, 1);
    check(fast > slow, "10 ms coefficient exceeds 100 ms coefficient", fast, slow);
    check(fast > 0 && fast < 1, "fast coefficient in (0,1)", fast, 1);
    check(slow > 0 && slow < 1, "slow coefficient in (0,1)", slow, 1);
}

// Source: LoudnessEqualizerTests.kWeightingResetDeterminism
void kWeightingResetDeterminism() {
    KWeightingFilter filter(48000);
    const float first = filter.processSample(1);
    for (int i = 0; i < 99; ++i) {
        filter.processSample(0);
    }
    filter.reset();
    const float second = filter.processSample(1);
    check(first == second, "reset reproduces exact first impulse sample", second, first);
}

float weightingGainDB(double frequency) {
    KWeightingFilter filter(48000);
    double squares = 0;
    constexpr int frameCount = 8192, skipFrames = 2048;
    for (int i = 0; i < frameCount; ++i) {
        const float phase = static_cast<float>(2 * std::numbers::pi * frequency * i / 48000);
        const float output = filter.processSample(0.5F * std::sin(phase));
        if (i >= skipFrames) {
            squares += static_cast<double>(output * output);
        }
    }
    const float outputRMS = static_cast<float>(std::sqrt(squares / (frameCount - skipFrames)));
    return 20 * std::log10(outputRMS / (0.5F / std::sqrt(2.0F)));
}

// Source: LoudnessEqualizerTests.kWeightingFrequencyResponse, original five argument rows.
template <int Frequency, int MinimumTenths, int MaximumTenths> void kWeightingFrequencyResponse() {
    const float measured = weightingGainDB(Frequency);
    const float minimum = MinimumTenths / 10.0F, maximum = MaximumTenths / 10.0F;
    check(measured >= minimum, "K-weighting response lower dB bound", measured, minimum);
    check(measured <= maximum, "K-weighting response upper dB bound", measured, maximum);
}

// Source: LoudnessEqualizerTests.kWeightingMonotonicHFBoost
void kWeightingMonotonicHFBoost() {
    const float one = weightingGainDB(1000), two = weightingGainDB(2000),
                four = weightingGainDB(4000);
    check(four > two, "4 kHz gain exceeds 2 kHz gain", four, two);
    check(two > one, "2 kHz gain exceeds 1 kHz gain", two, one);
}

// Source: LoudnessEqualizerTests.ingestReturnsAtHopBoundaries
void ingestReturnsAtHopBoundaries() {
    LoudnessSettings settings;
    settings.analysisWindowMS = 30;
    settings.analysisHopMS = 15;
    LoudnessDetector detector(settings, 48000);
    int levels = 0, absent = 0;
    for (int i = 0; i < 1440; ++i) {
        float level = 0;
        const bool ready = detector.ingest(0.5F, level);
        const bool boundary = i == 719 || i == 1439;
        check(ready == boundary, "level exists exactly at samples 719/1439", ready, boundary);
        levels += ready ? 1 : 0;
        absent += ready ? 0 : 1;
    }
    check(levels == 2, "exactly two analysis hops", levels, 2);
    check(absent == 1438, "all other samples have no new level", absent, 1438);
}

// Source: LoudnessEqualizerTests.ingestConvergesToExpectedLevel
void ingestConvergesToExpectedLevel() {
    LoudnessSettings settings;
    settings.analysisWindowMS = 30;
    settings.analysisHopMS = 15;
    settings.detectorAttackMS = settings.detectorReleaseMS = 10;
    LoudnessDetector detector(settings, 48000);
    float last = -120;
    for (int i = 0; i < 720 * 25; ++i) {
        float level = 0;
        if (detector.ingest(0.5F, level)) {
            last = level;
        }
    }
    const float expected = 10 * std::log10(0.5F * 0.5F);
    check(std::abs(last - expected) < 0.5F, "DC RMS level within 0.5 dB", last, expected);
}

// Source: LoudnessEqualizerTests.detectorAttackFasterThanRelease
void detectorAttackFasterThanRelease() {
    LoudnessSettings settings;
    settings.detectorAttackMS = 15;
    settings.detectorReleaseMS = 120;
    LoudnessDetector detector(settings, 48000);
    float attack = -30;
    for (int i = 0; i < 5; ++i) {
        attack = detector.updateEnvelope(-10);
    }
    detector.reset();
    for (int i = 0; i < 20; ++i) {
        detector.updateEnvelope(-10);
    }
    float release = -10;
    for (int i = 0; i < 5; ++i) {
        release = detector.updateEnvelope(-30);
    }
    const float attackDistance = attack - (-30), releaseDistance = -10 - release;
    check(attackDistance > releaseDistance, "detector attack covers more dB than release",
          attackDistance, releaseDistance);
}

// Source: LoudnessEqualizerTests.gainComputerClamps
void gainComputerClamps() {
    LoudnessSettings settings;
    settings.targetLoudnessDB = -12;
    settings.maxBoostDB = 4;
    settings.maxCutDB = 6;
    settings.compressionThresholdOffsetDB = 4;
    settings.compressionRatio = 1.5F;
    settings.compressionKneeDB = 6;
    settings.noiseFloorThresholdDB = -80;
    const float quiet = desiredLoudnessGain(settings, -18);
    const float knee = desiredLoudnessGain(settings, -10);
    const float loud = desiredLoudnessGain(settings, 12);
    check(quiet == 4, "quiet material clamps to +4 dB boost", quiet, 4);
    check(knee < 0, "soft knee gently reduces gain", knee, 0);
    check(knee > -1.5F, "soft-knee reduction remains above -1.5 dB", knee, -1.5);
    check(loud == -6, "loud material clamps to -6 dB cut", loud, -6);
}

// Source: LoudnessEqualizerTests.gainComputerNoiseFloorProtection
void gainComputerNoiseFloorProtection() {
    LoudnessSettings settings;
    settings.targetLoudnessDB = -20;
    settings.maxBoostDB = 10;
    settings.noiseFloorThresholdDB = -55;
    settings.lowLevelMaxBoostDB = 4;
    const float gain = desiredLoudnessGain(settings, -70);
    check(gain <= 4, "noise-floor boost does not exceed +4 dB", gain, 4);
}

// Source: LoudnessEqualizerTests.gainSmootherAsymmetry
void gainSmootherAsymmetry() {
    LoudnessSettings settings;
    settings.gainAttackMS = 30;
    settings.gainReleaseMS = 700;
    GainSmoother smoother(settings, 48000);
    smoother.reset(0);
    float attack = 0;
    for (int i = 0; i < 10; ++i) {
        attack = smoother.process(-10);
    }
    smoother.reset(-10);
    float release = -10;
    for (int i = 0; i < 10; ++i) {
        release = smoother.process(0);
    }
    const float reductionDistance = std::abs(attack), recoveryDistance = std::abs(release - (-10));
    check(recoveryDistance < reductionDistance, "gain recovery is slower than reduction",
          recoveryDistance, reductionDistance);
}

constexpr std::array<NamedUnit, 15> units{{
    {"Tools/DSPTests/LoudnessCompatibilityTests.cpp::dbLinearRoundTrip", dbLinearRoundTrip},
    {"Tools/DSPTests/LoudnessCompatibilityTests.cpp::smoothingCoefficientOrder",
     smoothingCoefficientOrder},
    {"Tools/DSPTests/LoudnessCompatibilityTests.cpp::kWeightingResetDeterminism",
     kWeightingResetDeterminism},
    {"Tools/DSPTests/LoudnessCompatibilityTests.cpp::kWeightingFrequencyResponse.100Hz",
     kWeightingFrequencyResponse<100, -10, 10>},
    {"Tools/DSPTests/LoudnessCompatibilityTests.cpp::kWeightingFrequencyResponse.1000Hz",
     kWeightingFrequencyResponse<1000, -10, 10>},
    {"Tools/DSPTests/LoudnessCompatibilityTests.cpp::kWeightingFrequencyResponse.2000Hz",
     kWeightingFrequencyResponse<2000, 5, 35>},
    {"Tools/DSPTests/LoudnessCompatibilityTests.cpp::kWeightingFrequencyResponse.4000Hz",
     kWeightingFrequencyResponse<4000, 20, 50>},
    {"Tools/DSPTests/LoudnessCompatibilityTests.cpp::kWeightingFrequencyResponse.10000Hz",
     kWeightingFrequencyResponse<10000, 20, 50>},
    {"Tools/DSPTests/LoudnessCompatibilityTests.cpp::kWeightingMonotonicHFBoost",
     kWeightingMonotonicHFBoost},
    {"Tools/DSPTests/LoudnessCompatibilityTests.cpp::ingestReturnsAtHopBoundaries",
     ingestReturnsAtHopBoundaries},
    {"Tools/DSPTests/LoudnessCompatibilityTests.cpp::ingestConvergesToExpectedLevel",
     ingestConvergesToExpectedLevel},
    {"Tools/DSPTests/LoudnessCompatibilityTests.cpp::detectorAttackFasterThanRelease",
     detectorAttackFasterThanRelease},
    {"Tools/DSPTests/LoudnessCompatibilityTests.cpp::gainComputerClamps", gainComputerClamps},
    {"Tools/DSPTests/LoudnessCompatibilityTests.cpp::gainComputerNoiseFloorProtection",
     gainComputerNoiseFloorProtection},
    {"Tools/DSPTests/LoudnessCompatibilityTests.cpp::gainSmootherAsymmetry", gainSmootherAsymmetry},
}};
} // namespace

std::span<const NamedUnit> loudnessCompatibilityUnits() noexcept { return units; }
} // namespace finetune::test
