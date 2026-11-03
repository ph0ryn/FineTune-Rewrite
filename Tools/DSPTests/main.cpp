// SPDX-License-Identifier: MIT
// Independent boundary units and runner. Derived GPL units are in a separate translation unit.
#include "AudioDSP/AudioDSP.hpp"
#include "AudioDSP/Dynamics.hpp"
#include "DSPTestUnits.hpp"
#include "NativeAudioBiquad.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <new>
#include <numbers>
#include <type_traits>
#include <vector>

namespace {
bool watchAllocations = false;
std::size_t allocationCount = 0;
int failures = 0;
const char *activeID = "setup";
const char *firstFailure = nullptr;
bool firstHasMeasurements = false;
double firstActual = 0, firstExpected = 0;

void recordFailure(const char *message, bool measured, double actual, double expected) {
    std::fprintf(stderr, "FAIL %s: %s", activeID, message);
    if (measured) {
        std::fprintf(stderr, " [actual=%.17g, expected/bound=%.17g]", actual, expected);
    }
    std::fputc('\n', stderr);
    ++failures;
    if (!firstFailure) {
        firstFailure = message;
        firstHasMeasurements = measured;
        firstActual = actual;
        firstExpected = expected;
    }
}
void expect(bool value, const char *message) {
    if (!value) {
        recordFailure(message, false, 0, 0);
    }
}

struct UnitResult {
    const char *id;
    bool passed;
    const char *failure;
    bool measured;
    double actual;
    double expected;
};

void jsonString(std::FILE *file, const char *value) {
    std::fputc('"', file);
    for (const auto *p = reinterpret_cast<const unsigned char *>(value); *p; ++p) {
        if (*p == '"' || *p == '\\') {
            std::fputc('\\', file);
            std::fputc(*p, file);
        } else if (*p < 0x20) {
            std::fprintf(file, "\\u%04x", static_cast<unsigned>(*p));
        } else {
            std::fputc(*p, file);
        }
    }
    std::fputc('"', file);
}
void jsonMeasurement(std::FILE *file, bool known, double value) {
    if (!known) {
        std::fputs("null", file);
    } else if (std::isfinite(value)) {
        std::fprintf(file, "%.17g", value);
    } else {
        jsonString(file, std::isnan(value) ? "NaN" : value < 0 ? "-Infinity" : "Infinity");
    }
}
bool writeReport(const char *path, std::span<const UnitResult> results, bool complete) {
    auto *file = std::fopen(path, "w");
    if (!file) {
        std::perror("Unable to open DSP report");
        return false;
    }
    std::fprintf(file, "{\"schema_version\":1,\"complete\":%s,\"cases\":[",
                 complete ? "true" : "false");
    bool first = true;
    for (const auto &result : results) {
        if (!first) {
            std::fputc(',', file);
        }
        first = false;
        std::fputs("{\"id\":", file);
        jsonString(file, result.id);
        std::fprintf(file, ",\"status\":\"%s\",\"invocations\":1",
                     result.passed ? "passed" : "failed");
        if (!result.passed) {
            std::fputs(",\"failure\":{\"message\":", file);
            jsonString(file, result.failure);
            std::fputs(",\"actual\":", file);
            jsonMeasurement(file, result.measured, result.actual);
            std::fputs(",\"expected\":", file);
            jsonMeasurement(file, result.measured, result.expected);
            std::fputc('}', file);
        }
        std::fputc('}', file);
    }
    std::fputs("]}\n", file);
    const bool good = !std::ferror(file);
    const int closeStatus = std::fclose(file);
    if (!good || closeStatus != 0) {
        std::fputs("Unable to finish DSP report\n", stderr);
        return false;
    }
    return true;
}
} // namespace

void finetune::test::check(bool condition, const char *property, double actual, double expected) {
    if (!condition) {
        recordFailure(property, true, actual, expected);
    }
}

void *operator new(std::size_t count) {
    if (watchAllocations) {
        ++allocationCount;
    }
    if (void *memory = std::malloc(count == 0 ? 1 : count)) {
        return memory;
    }
    std::abort();
}
void *operator new[](std::size_t count) { return ::operator new(count); }
void operator delete(void *memory) noexcept { std::free(memory); }
void operator delete[](void *memory) noexcept { std::free(memory); }

namespace {
using namespace finetune::dsp;
static_assert(!std::is_copy_constructible_v<BiquadProcessor>);
static_assert(noexcept(std::declval<BiquadProcessor &>().processInterleaved(nullptr, nullptr, 0,
                                                                            2)));

PreparedBiquad prepared(float gainDB = 9, std::size_t channels = 2) {
    const auto c = coefficients({FilterType::peaking, 750, gainDB, 1.4}, 48000);
    PreparedBiquad result;
    expect(prepareBiquad(c, channels, result) == Status::ok, "prepare a valid peaking section");
    return result;
}

double magnitude(const BiquadCoefficients &c, double frequency, double rate) {
    const double w = 2 * std::numbers::pi * frequency / rate;
    const double nr = c[0] + c[1] * std::cos(w) + c[2] * std::cos(2 * w);
    const double ni = -c[1] * std::sin(w) - c[2] * std::sin(2 * w);
    const double dr = 1 + c[3] * std::cos(w) + c[4] * std::cos(2 * w);
    const double di = -c[3] * std::sin(w) - c[4] * std::sin(2 * w);
    return std::sqrt((nr * nr + ni * ni) / (dr * dr + di * di));
}

void mathBoundaries() {
    for (double rate : {8000.0, 44100.0, 48000.0, 96000.0}) {
        for (auto type : {FilterType::peaking, FilterType::lowShelf, FilterType::highShelf}) {
            for (float gain : {-18.0F, 0.0F, 9.0F}) {
                const auto c = coefficients({type, 750, gain, 1.4}, rate);
                for (double value : c) {
                    expect(std::isfinite(value), "RBJ coefficients remain finite");
                }
                expect(std::abs(c[4]) < 1 && 1 + c[3] + c[4] > 0 && 1 - c[3] + c[4] > 0,
                       "RBJ section meets Jury stability criteria");
                if (type == FilterType::peaking) {
                    expect(std::abs(20 * std::log10(magnitude(c, 750, rate)) - gain) < 1e-6,
                           "peaking center response matches dB gain");
                }
            }
        }
    }
    const auto zero = coefficients({FilterType::peaking, 0, 6, 1.4}, 48000);
    expect(zero[4] == 1, "raw math preserves the frequency-zero analytical boundary");
    const double warped = preWarpFrequency(5700, 44100, 96000);
    expect(std::abs(preWarpFrequency(warped, 96000, 44100) - 5700) < 1e-8,
           "bilinear prewarp round trip");
    const std::array<float, 2> wrongGains{1, 2};
    const auto unity = graphicEQCoefficients(wrongGains, 48000);
    for (std::size_t i = 0; i < unity.size(); ++i) {
        expect(unity[i] == (i % 5 == 0 ? 1 : 0), "wrong graphic band count is explicit unity");
    }
}

void firstFrameAndTail() {
    for (std::size_t activeChannel : {0U, 1U}) {
        BiquadProcessor processor;
        expect(processor.configure(prepared()) == Status::ok, "configure before first audio");
        std::array<float, 2> input{}, output{};
        input[activeChannel] = 0.2F;
        expect(processor.processInterleaved(input.data(), output.data(), 1, 2) == Status::ok,
               "one-sided single-frame notification is processed");
        const auto c = coefficients({FilterType::peaking, 750, 9, 1.4}, 48000);
        expect(output[activeChannel] == static_cast<float>(0.2F * c[0]),
               "initial EQ applies to the very first sample without startup fade");
        expect(output[1 - activeChannel] == 0, "silent channel does not gate the other channel");
        input = {};
        processor.processInterleaved(input.data(), output.data(), 1, 2);
        expect(output[activeChannel] != 0, "silence advances real filter tail, not an idle gate");
        processor.reset();
        processor.processInterleaved(input.data(), output.data(), 1, 2);
        expect(output == input, "reset clears histories and silence remains silence");
        input[activeChannel] = 0.2F;
        processor.processInterleaved(input.data(), output.data(), 1, 2);
        expect(output[activeChannel] != 0, "short sound resumes immediately after silence");
    }
}

void partitionAndPathIsolation() {
    constexpr std::size_t frames = 4097;
    std::vector<float> input(frames * 2), whole(frames * 2), split(frames * 2);
    for (std::size_t i = 0; i < frames; ++i) {
        input[i * 2] = static_cast<float>(0.13 * std::sin(i * 0.097));
        input[i * 2 + 1] = static_cast<float>(0.07 * std::cos(i * 0.031));
    }
    BiquadProcessor a, b, otherPath;
    a.configure(prepared());
    b.configure(prepared());
    otherPath.configure(prepared(-9));
    a.processInterleaved(input.data(), whole.data(), frames, 2);
    std::size_t offset = 0;
    for (std::size_t chunk : {1U, 7U, 63U, 257U, 3769U}) {
        b.processInterleaved(input.data() + offset * 2, split.data() + offset * 2, chunk, 2);
        offset += chunk;
    }
    expect(offset == frames && whole == split, "arbitrary buffer partition is bit-exact");

    std::vector<float> reference(frames * 2), actual(frames * 2);
    BiquadProcessor untouched;
    untouched.configure(prepared(-9));
    otherPath.processInterleaved(input.data(), actual.data(), frames, 2);
    untouched.processInterleaved(input.data(), reference.data(), frames, 2);
    expect(actual == reference, "another route's EQ and processing do not alter this history");
    expect(actual != whole, "two routes apply different configured EQ");
    a.configure(prepared(3));
    a.reset();
    otherPath.processInterleaved(input.data(), actual.data(), frames, 2);
    untouched.processInterleaved(input.data(), reference.data(), frames, 2);
    expect(actual == reference, "reconfiguring/resetting route A cannot reset route B");

    b.setEnabled(false);
    b.processInterleaved(input.data(), actual.data(), frames, 2);
    expect(actual == input, "disabled processing is bit-exact bypass");
}

void validationAndRecovery() {
    PreparedBiquad output = prepared();
    const auto valid = coefficients({FilterType::peaking, 750, 9, 1.4}, 48000);
    auto invalid = valid;
    invalid[4] = 1.1;
    expect(prepareBiquad(invalid, 2, output) == Status::invalidConfiguration,
           "unstable denominator is rejected before execution");
    invalid = valid;
    invalid[2] = std::numeric_limits<double>::quiet_NaN();
    expect(prepareBiquad(invalid, 2, output) == Status::invalidConfiguration,
           "non-finite coefficient is rejected");
    expect(prepareBiquad(valid, 0, output) == Status::invalidArgument &&
               prepareBiquad(valid, maxChannels + 1, output) == Status::invalidArgument,
           "unsupported channel counts fail explicitly");
    expect(prepareBiquad(std::span(valid).first(4), 2, output) == Status::invalidArgument,
           "partial coefficient section is rejected");
    std::array<double, (maxBiquadSections + 1) * 5> tooMany{};
    expect(prepareBiquad(tooMany, 2, output) == Status::invalidArgument,
           "section bound is enforced");
    expect(output.sectionCount() == 1 && output.channelCount() == 2,
           "invalid preparation leaves previous valid configuration unchanged");

    BiquadProcessor processor;
    expect(processor.configure(PreparedBiquad{}) == Status::invalidConfiguration,
           "unprepared configuration cannot be installed");
    processor.configure(output);
    std::array<float, 10> input{}, samples{};
    samples.fill(42);
    expect(processor.processInterleaved(nullptr, samples.data(), 4, 2) == Status::invalidArgument,
           "null input is rejected before writing");
    expect(samples[0] == 42, "invalid arguments do not partially mutate output");
    expect(processor.processInterleaved(nullptr, nullptr, 0, 2) == Status::ok,
           "zero-frame processing does not dereference buffers");

    for (float bad :
         {std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity(),
          -std::numeric_limits<float>::infinity()}) {
        input.fill(0.2F);
        input[5] = bad;
        samples.fill(42);
        expect(processor.processInterleaved(input.data(), samples.data(), 4, 2) ==
                   Status::nonFiniteSignal,
               "mid-buffer non-finite signal reports an explicit error");
        expect(std::all_of(samples.begin(), samples.begin() + 8, [](float x) { return x == 0; }),
               "invalid signal mutes entire block rather than poisoning future history");
        expect(samples[8] == 42 && samples[9] == 42, "block mute respects frame count");
        input.fill(0.2F);
        BiquadProcessor fresh;
        fresh.configure(output);
        std::array<float, 10> reference{};
        fresh.processInterleaved(input.data(), reference.data(), 4, 2);
        processor.processInterleaved(input.data(), samples.data(), 4, 2);
        expect(std::equal(samples.begin(), samples.begin() + 8, reference.begin()),
               "first clean block after error resumes with reset history");
    }
}

void cBoundaryAndRealtime() {
    expect(ft_biquad_create(0) == nullptr && ft_biquad_create(9) == nullptr,
           "C creation rejects unsupported configuration");
    auto *processor = ft_biquad_create(2);
    expect(processor != nullptr, "C creation succeeds");
    auto c = coefficients({FilterType::peaking, 750, 9, 1.4}, 48000);
    expect(ft_biquad_replace_coefficients(processor, c.data(), 1) == FT_BIQUAD_OK,
           "C coefficient copy accepts valid configuration");
    c.fill(std::numeric_limits<double>::quiet_NaN());
    std::array<float, 2> input{0.1F, 0}, output{};
    expect(ft_biquad_process(processor, input.data(), output.data(), 1) == FT_BIQUAD_OK &&
               std::isfinite(output[0]) && output[0] > 0,
           "native configuration does not borrow temporary coefficient memory");
    expect(ft_biquad_replace_coefficients(processor, c.data(), 1) ==
               FT_BIQUAD_INVALID_CONFIGURATION,
           "C boundary reports invalid coefficient configuration");
    allocationCount = 0;
    watchAllocations = true;
    for (int i = 0; i < 10000; ++i) {
        ft_biquad_process(processor, input.data(), output.data(), 1);
    }
    watchAllocations = false;
    expect(allocationCount == 0, "RT processing allocates no C++ heap memory");
    ft_biquad_destroy(processor);
}
void copiedConfigurationOwnsFreshHistory() {
    auto *source = ft_biquad_create(2);
    auto *destination = ft_biquad_create(2);
    auto *reference = ft_biquad_create(2);
    auto *mismatched = ft_biquad_create(1);
    const auto c = coefficients({FilterType::peaking, 750, 9, 1.4}, 48000);
    ft_biquad_replace_coefficients(source, c.data(), 1);
    ft_biquad_replace_coefficients(reference, c.data(), 1);
    const std::array<float, 2> input{0.2F, 0};
    std::array<float, 2> output{}, expected{};
    ft_biquad_process(source, input.data(), output.data(), 1);
    expect(ft_biquad_copy_configuration(source, mismatched) == FT_BIQUAD_INVALID_ARGUMENT,
           "configuration copy refuses mismatched channel formats");
    expect(ft_biquad_copy_configuration(source, destination) == FT_BIQUAD_OK,
           "configuration-only copy succeeds");
    ft_biquad_destroy(source);
    ft_biquad_process(destination, input.data(), output.data(), 1);
    ft_biquad_process(reference, input.data(), expected.data(), 1);
    expect(output == expected,
           "copied route survives source destruction and starts without source delay history");
    ft_biquad_destroy(destination);
    ft_biquad_destroy(reference);
    ft_biquad_destroy(mismatched);
}

void planarChannelsAndInvalidViews() {
    constexpr std::size_t channels = 6;
    BiquadProcessor processor;
    processor.configure(prepared(9, channels));
    std::array<std::array<float, 3>, channels> input{}, output{};
    std::array<ConstChannelView, channels> inputViews{};
    std::array<ChannelView, channels> outputViews{};
    for (std::size_t channel = 0; channel < channels; ++channel) {
        input[channel] = {static_cast<float>(channel + 1) * 0.03F, 0, 0};
        output[channel].fill(42);
        inputViews[channel] = {input[channel].data(), 1};
        outputViews[channel] = {output[channel].data(), 1};
    }
    outputViews.back().stride = 0;
    expect(processor.process(inputViews, outputViews, 3) == Status::invalidArgument &&
               output[0][0] == 42,
           "all channel views are validated before the first output write");
    outputViews.back().stride = 1;
    expect(processor.process(inputViews, outputViews, 3) == Status::ok,
           "six planar channels are processed without format conversion");
    for (std::size_t channel = 0; channel < channels; ++channel) {
        BiquadProcessor isolated;
        isolated.configure(prepared(9, 1));
        std::array<float, 3> expected{};
        isolated.processInterleaved(input[channel].data(), expected.data(), 3, 1);
        expect(output[channel] == expected, "each planar channel has its own filter history");
    }
}
void dynamicsNumericalBoundaries() {
    expect(softLimit(0.5F) == 0.5F && softLimit(-0.95F) == -0.95F,
           "limiter is bit-exact below its knee");
    expect(std::isnan(softLimit(std::numeric_limits<float>::infinity())),
           "scalar limiter preserves the portable IEEE infinity expectation");
    const auto contour = iso226Contour(20);
    expect(std::abs(contour[0] - 88.167) < 0.01 && std::abs(contour[17] - 20) < 0.001,
           "ISO 226:2023 reference contour matches normative numerical anchors");
    LoudnessSettings settings;
    settings.analysisWindowMS = 30;
    settings.analysisHopMS = 15;
    LoudnessDetector detector(settings, 48000);
    int boundaries = 0;
    for (int i = 0; i < 1440; ++i) {
        float level = 0;
        const bool ready = detector.ingest(0.5F, level);
        expect(ready == (i == 719 || i == 1439), "detector reports exact analysis hop boundaries");
        boundaries += ready ? 1 : 0;
    }
    expect(boundaries == 2, "detector reports two hops");
    settings.enabled = true;
    LoudnessEqualizer equalizer(settings, 48000);
    std::array<float, 1024> input{}, output{};
    for (std::size_t i = 0; i < 512; ++i) {
        input[i * 2] = 0.2F;
        input[i * 2 + 1] = 0.1F;
    }
    allocationCount = 0;
    watchAllocations = true;
    const auto result = equalizer.process(input.data(), output.data(), 512, 2);
    watchAllocations = false;
    expect(result == Status::ok && output[0] != 0 && output[0] == output[1] * 2,
           "shared loudness gain preserves a short stereo sound from its first sample");
    expect(allocationCount == 0, "loudness processing does not allocate");
}
} // namespace

int main(int argc, char **argv) {
    const char *reportPath = nullptr;
    if (argc != 1) {
        if (argc != 3 || std::strcmp(argv[1], "--report") != 0) {
            std::fputs("Usage: DSPTests [--report path.json]\n", stderr);
            return EXIT_FAILURE;
        }
        reportPath = argv[2];
        if (!writeReport(reportPath, {}, false)) {
            return EXIT_FAILURE;
        }
    }
    using finetune::test::NamedUnit;
    const auto compatibility = finetune::test::loudnessCompatibilityUnits();
    const NamedUnit independent[]{
        {"Tools/DSPTests/main.cpp::mathBoundaries", mathBoundaries},
        {"Tools/DSPTests/main.cpp::firstFrameAndTail", firstFrameAndTail},
        {"Tools/DSPTests/main.cpp::partitionAndPathIsolation", partitionAndPathIsolation},
        {"Tools/DSPTests/main.cpp::validationAndRecovery", validationAndRecovery},
        {"Tools/DSPTests/main.cpp::cBoundaryAndRealtime", cBoundaryAndRealtime},
        {"Tools/DSPTests/main.cpp::copiedConfigurationOwnsFreshHistory",
         copiedConfigurationOwnsFreshHistory},
        {"Tools/DSPTests/main.cpp::planarChannelsAndInvalidViews", planarChannelsAndInvalidViews},
        {"Tools/DSPTests/main.cpp::dynamicsNumericalBoundaries", dynamicsNumericalBoundaries},
    };
    std::vector<UnitResult> results;
    results.reserve(std::size(independent) + compatibility.size());
    const auto run = [&](NamedUnit unit) {
        activeID = unit.id;
        firstFailure = nullptr;
        firstHasMeasurements = false;
        const int before = failures;
        unit.run();
        const bool passed = failures == before;
        results.push_back(
            {unit.id, passed, firstFailure, firstHasMeasurements, firstActual, firstExpected});
        std::printf("%s %s\n", passed ? "PASS" : "FAIL", unit.id);
    };
    for (const auto &unit : independent) {
        run(unit);
    }
    for (const auto &unit : compatibility) {
        run(unit);
    }
    if (reportPath && !writeReport(reportPath, results, true)) {
        return EXIT_FAILURE;
    }
    std::printf("DSP boundary scenarios: %s (%d failures, %zu named cases)\n",
                failures == 0 ? "PASS" : "FAIL", failures, results.size());
    return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
