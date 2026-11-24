#include "HALContractHarness.hpp"

namespace native_hal_contract {
namespace {

void timingDisabledByDefault() {
    resetFixture();
    auto p = prepare(request(state()));
    REQUIRE(p && !hal.ios.empty());
    const auto io = hal.ios.back();
    const auto before = timingSnapshot(p);
    CHECK(!before.enabled && before.observed_callbacks == 0 && before.last_valid_mask == 0);
    commit(p, state());
    Signal signal;
    TimingStamp(1000, 100, 200).render(signal, io);
    signal.render(io);
    CHECK(!signal.zero() && snapshot(p).callback_count == 2);
    CHECK(sameTiming(before, timingSnapshot(p)));
}

void timingEnableLifecycleAndNullSafety() {
    inputs = 4;
    FTNativeError error{};
    FTNativeTimingSnapshot unused{};
    CHECK(ft_native_route_enable_timing(nullptr, &error) == FT_NATIVE_FAILED);
    CHECK(ft_native_route_enable_timing(nullptr, nullptr) == FT_NATIVE_FAILED);
    CHECK(ft_native_route_timing_snapshot(nullptr, &unused) == FT_NATIVE_FAILED);
    CHECK(ft_native_route_timing_snapshot(nullptr, nullptr) == FT_NATIVE_FAILED);
    for (unsigned mode = 0; mode < 4; ++mode) {
        resetFixture();
        auto p = prepare(request(state()));
        CHECK(p && !hal.ios.empty());
        if (!p || hal.ios.empty())
            continue;
        CHECK(ft_native_route_timing_snapshot(p.get(), nullptr) == FT_NATIVE_FAILED);
        // A null error sink is allowed, and repeated prepared enables do not reset state.
        CHECK(ft_native_route_enable_timing(p.get(), nullptr) == FT_NATIVE_OK);
        enableTiming(p);
        const auto prepared = timingSnapshot(p);
        CHECK(prepared.enabled && prepared.sample_rate == 48000 &&
              prepared.observed_callbacks == 0 && prepared.last_valid_mask == 0);
        if (mode == 0) {
            auto initial = state();
            CHECK(ft_native_route_start_muted(p.get(), &initial, &error) == FT_NATIVE_OK);
        } else if (mode == 1) {
            commit(p, state());
        } else if (mode == 2) {
            ft_native_route_cancel(p.get());
        } else {
            CHECK(ft_native_route_retire(p.get(), &error) == FT_NATIVE_OK);
        }
        CHECK(ft_native_route_enable_timing(p.get(), &error) == FT_NATIVE_FAILED);
        CHECK(sameTiming(prepared, timingSnapshot(p)));
    }
}

void timingNormalTimestamps() {
    resetFixture();
    TimingClock clock;
    auto p = prepare(request(state()));
    REQUIRE(p && !hal.ios.empty());
    enableTiming(p);
    const auto io = hal.ios.back();
    commit(p, state());
    const auto period = clock.ticks(16.0 / 48000 * 1e9), origin = clock.ticks(1e9);
    for (unsigned n = 0; n < 3; ++n) {
        Signal signal;
        TimingStamp(origin + n * period, 1000 + 16 * n, 1128 + 16 * n).render(signal, io);
        CHECK(!signal.zero());
    }
    const auto t = timingSnapshot(p);
    CHECK(t.enabled && t.sample_rate == 48000 && t.observed_callbacks == 3);
    CHECK(t.idle_callbacks == 0 && t.last_valid_mask == 7);
    CHECK(t.missing_now_host == 0 && t.missing_input_sample == 0 && t.missing_output_sample == 0);
    CHECK(t.nonincreasing_now_host == 0 && t.host_gaps_over_two_periods == 0);
    CHECK(t.input_sample_jumps == 0 && t.output_sample_jumps == 0);
    CHECK(t.max_input_step_error_frames == 0 && t.max_output_step_error_frames == 0);
    CHECK(t.last_input_sample_time == 1032 && t.last_output_sample_time == 1160);
    CHECK(t.last_io_offset_frames == 128 && t.max_io_offset_change_frames == 0);
    CHECK(clock.near(t.max_now_host_gap_ns, clock.ns(period)));
    // Actual callback clocks are nondeterministic; never assert an exact duration/deadline.
    CHECK(std::isfinite(t.max_callback_gap_ns) && t.max_callback_gap_ns >= 0);
    CHECK(std::isfinite(t.max_callback_duration_ns) && t.max_callback_duration_ns >= 0);
    CHECK(t.callbacks_over_nominal_period <= t.observed_callbacks);
    CHECK(snapshot(p).callback_error_count == 0);
}

void timingSampleDiscontinuitiesAndTolerance() {
    inputs = 10;
    TimingClock clock;
    for (bool inputLane : {false, true})
        for (double delta : {48.0, -16.0, 0.0, 15.0, 17.0}) {
            resetFixture();
            auto p = prepare(request(state()));
            CHECK(p && !hal.ios.empty());
            if (!p || hal.ios.empty())
                continue;
            enableTiming(p);
            const auto io = hal.ios.back();
            commit(p, state());
            Signal first, next;
            const auto origin = clock.ticks(1e9), period = clock.ticks(16.0 / 48000 * 1e9);
            TimingStamp(origin, 1000, 2000).render(first, io);
            TimingStamp(origin + period, 1000 + (inputLane ? delta : 16),
                        2000 + (inputLane ? 16 : delta))
                .render(next, io);
            const auto t = timingSnapshot(p);
            const auto error = std::fabs(delta - 16);
            CHECK(t.observed_callbacks == 2 && t.last_valid_mask == 7);
            CHECK(t.input_sample_jumps == (inputLane && error > 1 ? 1 : 0));
            CHECK(t.output_sample_jumps == (!inputLane && error > 1 ? 1 : 0));
            CHECK(t.max_input_step_error_frames == (inputLane ? error : 0));
            CHECK(t.max_output_step_error_frames == (inputLane ? 0 : error));
            CHECK(t.max_io_offset_change_frames == error);
            CHECK(t.last_io_offset_frames == 1000 + (inputLane ? 16 - delta : delta - 16));
            CHECK(next.output == first.output && !next.zero());
            CHECK(snapshot(p).callback_error_count == 0 &&
                  snapshot(p).failure.kind == FT_NATIVE_NO_FAILURE);
        }
}

void timingHostGapsAndNonincreasingHost() {
    resetFixture();
    TimingClock clock;
    auto p = prepare(request(state()));
    REQUIRE(p && !hal.ios.empty());
    enableTiming(p);
    const auto io = hal.ios.back();
    commit(p, state());
    const auto origin = clock.ticks(1e9), period = clock.ticks(16.0 / 48000 * 1e9),
               gap = clock.ticks(1e6);
    const std::array hosts{origin, origin + period, origin + period + gap, origin + period + gap,
                           origin + period + gap - 1};
    for (std::size_t n = 0; n < hosts.size(); ++n) {
        Signal signal;
        TimingStamp(hosts[n], 1000 + 16 * n, 2000 + 16 * n).render(signal, io);
    }
    const auto t = timingSnapshot(p);
    CHECK(t.observed_callbacks == hosts.size() && t.nonincreasing_now_host == 2);
    CHECK(t.host_gaps_over_two_periods == 1);
    CHECK(clock.near(t.max_now_host_gap_ns, clock.ns(gap)));
    CHECK(t.input_sample_jumps == 0 && t.output_sample_jumps == 0);
    CHECK(snapshot(p).callback_error_count == 0 &&
          snapshot(p).failure.kind == FT_NATIVE_NO_FAILURE);
}

void timingMissingTimestampsResetOnlyTheirBaseline() {
    inputs = 11;
    TimingClock clock;
    for (unsigned lane = 0; lane < 3; ++lane)
        for (unsigned mode = 0; mode < 4; ++mode) {
            if (lane == 0 && mode >= 2)
                continue; // HAL host time is integral, so only null/missing flag apply.
            resetFixture();
            auto p = prepare(request(state()));
            CHECK(p && !hal.ios.empty());
            if (!p || hal.ios.empty())
                continue;
            enableTiming(p);
            const auto io = hal.ios.back();
            commit(p, state());
            const auto origin = clock.ticks(1e9), period = clock.ticks(16.0 / 48000 * 1e9);
            Signal first, missing, restored;
            TimingStamp(origin, 1000, 2000).render(first, io);
            TimingStamp invalid(origin + period, 1016, 2016);
            auto *target = lane == 0 ? &invalid.now : lane == 1 ? &invalid.input : &invalid.output;
            if (mode == 1)
                target->mFlags = 0;
            if (mode >= 2)
                target->mSampleTime = mode == 2 ? std::numeric_limits<double>::quiet_NaN()
                                                : std::numeric_limits<double>::infinity();
            missing.render(io, lane == 0 && mode == 0 ? nullptr : &invalid.now,
                           lane == 1 && mode == 0 ? nullptr : &invalid.input,
                           lane == 2 && mode == 0 ? nullptr : &invalid.output);
            const auto broken = timingSnapshot(p);
            CHECK(broken.observed_callbacks == 2 && broken.last_valid_mask == (7U & ~(1U << lane)));
            CHECK(broken.missing_now_host == (lane == 0 ? 1 : 0));
            CHECK(broken.missing_input_sample == (lane == 1 ? 1 : 0));
            CHECK(broken.missing_output_sample == (lane == 2 ? 1 : 0));
            CHECK(broken.last_input_sample_time == (lane == 1 ? 1000 : 1016));
            CHECK(broken.last_output_sample_time == (lane == 2 ? 2000 : 2016));
            // A distant returning timestamp must establish a fresh lane/offset baseline.
            TimingStamp(lane == 0 ? origin + clock.ticks(1e8) : origin + 2 * period,
                        lane == 1 ? 9000 : 1032, lane == 2 ? 12000 : 2032)
                .render(restored, io);
            const auto t = timingSnapshot(p);
            CHECK(t.observed_callbacks == 3 && t.last_valid_mask == 7);
            CHECK(t.input_sample_jumps == 0 && t.output_sample_jumps == 0);
            CHECK(t.max_input_step_error_frames == 0 && t.max_output_step_error_frames == 0);
            CHECK(t.host_gaps_over_two_periods == 0 && t.nonincreasing_now_host == 0);
            CHECK(t.max_io_offset_change_frames == 0);
            CHECK(snapshot(p).callback_error_count == 0 && !restored.zero());
        }
    // Entirely absent timestamps are also a valid audio callback, never invented zero times.
    resetFixture();
    auto p = prepare(request(state()));
    REQUIRE(p && !hal.ios.empty());
    enableTiming(p);
    commit(p, state());
    Signal absent;
    absent.render(hal.ios.back());
    const auto t = timingSnapshot(p);
    CHECK(t.observed_callbacks == 1 && t.last_valid_mask == 0);
    CHECK(t.missing_now_host == 1 && t.missing_input_sample == 1 && t.missing_output_sample == 1);
    CHECK(snapshot(p).callback_error_count == 0 && !absent.zero());
}

void timingValidIdleAndZeroFrames() {
    resetFixture();
    TimingClock clock;
    auto p = prepare(request(state()));
    REQUIRE(p && !hal.ios.empty());
    enableTiming(p);
    const auto io = hal.ios.back();
    commit(p, state());
    const auto origin = clock.ticks(1e9), period = clock.ticks(16.0 / 48000 * 1e9);
    Signal idle, empty, resumed;
    idle.in.mBuffers[0].mData = nullptr;
    TimingStamp(origin, 1000, 2000).render(idle, io);
    empty.in.mBuffers[0].mDataByteSize = empty.out.mBuffers[0].mDataByteSize = 0;
    TimingStamp(origin + period, 1016, 2016).render(empty, io);
    CHECK(snapshot(p).applied_revision == 0);
    const auto idleTiming = timingSnapshot(p);
    CHECK(idleTiming.observed_callbacks == 2 && idleTiming.idle_callbacks == 2);
    CHECK(idleTiming.last_valid_mask == 7 && idleTiming.last_input_sample_time == 1016 &&
          idleTiming.last_output_sample_time == 2016);
    // Previous frame count was zero. Resumption at the same sample time is continuous.
    TimingStamp(origin + period, 1016, 2016).render(resumed, io);
    const auto t = timingSnapshot(p);
    CHECK(t.observed_callbacks == 3 && t.idle_callbacks == 2);
    CHECK(t.input_sample_jumps == 0 && t.output_sample_jumps == 0);
    CHECK(t.max_input_step_error_frames == 0 && t.max_output_step_error_frames == 0);
    CHECK(idle.zero() && resumed.output[0] == resumed.input[0] * state().target_gain);
    CHECK(snapshot(p).callback_error_count == 0 && snapshot(p).applied_revision == 1);
}

void timingDoesNotChangeRenderedOutput() {
    resetFixture();
    auto initial = state();
    std::array<float, 10> gains{};
    gains.fill(3);
    initial.processing.eq_gains_db = gains.data();
    initial.processing.eq_gain_count = gains.size();
    auto disabled = prepare(request(initial));
    REQUIRE(disabled && !hal.ios.empty());
    const auto disabledIO = hal.ios.back();
    auto enabled = prepare(request(initial, "fixture-b"));
    REQUIRE(enabled && !hal.ios.empty());
    const auto enabledIO = hal.ios.back();
    enableTiming(enabled);
    commit(disabled, initial);
    commit(enabled, initial);
    for (unsigned n = 0; n < 6; ++n) {
        if (n == 2) {
            CHECK(ft_native_route_request_levels(disabled.get(), {2, 0.75F, false, 0.5F}) ==
                  FT_NATIVE_OK);
            CHECK(ft_native_route_request_levels(enabled.get(), {2, 0.75F, false, 0.5F}) ==
                  FT_NATIVE_OK);
        }
        Signal reference, actual;
        TimingStamp stamp(1000 + n, 1000 + 64 * n, 2000 - 32 * n);
        stamp.render(reference, disabledIO);
        stamp.render(actual, enabledIO);
        CHECK(actual.output == reference.output && !actual.zero());
        CHECK(snapshot(enabled).applied_revision == snapshot(disabled).applied_revision);
        CHECK(snapshot(enabled).callback_error_count == 0);
    }
    CHECK(timingSnapshot(enabled).observed_callbacks == 6);
    CHECK(timingSnapshot(disabled).observed_callbacks == 0);
}

void timingRetirementArchivesAndLateCallbacksAreInert() {
    resetFixture();
    auto p = prepare(request(state()));
    REQUIRE(p && !hal.ios.empty());
    enableTiming(p);
    const auto io = hal.ios.back();
    commit(p, state());
    Signal first;
    TimingStamp(1000, 1000, 2000).render(first, io);
    const auto before = timingSnapshot(p);
    CHECK(before.enabled && before.observed_callbacks == 1);
    ft_native_route_cancel(p.get());
    Signal cancelled;
    TimingStamp(9000, 8000, -1000).render(cancelled, io);
    CHECK(cancelled.zero() && sameTiming(before, timingSnapshot(p)));
    FTNativeError error{};
    CHECK(ft_native_route_retire(p.get(), &error) == FT_NATIVE_OK);
    CHECK(snapshot(p).phase == FT_NATIVE_RETIRED && hal.resources() == 0);
    CHECK(sameTiming(before, timingSnapshot(p)));
    Signal retired;
    retired.render(io);
    CHECK(retired.zero() && sameTiming(before, timingSnapshot(p)));
}

void timingDetectsOutputWaveformDiscontinuity() {
    inputs = 2;
    resetFixture();
    auto p = prepare(request(state()));
    REQUIRE(p && !hal.ios.empty());
    enableTiming(p);
    commit(p, state());
    const auto io = hal.ios.back();
    Signal normal;
    normal.render(io);
    const auto baseline = timingSnapshot(p);
    CHECK(baseline.output_discontinuities == 0);
    CHECK(baseline.max_output_sample_delta < 0.5F);
    Signal spike;
    spike.input[16] = 4.0F; // One extreme sample amid a quiet alternating signal.
    spike.render(io);
    const auto after = timingSnapshot(p);
    CHECK(after.output_discontinuities > baseline.output_discontinuities);
    CHECK(after.max_output_sample_delta > 0.5F);
}

void timingDetectsCallbackBoundaryDiscontinuity() {
    inputs = 2;
    resetFixture();
    auto p = prepare(request(state()));
    REQUIRE(p && !hal.ios.empty());
    enableTiming(p);
    commit(p, state());
    const auto io = hal.ios.back();

    Signal quiet;
    quiet.input.fill(0);
    quiet.render(io);
    const auto baseline = timingSnapshot(p);
    CHECK(baseline.output_discontinuities == 0);

    Signal step;
    step.input.fill(1);
    step.render(io);
    const auto after = timingSnapshot(p);
    CHECK(after.output_discontinuities >= baseline.output_discontinuities + 2);
}

constexpr std::array<CaseUnit, 11> cases{{
    {"Tests/NativeHALContractTests/main.cpp::timingDisabledByDefault", timingDisabledByDefault},
    {"Tests/NativeHALContractTests/main.cpp::timingEnableLifecycleAndNullSafety",
     timingEnableLifecycleAndNullSafety},
    {"Tests/NativeHALContractTests/main.cpp::timingNormalTimestamps", timingNormalTimestamps},
    {"Tests/NativeHALContractTests/main.cpp::timingSampleDiscontinuitiesAndTolerance",
     timingSampleDiscontinuitiesAndTolerance},
    {"Tests/NativeHALContractTests/main.cpp::timingHostGapsAndNonincreasingHost",
     timingHostGapsAndNonincreasingHost},
    {"Tests/NativeHALContractTests/main.cpp::timingMissingTimestampsResetOnlyTheirBaseline",
     timingMissingTimestampsResetOnlyTheirBaseline},
    {"Tests/NativeHALContractTests/main.cpp::timingValidIdleAndZeroFrames",
     timingValidIdleAndZeroFrames},
    {"Tests/NativeHALContractTests/main.cpp::timingDoesNotChangeRenderedOutput",
     timingDoesNotChangeRenderedOutput},
    {"Tests/NativeHALContractTests/main.cpp::timingRetirementArchivesAndLateCallbacksAreInert",
     timingRetirementArchivesAndLateCallbacksAreInert},
    {"Tests/NativeHALContractTests/main.cpp::timingDetectsOutputWaveformDiscontinuity",
     timingDetectsOutputWaveformDiscontinuity},
    {"Tests/NativeHALContractTests/main.cpp::timingDetectsCallbackBoundaryDiscontinuity",
     timingDetectsCallbackBoundaryDiscontinuity},
}};

} // namespace

std::span<const CaseUnit> timingDiagnosticCases() noexcept { return cases; }

} // namespace native_hal_contract
