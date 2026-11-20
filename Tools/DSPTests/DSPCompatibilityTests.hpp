#pragma once

#include "AudioDSP/AudioDSP.hpp"
#include "AudioDSP/Dynamics.hpp"
#include "DSPTestUnits.hpp"

#include <algorithm>
#include <array>
#include <cfloat>
#include <cmath>
#include <complex>
#include <cstddef>
#include <limits>
#include <memory>
#include <numbers>
#include <vector>

namespace finetune::test::upstream_dsp {

namespace {

inline double dbGain(double magnitude) noexcept { return 20.0 * std::log10(magnitude); }

inline double biquadMagnitudeAtFrequency(std::span<const double> c, double frequency,
                                         double sampleRate) noexcept {
    const double omega = 2.0 * std::numbers::pi * frequency / sampleRate;
    const std::complex<double> zInv = std::polar(1.0, -omega);
    const std::complex<double> zInv2 = zInv * zInv;
    const std::complex<double> num = c[0] + c[1] * zInv + c[2] * zInv2;
    const std::complex<double> den = 1.0 + c[3] * zInv + c[4] * zInv2;
    return std::abs(num / den);
}

inline double cascadeMagnitudeDB(std::span<const double> coefficients, std::size_t sections,
                                 double frequency, double sampleRate) noexcept {
    double mag = 1.0;
    for (std::size_t s = 0; s < sections; ++s) {
        mag *= biquadMagnitudeAtFrequency(coefficients.subspan(s * 5, 5), frequency, sampleRate);
    }
    return dbGain(std::max(mag, 1e-12));
}

inline void checkJuryStable(std::span<const double> c, const char *label) {
    check(c.size() >= 5, label, static_cast<double>(c.size()), 5.0);
    for (std::size_t i = 0; i < 5; ++i) {
        check(std::isfinite(c[i]), label, c[i], 0.0);
    }
    const double a1 = c[3];
    const double a2 = c[4];
    check(std::abs(a2) < 1.0, "Jury stability |a2| < 1", std::abs(a2), 0.99);
    check(1.0 + a1 + a2 > 0.0, "Jury stability 1 + a1 + a2 > 0", 1.0 + a1 + a2, 1e-6);
    check(1.0 - a1 + a2 > 0.0, "Jury stability 1 - a1 + a2 > 0", 1.0 - a1 + a2, 1e-6);
}

inline std::vector<float> makeStereoSine(double frequency, double amplitude, double sampleRate,
                                         std::size_t frameCount) {
    std::vector<float> buf(frameCount * 2);
    const double omega = 2.0 * std::numbers::pi * frequency / sampleRate;
    for (std::size_t i = 0; i < frameCount; ++i) {
        const float sample =
            static_cast<float>(amplitude * std::sin(omega * static_cast<double>(i)));
        buf[i * 2] = sample;
        buf[i * 2 + 1] = sample;
    }
    return buf;
}

inline float measureRMS(const std::vector<float> &buf, std::size_t channel, std::size_t frameCount,
                        std::size_t skipFrames) {
    double sumSquares = 0.0;
    const std::size_t measureFrames = frameCount - skipFrames;
    for (std::size_t i = skipFrames; i < frameCount; ++i) {
        const double s = buf[i * 2 + channel];
        sumSquares += s * s;
    }
    return static_cast<float>(std::sqrt(sumSquares / static_cast<double>(measureFrames)));
}

inline std::unique_ptr<dsp::BiquadProcessor> makeSingleSectionProcessor(dsp::FilterType type,
                                                                        double frequency,
                                                                        float gainDB, double q,
                                                                        double sampleRate) {
    const auto coeffs = dsp::coefficients({type, frequency, gainDB, q}, sampleRate);
    dsp::PreparedBiquad prepared;
    const auto status = dsp::prepareBiquad(coeffs, 2, prepared);
    check(status == dsp::Status::ok, "prepareBiquad ok", static_cast<double>(status), 0.0);
    auto proc = std::make_unique<dsp::BiquadProcessor>();
    check(proc->configure(prepared) == dsp::Status::ok, "configure ok", 1.0, 1.0);
    return proc;
}

inline std::unique_ptr<dsp::BiquadProcessor>
makeGraphicEQProcessor(std::span<const float, 10> gains, double sampleRate) {
    const auto coeffs = dsp::graphicEQCoefficients(gains, sampleRate);
    dsp::PreparedBiquad prepared;
    const auto status = dsp::prepareBiquad(coeffs, 2, prepared);
    check(status == dsp::Status::ok, "prepareBiquad graphicEQ ok", static_cast<double>(status),
          0.0);
    auto proc = std::make_unique<dsp::BiquadProcessor>();
    check(proc->configure(prepared) == dsp::Status::ok, "configure graphicEQ ok", 1.0, 1.0);
    return proc;
}

// MARK: - SoftLimiter Adversarial Tests

inline void softLimiterConstantsAndPassthrough() {
    check(dsp::limiterThreshold == 0.95F, "limiterThreshold", dsp::limiterThreshold, 0.95);
    check(dsp::limiterCeiling == 1.0F, "limiterCeiling", dsp::limiterCeiling, 1.0);
    const float expectedHeadroom = dsp::limiterCeiling - dsp::limiterThreshold;
    check(std::abs(dsp::limiterHeadroom - expectedHeadroom) < 1e-6F, "limiterHeadroom",
          dsp::limiterHeadroom, expectedHeadroom);

    const std::array<float, 9> passthroughInputs{0.0F,   0.1F,  0.5F,   0.94F, 0.95F,
                                                 -0.01F, -0.5F, -0.94F, -0.95F};
    for (const float x : passthroughInputs) {
        check(dsp::softLimit(x) == x, "bit-exact linear passthrough", dsp::softLimit(x), x);
    }
    check(dsp::softLimit(0.0F) == 0.0F && !std::signbit(dsp::softLimit(0.0F)), "zero passthrough",
          dsp::softLimit(0.0F), 0.0);
}

inline void softLimiterCeilingAndAsymptotic() {
    const std::array<float, 6> sub1k{1.0F, 2.0F, 10.0F, 100.0F, 500.0F, 1000.0F};
    for (const float x : sub1k) {
        const float pos = dsp::softLimit(x);
        const float neg = dsp::softLimit(-x);
        check(pos < dsp::limiterCeiling && pos > dsp::limiterThreshold, "pos bounded below 1.0",
              pos, 1.0);
        check(neg > -dsp::limiterCeiling && neg < -dsp::limiterThreshold, "neg bounded above -1.0",
              neg, -1.0);
    }

    const std::array<float, 3> extreme{1e6F, 1e10F, FLT_MAX};
    for (const float x : extreme) {
        check(std::abs(dsp::softLimit(x)) <= dsp::limiterCeiling, "extreme <= ceiling",
              dsp::softLimit(x), dsp::limiterCeiling);
        check(std::abs(dsp::softLimit(-x)) <= dsp::limiterCeiling, "neg extreme <= ceiling",
              dsp::softLimit(-x), dsp::limiterCeiling);
    }

    check(dsp::softLimit(100.0F) >= 0.99F, "asymptotic at 100", dsp::softLimit(100.0F), 0.99);
    check(dsp::softLimit(10000.0F) >= 0.9999F, "asymptotic at 10000", dsp::softLimit(10000.0F),
          0.9999);
}

inline void softLimiterMonotonicityAndSymmetry() {
    float prevPos = -1.0F;
    float prevNeg = 1.0F;
    for (int i = 0; i <= 200; ++i) {
        const float x = static_cast<float>(i) * 0.05F;
        const float yPos = dsp::softLimit(x);
        const float yNeg = dsp::softLimit(-x);
        check(yPos >= prevPos, "positive monotonicity", yPos, prevPos);
        check(yNeg <= prevNeg, "negative monotonicity", yNeg, prevNeg);
        check(yNeg == -yPos, "odd symmetry", yNeg, -yPos);
        if (x > 0.0F) {
            check(yPos > 0.0F && yNeg < 0.0F, "sign preservation", yPos, 1.0);
        }
        prevPos = yPos;
        prevNeg = yNeg;
    }
}

inline void softLimiterContinuityAndConcavity() {
    const float t = dsp::limiterThreshold;
    const float eps = 1e-4F;
    const float yLeft = dsp::softLimit(t - eps);
    const float yAt = dsp::softLimit(t);
    const float yRight = dsp::softLimit(t + eps);
    check(std::abs(yAt - yLeft) < 2e-4F, "left continuity at threshold", yAt, yLeft);
    check(std::abs(yRight - yAt) < 2e-4F, "right continuity at threshold", yRight, yAt);

    const float slopeLeft = (yAt - yLeft) / eps;
    const float slopeRight = (yRight - yAt) / eps;
    check(std::abs(slopeLeft - 1.0F) < 1e-2F, "left derivative ~1", slopeLeft, 1.0);
    check(std::abs(slopeRight - 1.0F) < 2e-2F, "right derivative ~1", slopeRight, 1.0);

    const std::array<float, 5> points{0.96F, 1.0F, 1.5F, 2.0F, 5.0F};
    const float h = 1e-3F;
    float prevDeriv = 2.0F;
    for (const float x : points) {
        const float deriv = (dsp::softLimit(x + h) - dsp::softLimit(x - h)) / (2.0F * h);
        check(deriv > 0.0F && deriv < prevDeriv, "decreasing derivative above threshold", deriv,
              prevDeriv);
        prevDeriv = deriv;
    }
}

inline void softLimiterSpecialFloatsAndBuffer() {
    // Upstream contract: non-finite input propagates as NaN, never as a valid
    // sample — the NaN safety net in the processing chain depends on this.
    const float nanOut = dsp::softLimit(std::numeric_limits<float>::quiet_NaN());
    check(std::isnan(nanOut), "NaN input produces NaN output, not a valid sample", nanOut,
          std::numeric_limits<float>::quiet_NaN());

    const float posInfOut = dsp::softLimit(std::numeric_limits<float>::infinity());
    const float negInfOut = dsp::softLimit(-std::numeric_limits<float>::infinity());
    check(std::isnan(posInfOut), "+Inf input produces NaN output", posInfOut,
          std::numeric_limits<float>::quiet_NaN());
    check(std::isnan(negInfOut), "-Inf input produces NaN output", negInfOut,
          std::numeric_limits<float>::quiet_NaN());

    const float subnormal = std::numeric_limits<float>::denorm_min();
    check(dsp::softLimit(subnormal) == subnormal, "subnormal passthrough",
          dsp::softLimit(subnormal), subnormal);

    dsp::softLimitBuffer(nullptr, 0);

    std::array<float, 6> mixed{0.2F, 0.95F, 1.5F, -2.0F, -0.5F, 3.0F};
    const std::array<float, 6> orig = mixed;
    dsp::softLimitBuffer(mixed.data(), mixed.size());
    for (std::size_t i = 0; i < mixed.size(); ++i) {
        check(std::abs(mixed[i] - dsp::softLimit(orig[i])) < 1e-6F,
              "softLimitBuffer matches scalar", mixed[i], dsp::softLimit(orig[i]));
    }

    std::vector<float> large(100000, 1.25F);
    dsp::softLimitBuffer(large.data(), large.size());
    const float expected = dsp::softLimit(1.25F);
    check(large.front() == expected && large.back() == expected, "100k buffer limit", large.back(),
          expected);
}

// MARK: - BiquadMath & Stability Tests

inline void biquadCoefficientsAndFrequencyResponse() {
    const double sr = 48000.0;
    const auto flat = dsp::coefficients({dsp::FilterType::peaking, 1000.0, 0.0F, 1.4}, sr);
    check(std::abs(flat[0] - 1.0) < 1e-12 && std::abs(flat[1] - flat[3]) < 1e-12 &&
              std::abs(flat[2] - flat[4]) < 1e-12,
          "0dB peaking cancels poles and zeros", flat[0], 1.0);
    check(std::abs(dbGain(biquadMagnitudeAtFrequency(flat, 1000.0, sr))) < 1e-9,
          "0dB peaking has 0dB response", dbGain(biquadMagnitudeAtFrequency(flat, 1000.0, sr)),
          0.0);

    const auto boost = dsp::coefficients({dsp::FilterType::peaking, 1000.0, 6.0F, 1.4}, sr);
    const double boostAtCenter = dbGain(biquadMagnitudeAtFrequency(boost, 1000.0, sr));
    const double boostAtDC = dbGain(biquadMagnitudeAtFrequency(boost, 0.0, sr));
    const double boostAtNyquist = dbGain(biquadMagnitudeAtFrequency(boost, sr * 0.5, sr));
    check(std::abs(boostAtCenter - 6.0) < 0.05, "peaking center gain +6dB", boostAtCenter, 6.0);
    check(std::abs(boostAtDC) < 1e-4, "peaking DC unity", boostAtDC, 0.0);
    check(std::abs(boostAtNyquist) < 1e-4, "peaking Nyquist unity", boostAtNyquist, 0.0);

    // Boost and cut are reciprocal: normalized b0 of +g dB and -g dB peaking
    // filters multiply to 1 (upstream BiquadMathTests.boostCutSymmetry pin).
    for (const float gainDB : {3.0F, 6.0F, 12.0F}) {
        const auto boost = dsp::coefficients({dsp::FilterType::peaking, 1000.0, gainDB, 1.4}, sr);
        const auto cut = dsp::coefficients({dsp::FilterType::peaking, 1000.0, -gainDB, 1.4}, sr);
        check(std::abs(boost[0] * cut[0] - 1.0) < 1e-10, "peaking boost/cut b0 reciprocity",
              boost[0] * cut[0], 1.0);
    }

    const auto lowShelf = dsp::coefficients({dsp::FilterType::lowShelf, 200.0, 6.0F, 0.707}, sr);
    const double lsDC = dbGain(biquadMagnitudeAtFrequency(lowShelf, 0.0, sr));
    const double lsNyquist = dbGain(biquadMagnitudeAtFrequency(lowShelf, sr * 0.5, sr));
    check(std::abs(lsDC - 6.0) < 0.05, "lowShelf DC gain +6dB", lsDC, 6.0);
    check(std::abs(lsNyquist) < 1e-4, "lowShelf Nyquist unity", lsNyquist, 0.0);

    const auto highShelf =
        dsp::coefficients({dsp::FilterType::highShelf, 4000.0, -6.0F, 0.707}, sr);
    const double hsDC = dbGain(biquadMagnitudeAtFrequency(highShelf, 0.0, sr));
    const double hsNyquist = dbGain(biquadMagnitudeAtFrequency(highShelf, sr * 0.5, sr));
    check(std::abs(hsDC) < 1e-4, "highShelf DC unity", hsDC, 0.0);
    check(std::abs(hsNyquist - (-6.0)) < 0.05, "highShelf Nyquist -6dB", hsNyquist, -6.0);
}

inline void biquadExhaustiveJuryStability() {
    const std::array<double, 8> rates{8000.0,  16000.0, 22050.0, 44100.0,
                                      48000.0, 88200.0, 96000.0, 192000.0};
    const std::array<double, 13> freqs{20.0,   31.25,  62.5,   125.0,   250.0,   500.0,  1000.0,
                                       2000.0, 4000.0, 8000.0, 12000.0, 16000.0, 19000.0};
    const std::array<float, 5> gains{-12.0F, -6.0F, 0.0F, 6.0F, 12.0F};
    const std::array<double, 5> qs{0.1, 0.5, 1.4, 5.0, 10.0};
    const std::array<dsp::FilterType, 3> types{dsp::FilterType::peaking, dsp::FilterType::lowShelf,
                                               dsp::FilterType::highShelf};

    for (const auto type : types) {
        for (const double sr : rates) {
            for (const double f : freqs) {
                if (f >= sr * 0.5) {
                    continue;
                }
                for (const float g : gains) {
                    for (const double q : qs) {
                        const auto c = dsp::coefficients({type, f, g, q}, sr);
                        checkJuryStable(c, "Jury pole stability grid");
                    }
                }
            }
        }
    }

    // Worst-case 8kHz near-Nyquist and production 10-band max gain
    for (const double f : {10.0, 100.0, 1000.0, 3900.0, 3999.0}) {
        for (const float g : {-12.0F, 12.0F}) {
            for (const double q : {0.1, 1.4, 10.0}) {
                checkJuryStable(dsp::coefficients({dsp::FilterType::peaking, f, g, q}, 8000.0),
                                "8kHz near-Nyquist Jury stability");
            }
        }
    }

    // Zero frequency produces finite pole-zero cancelling marginally-stable coefficients
    const auto zeroFreq = dsp::coefficients({dsp::FilterType::peaking, 0.0, 12.0F, 1.4}, 48000.0);
    check(zeroFreq[0] == 1.0 && zeroFreq[1] == zeroFreq[3] && zeroFreq[2] == zeroFreq[4] &&
              std::abs(zeroFreq[4]) <= 1.0,
          "zero frequency returns finite pole-zero unity", zeroFreq[0], 1.0);
}

inline void biquadGraphicAndBluetoothHFP() {
    const std::array<float, 10> flatGains{};
    const auto flatCoeffs = dsp::graphicEQCoefficients(flatGains, 48000.0);
    for (std::size_t i = 0; i < 10; ++i) {
        const auto sec = std::span<const double>(flatCoeffs).subspan(i * 5, 5);
        check(std::abs(sec[0] - 1.0) < 1e-12 && std::abs(sec[1] - sec[3]) < 1e-12 &&
                  std::abs(sec[2] - sec[4]) < 1e-12,
              "flat band unity", sec[0], 1.0);
    }

    const std::array<float, 10> maxGains{12, 12, 12, 12, 12, 12, 12, 12, 12, 12};
    for (const double sr : {8000.0, 44100.0, 48000.0, 96000.0}) {
        const auto c = dsp::graphicEQCoefficients(maxGains, sr);
        for (std::size_t band = 0; band < 10; ++band) {
            checkJuryStable(std::span<const double>(c).subspan(band * 5, 5), "production max gain");
        }
    }

    // 8kHz BT HFP: bands at 4kHz (idx 7), 8kHz (idx 8), 16kHz (idx 9) >= Nyquist must be unity
    const auto hfp8k = dsp::graphicEQCoefficients(maxGains, 8000.0);
    for (std::size_t band = 0; band < 7; ++band) {
        check(hfp8k[band * 5 + 1] != 0.0, "8kHz below-Nyquist band active",
              static_cast<double>(band), 1.0);
    }
    for (std::size_t band = 7; band < 10; ++band) {
        check(hfp8k[band * 5] == 1.0 && hfp8k[band * 5 + 1] == 0.0 && hfp8k[band * 5 + 3] == 0.0,
              "8kHz above-Nyquist band bypassed", hfp8k[band * 5], 1.0);
    }

    // 4kHz: 2kHz..16kHz bypassed
    const auto sr4k = dsp::graphicEQCoefficients(maxGains, 4000.0);
    for (std::size_t band = 6; band < 10; ++band) {
        check(sr4k[band * 5] == 1.0 && sr4k[band * 5 + 3] == 0.0, "4kHz above-Nyquist bypassed",
              sr4k[band * 5], 1.0);
    }
}

inline void biquadAutoEQAndPreWarp() {
    check(dsp::preWarpFrequency(1000.0, 48000.0, 48000.0) == 1000.0, "same rate preWarp identity",
          dsp::preWarpFrequency(1000.0, 48000.0, 48000.0), 1000.0);

    const double warped = dsp::preWarpFrequency(10000.0, 44100.0, 48000.0);
    const double roundtrip = dsp::preWarpFrequency(warped, 48000.0, 44100.0);
    check(std::abs(roundtrip - 10000.0) < 1e-6, "preWarp roundtrip", roundtrip, 10000.0);
    check(warped > 10000.0, "preWarp shifts 10kHz from 44.1k->48k upward", warped, 10191.0);

    const double nearNyquist = dsp::preWarpFrequency(21500.0, 44100.0, 48000.0);
    check(std::isfinite(nearNyquist) && nearNyquist < 24000.0, "near-Nyquist preWarp finite",
          nearNyquist, 22050.0);

    const std::array<dsp::FilterSpec, 3> mixed{
        dsp::FilterSpec{dsp::FilterType::lowShelf, 105.0, 5.5F, 0.71},
        dsp::FilterSpec{dsp::FilterType::peaking, 3200.0, -4.2F, 2.5},
        dsp::FilterSpec{dsp::FilterType::highShelf, 12000.0, 3.0F, 0.71},
    };
    std::array<double, 15> out{};
    const auto status = dsp::autoEQCoefficients(mixed, 48000.0, 44100.0, out);
    check(status == dsp::Status::ok, "autoEQ mixed status ok", static_cast<double>(status), 0.0);
    for (std::size_t s = 0; s < 3; ++s) {
        checkJuryStable(std::span<const double>(out).subspan(s * 5, 5), "autoEQ mixed stable");
    }

    // Empty filters ok + prepares bypass
    std::array<double, 0> emptyOut{};
    const std::span<const dsp::FilterSpec> emptyFilters{};
    check(dsp::autoEQCoefficients(emptyFilters, 48000.0, 48000.0, emptyOut) == dsp::Status::ok,
          "autoEQ empty ok", 0.0, 0.0);

    dsp::PreparedBiquad prepared;
    check(dsp::prepareBiquad(emptyOut, 2, prepared) == dsp::Status::ok, "prepareBiquad empty ok",
          static_cast<double>(prepared.sectionCount()), 0.0);
}

// MARK: - BiquadProcessor Signal & Adversarial Signal Tests

inline void biquadSignalPeakingAndSelectivity() {
    constexpr double sr = 48000.0;
    constexpr std::size_t frames = 8192;
    constexpr std::size_t skip = 2048;

    auto procBoost =
        makeSingleSectionProcessor(dsp::FilterType::peaking, 1000.0, 12.0F, dsp::graphicEQQ, sr);
    const auto in1k = makeStereoSine(1000.0, 1.0, sr, frames);
    std::vector<float> out1k(frames * 2, 0.0F);
    check(procBoost->processInterleaved(in1k.data(), out1k.data(), frames, 2) == dsp::Status::ok,
          "peaking boost process ok", 0.0, 0.0);

    const float rmsIn1k = measureRMS(in1k, 0, frames, skip);
    const float rmsOutL = measureRMS(out1k, 0, frames, skip);
    const float rmsOutR = measureRMS(out1k, 1, frames, skip);
    const float gain1k = rmsOutL / rmsIn1k;
    check(gain1k > 3.5F && gain1k < 4.5F, "+12dB 1kHz boost ~4x", gain1k, 3.98);
    check(std::abs(rmsOutL - rmsOutR) / rmsOutL < 0.001F, "stereo symmetry", rmsOutL, rmsOutR);

    // 100Hz unaffected
    procBoost->reset();
    const auto in100 = makeStereoSine(100.0, 1.0, sr, frames);
    std::vector<float> out100(frames * 2, 0.0F);
    procBoost->processInterleaved(in100.data(), out100.data(), frames, 2);
    const float gain100 = measureRMS(out100, 0, frames, skip) / measureRMS(in100, 0, frames, skip);
    check(gain100 > 0.9F && gain100 < 1.1F, "+12dB 1kHz leaves 100Hz ~unity", gain100, 1.0);

    // Selectivity: off-center < 3.98x
    for (const double f : {500.0, 2000.0, 4000.0, 8000.0}) {
        procBoost->reset();
        const auto inF = makeStereoSine(f, 1.0, sr, frames);
        std::vector<float> outF(frames * 2, 0.0F);
        procBoost->processInterleaved(inF.data(), outF.data(), frames, 2);
        const float gainF = measureRMS(outF, 0, frames, skip) / measureRMS(inF, 0, frames, skip);
        check(gainF < 3.98F, "selectivity off-center < center", gainF, 3.98);
    }

    // -12dB cut at 1kHz
    auto procCut =
        makeSingleSectionProcessor(dsp::FilterType::peaking, 1000.0, -12.0F, dsp::graphicEQQ, sr);
    std::vector<float> outCut(frames * 2, 0.0F);
    procCut->processInterleaved(in1k.data(), outCut.data(), frames, 2);
    const float gainCut = measureRMS(outCut, 0, frames, skip) / rmsIn1k;
    check(gainCut > 0.2F && gainCut < 0.3F, "-12dB 1kHz cut ~0.25x", gainCut, 0.251);
}

inline void biquadSignalFlatAndShelves() {
    constexpr double sr = 48000.0;
    constexpr std::size_t frames = 8192;
    constexpr std::size_t skip = 2048;

    const std::array<float, 10> flat{};
    auto procFlat = makeGraphicEQProcessor(flat, sr);
    for (const double f : {100.0, 440.0, 1000.0, 4000.0, 10000.0}) {
        procFlat->reset();
        const auto inF = makeStereoSine(f, 1.0, sr, frames);
        std::vector<float> outF(frames * 2, 0.0F);
        procFlat->processInterleaved(inF.data(), outF.data(), frames, 2);
        const float gain = measureRMS(outF, 0, frames, skip) / measureRMS(inF, 0, frames, skip);
        check(std::abs(gain - 1.0F) < 0.02F, "flat 10-band EQ unity", gain, 1.0);
        if (f == 1000.0) {
            float maxErr = 0.0F;
            for (std::size_t i = skip * 2; i < frames * 2; ++i) {
                maxErr = std::max(maxErr, std::abs(outF[i] - inF[i]));
            }
            check(maxErr < 1e-3F, "flat EQ preserves waveform", maxErr, 0.0);
        }
    }

    auto procLow = makeSingleSectionProcessor(dsp::FilterType::lowShelf, 200.0, 12.0F, 0.707, sr);
    const auto in50 = makeStereoSine(50.0, 1.0, sr, frames);
    std::vector<float> out50(frames * 2, 0.0F);
    procLow->processInterleaved(in50.data(), out50.data(), frames, 2);
    const double gain50DB =
        dbGain(measureRMS(out50, 0, frames, skip) / measureRMS(in50, 0, frames, skip));
    check(gain50DB > 10.0 && gain50DB < 14.0, "low shelf +12dB boosts 50Hz", gain50DB, 12.0);

    procLow->reset();
    const auto in8k = makeStereoSine(8000.0, 1.0, sr, frames);
    std::vector<float> out8k(frames * 2, 0.0F);
    procLow->processInterleaved(in8k.data(), out8k.data(), frames, 2);
    const float gain8k = measureRMS(out8k, 0, frames, skip) / measureRMS(in8k, 0, frames, skip);
    check(gain8k > 0.94F && gain8k < 1.06F, "low shelf leaves 8kHz unity", gain8k, 1.0);

    auto procHighCut =
        makeSingleSectionProcessor(dsp::FilterType::highShelf, 4000.0, -12.0F, 0.707, sr);
    const auto in16k = makeStereoSine(16000.0, 1.0, sr, frames);
    std::vector<float> out16k(frames * 2, 0.0F);
    procHighCut->processInterleaved(in16k.data(), out16k.data(), frames, 2);
    const double gain16kDB =
        dbGain(measureRMS(out16k, 0, frames, skip) / measureRMS(in16k, 0, frames, skip));
    check(gain16kDB > -14.0 && gain16kDB < -10.0, "high shelf -12dB cuts 16kHz", gain16kDB, -12.0);

    procHighCut->reset();
    const auto in100 = makeStereoSine(100.0, 1.0, sr, frames);
    std::vector<float> out100(frames * 2, 0.0F);
    procHighCut->processInterleaved(in100.data(), out100.data(), frames, 2);
    const float gain100 = measureRMS(out100, 0, frames, skip) / measureRMS(in100, 0, frames, skip);
    check(gain100 > 0.94F && gain100 < 1.06F, "high shelf leaves 100Hz unity", gain100, 1.0);

    auto procHighBoost =
        makeSingleSectionProcessor(dsp::FilterType::highShelf, 4000.0, 6.0F, 0.707, sr);
    const auto in12k = makeStereoSine(12000.0, 1.0, sr, frames);
    std::vector<float> out12k(frames * 2, 0.0F);
    procHighBoost->processInterleaved(in12k.data(), out12k.data(), frames, 2);
    const double gain12kDB =
        dbGain(measureRMS(out12k, 0, frames, skip) / measureRMS(in12k, 0, frames, skip));
    check(gain12kDB > 4.0 && gain12kDB < 8.0, "high shelf +6dB boosts 12kHz", gain12kDB, 6.0);
}

inline void biquadSignalMultiBandRatesAndAdversarial() {
    constexpr std::size_t frames = 8192;
    constexpr std::size_t skip = 2048;

    // Sample rates 44.1k, 48k, 96k peaking 1kHz +12dB
    for (const double sr : {44100.0, 48000.0, 96000.0}) {
        auto proc = makeSingleSectionProcessor(dsp::FilterType::peaking, 1000.0, 12.0F,
                                               dsp::graphicEQQ, sr);
        const auto in = makeStereoSine(1000.0, 1.0, sr, frames);
        std::vector<float> out(frames * 2, 0.0F);
        proc->processInterleaved(in.data(), out.data(), frames, 2);
        const double gainDB =
            dbGain(measureRMS(out, 0, frames, skip) / measureRMS(in, 0, frames, skip));
        check(gainDB > 10.0 && gainDB < 14.0, "1kHz +12dB across sample rates", gainDB, 12.0);
    }

    // 8kHz BT HFP signal test: 500Hz boosted > 2x
    const std::array<float, 10> allPlus12{12, 12, 12, 12, 12, 12, 12, 12, 12, 12};
    auto hfpProc = makeGraphicEQProcessor(allPlus12, 8000.0);
    const auto in500 = makeStereoSine(500.0, 1.0, 8000.0, frames);
    std::vector<float> out500(frames * 2, 0.0F);
    hfpProc->processInterleaved(in500.data(), out500.data(), frames, 2);
    const float hfpGain = measureRMS(out500, 0, frames, skip) / measureRMS(in500, 0, frames, skip);
    check(hfpGain > 2.0F, "8kHz HFP 500Hz boosted", hfpGain, 4.0);

    // Bass+treble boost leaves 500Hz near unity
    const std::array<float, 10> bassTreble{6, 6, 0, 0, 0, 0, 0, 0, 6, 6};
    auto btProc = makeGraphicEQProcessor(bassTreble, 48000.0);
    const auto inMid = makeStereoSine(500.0, 1.0, 48000.0, frames);
    std::vector<float> outMid(frames * 2, 0.0F);
    btProc->processInterleaved(inMid.data(), outMid.data(), frames, 2);
    const float midGain = measureRMS(outMid, 0, frames, skip) / measureRMS(inMid, 0, frames, skip);
    check(midGain > 0.85F && midGain < 1.15F, "bass+treble 500Hz near unity", midGain, 1.0);

    // Boundary frame counts (1, 2, 65536), zero, subnormal, high amplitude
    auto eq1k = makeSingleSectionProcessor(dsp::FilterType::peaking, 1000.0, 12.0F, dsp::graphicEQQ,
                                           48000.0);
    for (const std::size_t n : {std::size_t{1}, std::size_t{2}, std::size_t{65536}}) {
        const auto in = makeStereoSine(1000.0, 0.5, 48000.0, n);
        std::vector<float> out(n * 2, 0.0F);
        check(eq1k->processInterleaved(in.data(), out.data(), n, 2) == dsp::Status::ok,
              "boundary frameCount ok", static_cast<double>(n), static_cast<double>(n));
        check(std::isfinite(out[0]) && std::isfinite(out.back()), "boundary frameCount finite",
              out[0], out[0]);
    }

    eq1k->reset();
    std::vector<float> subBuf(256, std::numeric_limits<float>::denorm_min());
    std::vector<float> subOut(256, 0.0F);
    eq1k->processInterleaved(subBuf.data(), subOut.data(), 128, 2);
    check(std::isfinite(subOut.back()), "subnormal finite", subOut.back(), 0.0);

    // DC signal through peaking = unity; through low shelf +6dB = ~2x
    eq1k->reset();
    std::vector<float> dcIn(frames * 2, 0.5F);
    std::vector<float> dcOut(frames * 2, 0.0F);
    eq1k->processInterleaved(dcIn.data(), dcOut.data(), frames, 2);
    check(std::abs(dcOut.back() - 0.5F) < 0.02F, "DC through peaking ~0.5", dcOut.back(), 0.5);

    auto lowShelf6 =
        makeSingleSectionProcessor(dsp::FilterType::lowShelf, 200.0, 6.0F, 0.707, 48000.0);
    std::vector<float> dcShelfOut(frames * 2, 0.0F);
    lowShelf6->processInterleaved(dcIn.data(), dcShelfOut.data(), frames, 2);
    check(std::abs(dcShelfOut.back() - 1.0F) < 0.05F, "DC through +6dB lowShelf ~1.0",
          dcShelfOut.back(), 1.0);

    // Nyquist alternating +1/-1 through peaking = unity
    eq1k->reset();
    std::vector<float> nyqIn(frames * 2, 0.0F);
    for (std::size_t i = 0; i < frames; ++i) {
        const float v = (i % 2 == 0) ? 1.0F : -1.0F;
        nyqIn[i * 2] = v;
        nyqIn[i * 2 + 1] = v;
    }
    std::vector<float> nyqOut(frames * 2, 0.0F);
    eq1k->processInterleaved(nyqIn.data(), nyqOut.data(), frames, 2);
    check(std::abs(std::abs(nyqOut.back()) - 1.0F) < 0.02F, "Nyquist through peaking ~unity",
          std::abs(nyqOut.back()), 1.0);

    // Upstream extreme-amplitude pin: +40 dBFS input through +12 dB peaking stays
    // finite with the expected ~4x gain (no overflow to NaN/Inf).
    eq1k->reset();
    const auto hotIn = makeStereoSine(1000.0, 100.0, 48000.0, frames);
    std::vector<float> hotOut(frames * 2, 0.0F);
    check(eq1k->processInterleaved(hotIn.data(), hotOut.data(), frames, 2) == dsp::Status::ok,
          "high amplitude processing succeeds", 0.0, 0.0);
    bool hotFinite = true;
    float hotMax = 0.0F;
    for (const float sample : hotOut) {
        hotFinite = hotFinite && std::isfinite(sample);
        hotMax = std::max(hotMax, std::abs(sample));
    }
    check(hotFinite, "high amplitude 100.0 through +12dB stays finite", hotMax, 0.0);
    const float hotGain = measureRMS(hotOut, 0, frames, skip) / measureRMS(hotIn, 0, frames, skip);
    check(hotGain > 3.0F && hotGain < 5.0F, "high amplitude EQ gain ~4x", hotGain, 4.0);

    // Upstream enable/disable cycle pin: bypass leaves delay history untouched, so
    // re-enabling resumes from the stale state with decaying filter ringing.
    auto cycleProc = makeSingleSectionProcessor(dsp::FilterType::peaking, 1000.0, 12.0F,
                                                dsp::graphicEQQ, 48000.0);
    constexpr std::size_t cycleFrames = 2048;
    const auto cycleIn = makeStereoSine(1000.0, 1.0, 48000.0, cycleFrames);
    std::vector<float> cycleOut(cycleFrames * 2, 0.0F);
    check(cycleProc->processInterleaved(cycleIn.data(), cycleOut.data(), cycleFrames, 2) ==
              dsp::Status::ok,
          "cycle active processing succeeds", 0.0, 0.0);
    const float activeRMS = measureRMS(cycleOut, 0, cycleFrames, 512);

    cycleProc->setEnabled(false);
    std::vector<float> silence(cycleFrames * 2, 0.0F);
    std::vector<float> bypassOut(cycleFrames * 2, 0.0F);
    cycleProc->processInterleaved(silence.data(), bypassOut.data(), cycleFrames, 2);
    check(bypassOut == silence, "disabled bypass leaves silence untouched", 0.0, 0.0);

    cycleProc->setEnabled(true);
    std::vector<float> reEnabledOut(cycleFrames * 2, 0.0F);
    check(cycleProc->processInterleaved(silence.data(), reEnabledOut.data(), cycleFrames, 2) ==
              dsp::Status::ok,
          "cycle re-enabled processing succeeds", 0.0, 0.0);
    bool ringing = false;
    for (std::size_t i = 0; i < 10; ++i) {
        if (reEnabledOut[i * 2] != 0.0F) {
            ringing = true;
            break;
        }
    }
    check(ringing, "re-enable resumes from stale delay state with ringing", 0.0, 0.0);
    const float ringingRMS = measureRMS(reEnabledOut, 0, cycleFrames, 0);
    check(ringingRMS < activeRMS, "re-enable ringing is quieter than the active signal", ringingRMS,
          activeRMS);

    // Rapid configure churn + extreme boost to flat transition
    const std::array<float, 10> flat{};
    dsp::PreparedBiquad flatPrep;
    dsp::prepareBiquad(dsp::graphicEQCoefficients(flat, 48000.0), 2, flatPrep);
    dsp::PreparedBiquad maxPrep;
    dsp::prepareBiquad(dsp::graphicEQCoefficients(allPlus12, 48000.0), 2, maxPrep);
    dsp::BiquadProcessor churnProc;
    for (int i = 0; i < 100; ++i) {
        churnProc.configure((i % 2 == 0) ? maxPrep : flatPrep);
    }
    churnProc.configure(flatPrep);
    const auto in1k = makeStereoSine(1000.0, 0.5, 48000.0, frames);
    std::vector<float> outChurn(frames * 2, 0.0F);
    churnProc.processInterleaved(in1k.data(), outChurn.data(), frames, 2);
    const float churnGain =
        measureRMS(outChurn, 0, frames, skip) / measureRMS(in1k, 0, frames, skip);
    check(std::abs(churnGain - 1.0F) < 0.02F, "rapid churn final flat wins", churnGain, 1.0);

    // Dual EQ cascade cumulative +6dB + +6dB -> ~12dB
    auto eqA = makeSingleSectionProcessor(dsp::FilterType::peaking, 1000.0, 6.0F, dsp::graphicEQQ,
                                          48000.0);
    auto eqB = makeSingleSectionProcessor(dsp::FilterType::peaking, 1000.0, 6.0F, dsp::graphicEQQ,
                                          48000.0);
    std::vector<float> midBuf(frames * 2, 0.0F);
    std::vector<float> finalBuf(frames * 2, 0.0F);
    eqA->processInterleaved(in1k.data(), midBuf.data(), frames, 2);
    eqB->processInterleaved(midBuf.data(), finalBuf.data(), frames, 2);
    const double dualDB =
        dbGain(measureRMS(finalBuf, 0, frames, skip) / measureRMS(in1k, 0, frames, skip));
    check(dualDB > 10.0 && dualDB < 14.0, "dual +6dB EQ cascade ~12dB", dualDB, 12.0);
}

// MARK: - ISO 226:2023 & Loudness Fitting Compatibility Tests

inline void iso226ReferenceTableAndContours() {
    std::array<double, 29> freqs{};
    std::array<double, 29> alpha{};
    std::array<double, 29> lu{};
    std::array<double, 29> tf{};
    check(dsp::iso226ReferenceData(0, freqs) == dsp::Status::ok, "iso226 freqs", 0.0, 0.0);
    check(dsp::iso226ReferenceData(1, alpha) == dsp::Status::ok, "iso226 alpha", 0.0, 0.0);
    check(dsp::iso226ReferenceData(2, lu) == dsp::Status::ok, "iso226 L_U", 0.0, 0.0);
    check(dsp::iso226ReferenceData(3, tf) == dsp::Status::ok, "iso226 T_f", 0.0, 0.0);

    // 1kHz is band index 17
    check(freqs[0] == 20.0 && freqs[17] == 1000.0 && freqs[28] == 12500.0, "29 ISO226 bands",
          freqs[17], 1000.0);
    check(alpha[17] == 0.300 && lu[17] == 0.0 && tf[17] == 2.4, "1kHz ISO226 Table 1 values",
          alpha[17], 0.300);

    // Table 1 anchor coefficients at the low, mid, and high normative bands
    // (upstream ISO226ContoursTests.table1CriticalCoefficients pins).
    check(alpha[0] == 0.635 && lu[0] == -31.5 && tf[0] == 78.1, "ISO226 Table 1 at band 0",
          alpha[0], 0.635);
    check(alpha[28] == 0.354 && lu[28] == -3.5 && tf[28] == 12.3, "ISO226 Table 1 at band 28",
          alpha[28], 0.354);

    const auto contour20 = dsp::iso226Contour(20.0);
    const auto contour40 = dsp::iso226Contour(40.0);
    check(std::abs(contour20[17] - 20.0) < 1e-6, "20 phon at 1kHz == 20", contour20[17], 20.0);
    check(std::abs(contour40[17] - 40.0) < 1e-6, "40 phon at 1kHz == 40", contour40[17], 40.0);
    // Normative equation anchors at bands 0/5/23/28; band 17 is pinned above
    // (upstream contourReferenceValues20Phon / contourReferenceValues40Phon).
    const std::array<std::size_t, 4> anchorBands{0, 5, 23, 28};
    const std::array<double, 4> contour20Anchors{88.167, 58.197, 15.233, 32.746};
    const std::array<double, 4> contour40Anchors{99.456, 72.849, 36.712, 51.253};
    for (std::size_t i = 0; i < anchorBands.size(); ++i) {
        const std::size_t band = anchorBands[i];
        check(std::abs(contour20[band] - contour20Anchors[i]) < 0.01, "20 phon normative anchor",
              contour20[band], contour20Anchors[i]);
        check(std::abs(contour40[band] - contour40Anchors[i]) < 0.01, "40 phon normative anchor",
              contour40[band], contour40Anchors[i]);
    }
    check(std::abs(dsp::iso226Contour(60.0)[17] - 60.0) < 0.02, "60 phon at 1kHz == 60",
          dsp::iso226Contour(60.0)[17], 60.0);

    const auto comp80 = dsp::iso226Compensation(80.0, 80.0, 1.0);
    for (const double g : comp80) {
        check(std::abs(g) < 1e-9, "80 phon comp vs 80 ref is zero", g, 0.0);
    }

    // Compensation exact-value pins at the 20 Hz edge and mid volume, with the
    // headroom property: required headroom equals the maximum positive gain
    // (upstream lowFrequencyTwentyHertzEdgeCase / normalizedCompensationAtMidVolume).
    const auto comp20 = dsp::iso226Compensation(20.0, 80.0, 1.0);
    check(std::abs(comp20[0] - 29.323) < 0.01, "20 phon 20 Hz compensation == 29.323 dB", comp20[0],
          29.323);
    check(std::abs(comp20[23] - (-3.220)) < 0.01, "20 phon band 23 compensation == -3.220 dB",
          comp20[23], -3.220);
    double comp20Max = 0.0;
    for (const double g : comp20) {
        comp20Max = std::max(comp20Max, g);
    }
    check(std::abs(comp20Max - 29.323) < 0.01, "20 phon compensation headroom == max gain",
          comp20Max, 29.323);

    const auto comp525 = dsp::iso226Compensation(52.5, 80.0, 1.0);
    check(std::abs(comp525[0] - 14.325) < 0.01, "52.5 phon 20 Hz compensation == 14.325 dB",
          comp525[0], 14.325);
    check(std::abs(comp525[5] - 10.161) < 0.01, "52.5 phon band 5 compensation == 10.161 dB",
          comp525[5], 10.161);
    check(std::abs(comp525[23] - (-1.130)) < 0.01, "52.5 phon band 23 compensation == -1.130 dB",
          comp525[23], -1.130);
    check(std::abs(comp525[28] - 4.024) < 0.01, "52.5 phon band 28 compensation == 4.024 dB",
          comp525[28], 4.024);
    double comp525Max = 0.0;
    for (const double g : comp525) {
        comp525Max = std::max(comp525Max, g);
    }
    check(std::abs(comp525Max - 14.325) < 0.01, "52.5 phon compensation headroom == max gain",
          comp525Max, 14.325);

    const auto comp30Full = dsp::iso226Compensation(30.0, 80.0, 1.0);
    const auto comp30Half = dsp::iso226Compensation(30.0, 80.0, 0.5);
    check(std::abs(comp30Full[17]) < 1e-9, "1kHz compensation == 0", comp30Full[17], 0.0);
    check(comp30Full[0] > 10.0, "low volume bass compensation positive", comp30Full[0], 15.0);
    check(std::abs(comp30Half[0] - comp30Full[0] * 0.5) < 1e-9, "amount scales compensation",
          comp30Half[0], comp30Full[0] * 0.5);
    check(std::abs(comp30Half[23] - comp30Full[23] * 0.5) < 1e-9,
          "amount scales compensation at band 23", comp30Half[23], comp30Full[23] * 0.5);
    const auto comp30Flat = dsp::iso226Compensation(30.0, 80.0, 0.0);
    for (const double g : comp30Flat) {
        check(std::abs(g) < 1e-9, "zero amount compensation is flat", g, 0.0);
    }
}

inline void iso226FittingAccuracyAndCompensator() {
    check(dsp::estimatedPhon(0.0F) == 20.0, "estimatedPhon(0) == 20", dsp::estimatedPhon(0.0F),
          20.0);
    check(dsp::estimatedPhon(1.0F) == 80.0, "estimatedPhon(1) == 80", dsp::estimatedPhon(1.0F),
          80.0);
    check(dsp::estimatedPhon(0.5F) > dsp::estimatedPhon(0.1F), "estimatedPhon monotonic",
          dsp::estimatedPhon(0.5F), dsp::estimatedPhon(0.1F));
    // Upstream estimatedPhon boundary pins: out-of-range volumes clamp, and the
    // square-root curve maps quarter volume to the 50 phon midpoint.
    check(dsp::estimatedPhon(1.5F) == 80.0, "volume above 1 clamps to reference phon",
          dsp::estimatedPhon(1.5F), 80.0);
    check(dsp::estimatedPhon(-0.5F) == 20.0, "negative volume clamps to lower bound",
          dsp::estimatedPhon(-0.5F), 20.0);
    check(std::abs(dsp::estimatedPhon(0.25F) - 50.0) < 0.01, "quarter volume maps to 50 phon",
          dsp::estimatedPhon(0.25F), 50.0);

    constexpr double sr = 48000.0;
    const double phon = dsp::estimatedPhon(0.03F);
    const auto target = dsp::iso226Compensation(phon, 80.0, 1.0);
    const auto gains = dsp::fittedLoudnessGains(phon, sr);
    const auto coeffs = dsp::loudnessBandCoefficients(gains, sr);

    // Upstream evaluation set: 96 log-spaced frequencies across the audible band,
    // with the low-frequency fit band bounded at 150 Hz.
    double maxAbsErr = 0.0;
    double lowSqErr = 0.0;
    std::size_t lowCount = 0;
    for (int i = 0; i < 96; ++i) {
        const double f = 20.0 * std::pow(1000.0, static_cast<double>(i) / 95.0);
        const double desired = dsp::interpolateCompensation(target, f);
        const double actual = cascadeMagnitudeDB(coeffs, 4, f, sr);
        const double err = std::abs(actual - desired);
        maxAbsErr = std::max(maxAbsErr, err);
        if (f <= 150.0) {
            lowSqErr += err * err;
            ++lowCount;
        }
    }
    const double lowRMSE = std::sqrt(lowSqErr / static_cast<double>(lowCount));
    check(lowRMSE <= 2.0, "loudness 4-filter low-frequency RMSE <= 2.0 dB", lowRMSE, 2.0);
    check(maxAbsErr <= 3.0, "loudness 4-filter max abs error <= 3.0 dB", maxAbsErr, 3.0);

    dsp::LoudnessCompensator comp(sr);
    check(!comp.isEnabled(), "LoudnessCompensator initially disabled", 0.0, 0.0);
    comp.setEnabled(true);
    check(comp.updateVolume(0.03F) == dsp::Status::ok, "updateVolume 0.03 ok", 0.0, 0.0);
    check(comp.isEnabled(), "enabled preserved after updateVolume", 1.0, 1.0);
    check(comp.updateVolume(0.03F) == dsp::Status::ok, "same-volume update ok", 0.0, 0.0);
}

} // namespace

} // namespace finetune::test::upstream_dsp
