// SPDX-License-Identifier: MIT
// Shared test-only harness for NativeHALContractTests translation units.
#pragma once

#include "../../Sources/NativeAudio/Runtime/AggregateTapPolicy.hpp"
#include "../NativeRuntimeTests/NativeTestReport.hpp"
#include "AllocationWatch.hpp"
#include "FakeHAL.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <mach/mach_time.h>
#include <memory>
#include <span>

namespace native_hal_contract {
using namespace native_hal_fixture;

struct CaseUnit {
    const char *id;
    void (*run)();
};

inline std::size_t assertions = 0;
inline std::size_t failures = 0;
inline std::size_t inputs = 1;
inline const char *currentID = "startup";
inline const char *firstFailure = nullptr;

inline bool check(bool condition, const char *property) {
    ++assertions;
    if (!condition) {
        if (!firstFailure) {
            firstFailure = property;
        }
        if (failures < 16) {
            std::fprintf(stderr, "%s: %s\n", currentID, property);
        }
        ++failures;
        return false;
    }
    return true;
}

#define CHECK(expr) ::native_hal_contract::check(bool(expr), #expr)
#define REQUIRE(expr)                                                                              \
    do {                                                                                           \
        if (!::native_hal_contract::check(bool(expr), #expr))                                      \
            return;                                                                                \
    } while (false)

struct Release {
    void operator()(FTNativeRoute *p) const {
        if (!p) {
            return;
        }
        // Only fixture cleanup: explicit tests inspect debt before disabling injected errors.
        hal.fault = hal.cleanupFault = Fault::none;
        hal.stopStatus = hal.destroyIOStatus = hal.destroyAggregateStatus = noErr;
        hal.destroyTapStatus = noErr;
        hal.overridePresence = false;
        hal.removeListenerFailureObject = kAudioObjectUnknown;
        hal.holdAggregate = false;
        FTNativeError error{};
        FTNativeResult result = FT_NATIVE_PENDING;
        for (unsigned n = 0; n < 8 && result != FT_NATIVE_OK; ++n) {
            result = ft_native_route_retire(p, &error);
        }
        CHECK(result == FT_NATIVE_OK);
        if (result == FT_NATIVE_OK) {
            CHECK(ft_native_route_release(p) == FT_NATIVE_OK);
        }
    }
};

using Route = std::unique_ptr<FTNativeRoute, Release>;

inline FTNativeOutputState state(std::uint64_t revision = 1, float gain = 0.25F) {
    FTNativeOutputState s{};
    s.revision = revision;
    s.target_gain = gain;
    s.processing.loudness_volume = 0.5F;
    return s;
}

inline FTNativeRouteRequest request(FTNativeOutputState s, const char *uid = "fixture-a") {
    static constexpr std::uint32_t process = 71;
    return {uid, &process, 1, 1, 1, 1, s};
}

inline Route prepare(const FTNativeRouteRequest &r) {
    FTNativeRoute *p = nullptr;
    FTNativeError error{};
    CHECK(ft_native_route_prepare(&r, &p, &error) == FT_NATIVE_OK);
    CHECK(p != nullptr && error.kind == FT_NATIVE_NO_FAILURE);
    return Route(p);
}

inline FTNativeRouteSnapshot snapshot(const Route &p) {
    FTNativeRouteSnapshot result{};
    CHECK(ft_native_route_snapshot(p.get(), &result) == FT_NATIVE_OK);
    return result;
}

inline void resetFixture() {
    CHECK(hal.resources() == 0);
    hal = FakeHAL{};
}

inline void commit(const Route &p, FTNativeOutputState s) {
    FTNativeError error{};
    CHECK(ft_native_route_commit(p.get(), &s, &error) == FT_NATIVE_OK);
    CHECK(error.kind == FT_NATIVE_NO_FAILURE);
}

struct Signal {
    std::array<float, 32> input{}, output{};
    AudioBufferList in{}, out{};

    Signal() {
        for (std::size_t i = 0; i < input.size(); i += 2) {
            input[i] = 0.125F;
            input[i + 1] = -0.0625F;
        }
        output.fill(0.875F);
        in.mNumberBuffers = out.mNumberBuffers = 1;
        in.mBuffers[0] = {2, static_cast<UInt32>(sizeof(input)), input.data()};
        out.mBuffers[0] = {2, static_cast<UInt32>(sizeof(output)), output.data()};
    }

    void render(IO io, const AudioTimeStamp *now = nullptr,
                const AudioTimeStamp *inputTime = nullptr,
                const AudioTimeStamp *outputTime = nullptr) {
        const auto before = input;
        const auto a = callback_observation::allocations.load(),
                   d = callback_observation::deletions.load();
        callback_observation::active = true;
        const auto status = io.callback(io.device, now, &in, inputTime, &out, outputTime, io.data);
        callback_observation::active = false;
        CHECK(status == noErr);
        CHECK(std::memcmp(input.data(), before.data(), sizeof(input)) == 0);
        CHECK(callback_observation::allocations == a && callback_observation::deletions == d);
    }

    bool zero() const {
        return std::all_of(output.begin(), output.end(), [](float v) { return v == 0; });
    }
};

inline FTNativeInvalidationSnapshot invalidation(const Route &p) {
    FTNativeInvalidationSnapshot result{};
    CHECK(ft_native_route_invalidation(p.get(), &result) == FT_NATIVE_OK);
    return result;
}

inline bool sameInvalidation(const FTNativeInvalidationSnapshot &a,
                             const FTNativeInvalidationSnapshot &b) {
    return a.source == b.source && a.reason == b.reason &&
           a.observed_device_id == b.observed_device_id &&
           a.expected_device_id == b.expected_device_id &&
           a.property_object_id == b.property_object_id && a.property_count == b.property_count &&
           a.property_selector == b.property_selector && a.property_scope == b.property_scope &&
           a.property_element == b.property_element &&
           a.has_property_address == b.has_property_address;
}

// Synthetic HAL timestamps use the machine's NRT-acquired timebase, not a fake RT clock.
struct TimingClock {
    mach_timebase_info_data_t timebase{};

    TimingClock() {
        CHECK(mach_timebase_info(&timebase) == KERN_SUCCESS);
        CHECK(timebase.numer != 0 && timebase.denom != 0);
    }

    std::uint64_t ticks(double ns) const {
        return static_cast<std::uint64_t>(std::llround(ns * timebase.denom / timebase.numer));
    }

    double ns(std::uint64_t ticks) const {
        return static_cast<double>(ticks) * timebase.numer / timebase.denom;
    }

    bool near(double actual, double expected) const {
        return std::isfinite(actual) && std::fabs(actual - expected) <= ns(1) + 1;
    }
};

struct TimingStamp {
    AudioTimeStamp now{}, input{}, output{};

    TimingStamp(std::uint64_t host, double in, double out) {
        now.mFlags = kAudioTimeStampHostTimeValid;
        now.mHostTime = host;
        input.mFlags = output.mFlags = kAudioTimeStampSampleTimeValid;
        input.mSampleTime = in;
        output.mSampleTime = out;
    }

    void render(Signal &signal, IO io) const { signal.render(io, &now, &input, &output); }
};

inline FTNativeTimingSnapshot timingSnapshot(const Route &p) {
    FTNativeTimingSnapshot result{};
    CHECK(ft_native_route_timing_snapshot(p.get(), &result) == FT_NATIVE_OK);
    return result;
}

inline void enableTiming(const Route &p) {
    FTNativeError error{};
    CHECK(ft_native_route_enable_timing(p.get(), &error) == FT_NATIVE_OK);
    CHECK(error.kind == FT_NATIVE_NO_FAILURE);
}

inline bool sameTiming(const FTNativeTimingSnapshot &a, const FTNativeTimingSnapshot &b) {
    return a.enabled == b.enabled && a.last_valid_mask == b.last_valid_mask &&
           a.sample_rate == b.sample_rate && a.observed_callbacks == b.observed_callbacks &&
           a.idle_callbacks == b.idle_callbacks && a.missing_now_host == b.missing_now_host &&
           a.missing_input_sample == b.missing_input_sample &&
           a.missing_output_sample == b.missing_output_sample &&
           a.nonincreasing_now_host == b.nonincreasing_now_host &&
           a.host_gaps_over_two_periods == b.host_gaps_over_two_periods &&
           a.input_sample_jumps == b.input_sample_jumps &&
           a.output_sample_jumps == b.output_sample_jumps &&
           a.callbacks_over_nominal_period == b.callbacks_over_nominal_period &&
           a.max_callback_gap_ns == b.max_callback_gap_ns &&
           a.max_callback_duration_ns == b.max_callback_duration_ns &&
           a.max_now_host_gap_ns == b.max_now_host_gap_ns &&
           a.max_input_step_error_frames == b.max_input_step_error_frames &&
           a.max_output_step_error_frames == b.max_output_step_error_frames &&
           a.last_input_sample_time == b.last_input_sample_time &&
           a.last_output_sample_time == b.last_output_sample_time &&
           a.last_io_offset_frames == b.last_io_offset_frames &&
           a.max_io_offset_change_frames == b.max_io_offset_change_frames;
}

std::span<const CaseUnit> acquisitionAndFormatCases() noexcept;
std::span<const CaseUnit> cleanupAndLifecycleCases() noexcept;
std::span<const CaseUnit> invalidationAndUpdateCases() noexcept;
std::span<const CaseUnit> timingDiagnosticCases() noexcept;

} // namespace native_hal_contract
