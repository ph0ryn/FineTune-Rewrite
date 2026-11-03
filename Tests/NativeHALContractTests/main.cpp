// SPDX-License-Identifier: MIT
// Real C exports + real runtime/DSP, only the external OS provider is replaced.
#include "AllocationWatch.hpp"
#include "FakeHAL.hpp"
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>

namespace {
using namespace native_hal_fixture;
std::size_t checks = 0, failures = 0, invocations = 1;
const char *currentID = "startup";
void check(bool condition, const char *property) {
    ++checks;
    if (!condition) {
        if (failures < 16)
            std::fprintf(stderr, "%s: %s\n", currentID, property);
        ++failures;
    }
}
#define CHECK(expr) check(bool(expr), #expr)
struct Release {
    void operator()(FTNativeRoute *p) const {
        if (!p)
            return;
        // Only fixture cleanup: explicit tests inspect debt before disabling injected errors.
        hal.fault = hal.cleanupFault = Fault::none;
        hal.holdAggregate = false;
        FTNativeError error{};
        FTNativeResult result = FT_NATIVE_PENDING;
        for (unsigned n = 0; n < 8 && result != FT_NATIVE_OK; ++n)
            result = ft_native_route_retire(p, &error);
        CHECK(result == FT_NATIVE_OK);
        if (result == FT_NATIVE_OK)
            CHECK(ft_native_route_release(p) == FT_NATIVE_OK);
    }
};
using Route = std::unique_ptr<FTNativeRoute, Release>;
FTNativeOutputState state(std::uint64_t revision = 1, float gain = 0.25F) {
    FTNativeOutputState s{};
    s.revision = revision;
    s.target_gain = gain;
    s.processing.loudness_volume = 0.5F;
    return s;
}
FTNativeRouteRequest request(FTNativeOutputState s, const char *uid = "fixture-a") {
    static constexpr std::uint32_t process = 71;
    return {uid, &process, 1, 1, 1, 1, s};
}
Route prepare(const FTNativeRouteRequest &r) {
    FTNativeRoute *p = nullptr;
    FTNativeError error{};
    CHECK(ft_native_route_prepare(&r, &p, &error) == FT_NATIVE_OK);
    CHECK(p != nullptr && error.kind == FT_NATIVE_NO_FAILURE);
    return Route(p);
}
FTNativeRouteSnapshot snapshot(const Route &p) {
    FTNativeRouteSnapshot result{};
    CHECK(ft_native_route_snapshot(p.get(), &result) == FT_NATIVE_OK);
    return result;
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
    void render(IO io) {
        const auto before = input;
        const AudioTimeStamp timestamp{};
        const auto a = callback_observation::allocations.load(),
                   d = callback_observation::deletions.load();
        callback_observation::active = true;
        const auto status =
            io.callback(io.device, &timestamp, &in, &timestamp, &out, &timestamp, io.data);
        callback_observation::active = false;
        CHECK(status == noErr);
        CHECK(std::memcmp(input.data(), before.data(), sizeof(input)) == 0);
        CHECK(callback_observation::allocations == a && callback_observation::deletions == d);
    }
    bool zero() const {
        return std::all_of(output.begin(), output.end(), [](float v) { return v == 0; });
    }
};
void latestCommitState() {
    invocations = 2;
    for (const auto gains : {std::array{0.25F, 0.75F}, std::array{0.75F, 0.25F}}) {
        CHECK(hal.resources() == 0);
        hal = FakeHAL{};
        auto p = prepare(request(state(1, gains[0])));
        if (!p || hal.ios.empty())
            return;
        const auto io = hal.ios.back();
        auto latest = state(2, gains[1]);
        FTNativeError error{};
        CHECK(ft_native_route_commit(p.get(), &latest, &error) == FT_NATIVE_OK);
        Signal signal;
        signal.render(io);
        const auto s = snapshot(p);
        CHECK(s.accepted_revision == 2);
        CHECK(s.processing_revision == 2);
        CHECK(s.levels_revision == 2 && s.applied_revision == 2);
        CHECK(s.phase == FT_NATIVE_FIRST_APPLIED);
        CHECK(signal.output[0] == signal.input[0] * gains[1]);
        CHECK(signal.output[1] == signal.input[1] * gains[1]);
        p.reset();
        CHECK(hal.resources() == 0);
    }
}
void resetFixture() {
    CHECK(hal.resources() == 0);
    hal = FakeHAL{};
}
void commit(const Route &p, FTNativeOutputState s) {
    FTNativeError error{};
    CHECK(ft_native_route_commit(p.get(), &s, &error) == FT_NATIVE_OK);
    CHECK(error.kind == FT_NATIVE_NO_FAILURE);
}
void acquisitionGuards() {
    invocations = 3;
    for (unsigned mode = 0; mode < 3; ++mode) {
        resetFixture();
        auto r = request(state());
        if (mode == 0)
            r.capture_session = 0;
        if (mode == 1)
            hal.usage = false;
        if (mode == 2)
            hal.selfPID = true;
        FTNativeRoute *p = nullptr;
        FTNativeError error{};
        CHECK(ft_native_route_prepare(&r, &p, &error) == FT_NATIVE_FAILED);
        CHECK(p == nullptr && hal.creates == 0 && hal.starts == 0 && hal.resources() == 0);
        CHECK(error.kind == (mode == 0   ? FT_NATIVE_CAPTURE_NOT_REQUESTED
                             : mode == 1 ? FT_NATIVE_UNAVAILABLE
                                         : FT_NATIVE_UNSUPPORTED));
    }
}
void capabilityAndCertificate() {
    invocations = 11;
    resetFixture();
    FTNativeOutputDescription description{};
    FTNativeError descriptionError{};
    CHECK(ft_native_describe_output("fixture-a", &description, &descriptionError) == FT_NATIVE_OK);
    CHECK(descriptionError.kind == FT_NATIVE_NO_FAILURE && description.object_id == 801);
    CHECK(description.input_channels == 0 && description.output_channels == 2);
    CHECK(description.virtual_sample_rate == 48000 && description.stereo_float32_supported);
    CHECK(hal.creates == 0 && hal.starts == 0 && hal.resources() == 0);
    for (unsigned mode = 0; mode < 10; ++mode) {
        resetFixture();
        if (mode == 0)
            hal.microphone = true;
        if (mode == 1)
            hal.unsupportedOutput = true;
        if (mode == 2)
            hal.wrongRate = true;
        if (mode == 3)
            hal.wrongCertificate = true;
        if (mode == 4)
            hal.wrongTapFormat = true;
        if (mode == 5)
            hal.disabledStreams = true;
        if (mode == 6)
            hal.oversized = true;
        if (mode == 7)
            hal.missingSubTap = true;
        if (mode == 8)
            hal.driftCompensation = 0;
        if (mode == 9)
            hal.driftQuality = kAudioAggregateDriftCompensationLowQuality;
        auto r = request(state());
        FTNativeRoute *p = nullptr;
        FTNativeError error{};
        CHECK(ft_native_route_prepare(&r, &p, &error) == FT_NATIVE_FAILED);
        CHECK(error.kind != FT_NATIVE_NO_FAILURE && hal.starts == 0);
        CHECK(p == nullptr && hal.resources() == 0);
        // A broken guard may unexpectedly acquire; still retire it after recording failure.
        Route unexpected(p);
        unexpected.reset();
        CHECK(hal.resources() == 0);
    }
}
void partialAcquisition() {
    invocations = 9;
    const std::array faults{Fault::tap, Fault::aggregate, Fault::io, Fault::certify,
                            Fault::listener};
    for (auto fault : faults)
        for (bool partial : {false, true}) {
            if (!partial && (fault == Fault::certify || fault == Fault::listener))
                continue;
            resetFixture();
            hal.fault = fault;
            hal.partial = partial;
            auto r = request(state());
            FTNativeRoute *p = nullptr;
            FTNativeError error{};
            CHECK(ft_native_route_prepare(&r, &p, &error) == FT_NATIVE_FAILED);
            CHECK(error.code == acquisitionError && error.kind == FT_NATIVE_FAILURE);
            CHECK(p == nullptr && hal.resources() == 0 && hal.starts == 0);
        }
    resetFixture();
    auto p = prepare(request(state()));
    if (!p)
        return;
    hal.fault = Fault::start;
    auto s = state();
    FTNativeError error{};
    CHECK(ft_native_route_commit(p.get(), &s, &error) == FT_NATIVE_FAILED);
    CHECK(error.code == acquisitionError && error.operation == FT_NATIVE_START);
    p.reset();
    CHECK(hal.resources() == 0 && hal.stops == 1);
}
void boundedCleanupDebt() {
    invocations = 3;
    resetFixture();
    hal.fault = Fault::tap;
    hal.cleanupFault = Fault::destroyTap;
    auto r = request(state());
    FTNativeRoute *raw = nullptr;
    FTNativeError error{};
    CHECK(ft_native_route_prepare(&r, &raw, &error) == FT_NATIVE_FAILED);
    Route debt(raw);
    CHECK(debt != nullptr && hal.taps.size() == 1);
    if (!debt)
        return;
    auto s = snapshot(debt);
    CHECK(s.failure.code == acquisitionError && s.cleanup_failure.code == cleanupError);
    CHECK(ft_native_route_release(debt.get()) == FT_NATIVE_PENDING);
    debt.reset();
    CHECK(hal.resources() == 0);

    resetFixture();
    auto active = prepare(request(state()));
    if (!active)
        return;
    hal.holdAggregate = true;
    CHECK(ft_native_route_retire(active.get(), &error) == FT_NATIVE_PENDING);
    CHECK(hal.aggregates.size() == 1 && hal.taps.size() == 1 && hal.ios.empty());
    CHECK(ft_native_route_release(active.get()) == FT_NATIVE_PENDING);
    active.reset();
    CHECK(hal.resources() == 0);

    resetFixture();
    hal.fault = Fault::tap;
    hal.cleanupFault = Fault::destroyTap;
    std::array<Route, 256> retained;
    for (auto &owner : retained) {
        raw = nullptr;
        CHECK(ft_native_route_prepare(&r, &raw, &error) == FT_NATIVE_FAILED);
        owner.reset(raw);
        CHECK(owner != nullptr);
    }
    const auto acquired = hal.creates;
    raw = nullptr;
    CHECK(ft_native_route_prepare(&r, &raw, &error) == FT_NATIVE_FAILED);
    Route extra(raw);
    CHECK(!extra && error.kind == FT_NATIVE_UNAVAILABLE && hal.creates == acquired);
    CHECK(hal.taps.size() == retained.size() && hal.starts == 0);
    for (auto &owner : retained)
        owner.reset();
    CHECK(hal.resources() == 0);
}
void savedTargetsAndPermit() {
    invocations = 3;
    resetFixture();
    auto a = prepare(request(state(1, 0.25F)));
    if (!a || hal.ios.empty())
        return;
    const auto ioA = hal.ios.back();
    commit(a, state(1, 0.25F));
    auto b = prepare(request(state(1, 0.75F), "fixture-b"));
    if (!b || hal.ios.empty())
        return;
    const auto ioB = hal.ios.back();
    auto sb = state(1, 0.75F);
    FTNativeError error{};
    CHECK(ft_native_route_start_muted(b.get(), &sb, &error) == FT_NATIVE_OK);
    Signal quiet;
    quiet.render(ioB);
    CHECK(quiet.zero());
    CHECK(snapshot(b).phase == FT_NATIVE_ARMED && snapshot(b).applied_revision == 0);
    Signal firstA;
    firstA.render(ioA);
    CHECK(firstA.output[0] == firstA.input[0] * 0.25F);
    commit(b, sb);
    Signal firstB;
    firstB.render(ioB);
    CHECK(firstB.output[0] == firstB.input[0] * 0.75F);
    Signal stillA;
    stillA.render(ioA);
    CHECK(stillA.output[0] == stillA.input[0] * 0.25F);
    a.reset();
    b.reset();
    CHECK(hal.resources() == 0);

    resetFixture();
    auto muted = state();
    muted.muted = true;
    auto p = prepare(request(muted));
    if (!p || hal.ios.empty())
        return;
    const auto io = hal.ios.back();
    commit(p, muted);
    Signal signal;
    signal.render(io);
    CHECK(signal.zero() && snapshot(p).applied_revision == 1 && snapshot(p).peak == 0);
    p.reset();

    resetFixture();
    hal.planar = true;
    p = prepare(request(state(1, 0.5F)));
    if (!p || hal.ios.empty())
        return;
    const auto planarIO = hal.ios.back();
    commit(p, state(1, 0.5F));
    struct List {
        UInt32 count = 2;
        AudioBuffer buffers[2]{};
    } in, out;
    static_assert(offsetof(List, buffers) == offsetof(AudioBufferList, mBuffers));
    std::array<float, 16> left, right, outLeft, outRight;
    left.fill(0.125F);
    right.fill(-0.0625F);
    outLeft.fill(1);
    outRight.fill(1);
    in.buffers[0] = {1, sizeof(left), left.data()};
    in.buffers[1] = {1, sizeof(right), right.data()};
    out.buffers[0] = {1, sizeof(outLeft), outLeft.data()};
    out.buffers[1] = {1, sizeof(outRight), outRight.data()};
    const AudioTimeStamp time{};
    callback_observation::active = true;
    const auto result =
        planarIO.callback(planarIO.device, &time, reinterpret_cast<AudioBufferList *>(&in), &time,
                          reinterpret_cast<AudioBufferList *>(&out), &time, planarIO.data);
    callback_observation::active = false;
    CHECK(result == noErr && outLeft[0] == 0.0625F && outRight[0] == -0.03125F);
    CHECK(left[0] == 0.125F && right[0] == -0.0625F);
}
void callbackSilenceAndInput() {
    invocations = 3;
    for (unsigned mode = 0; mode < 3; ++mode) {
        resetFixture();
        auto p = prepare(request(state()));
        if (!p || hal.ios.empty())
            return;
        const auto io = hal.ios.back();
        commit(p, state());
        Signal signal;
        if (mode == 0)
            signal.in.mBuffers[0].mData = nullptr;
        if (mode == 1)
            signal.input[0] = std::numeric_limits<float>::quiet_NaN();
        if (mode == 2)
            signal.out.mBuffers[0].mNumberChannels = 1; // Actual byte capacity remains valid.
        signal.render(io);
        CHECK(signal.zero());
        const auto s = snapshot(p);
        CHECK(s.applied_revision == 0 && s.phase != FT_NATIVE_FIRST_APPLIED);
        CHECK(s.callback_error_count == (mode == 0 ? 0 : 1));
    }
}
void lateCloseAndReuse() {
    invocations = 10;
    resetFixture();
    auto a = prepare(request(state()));
    if (!a || hal.ios.empty() || hal.listeners.empty())
        return;
    const auto oldIO = hal.ios.back();
    const auto oldListener = hal.listeners.front();
    commit(a, state());
    Signal first;
    first.render(oldIO);
    const auto starts = hal.starts;
    ft_native_route_cancel(a.get());
    ft_native_route_cancel(a.get());
    CHECK(hal.starts == starts && hal.stops == 0);
    a.reset();
    CHECK(hal.resources() == 0);
    auto b = prepare(request(state(1, 0.75F), "fixture-b"));
    if (!b || hal.ios.empty())
        return;
    const auto io = hal.ios.back();
    commit(b, state(1, 0.75F));
    Signal late;
    late.render(oldIO);
    CHECK(late.zero());
    callback_observation::active = true;
    const auto result =
        oldListener.callback(oldListener.object, 1, &oldListener.property, oldListener.data);
    callback_observation::active = false;
    CHECK(result == noErr);
    Signal current;
    current.render(io);
    CHECK(current.output[0] == current.input[0] * 0.75F);
    CHECK(snapshot(b).failure.kind == FT_NATIVE_NO_FAILURE);
    b.reset();

    const std::array properties{
        AudioObjectPropertyAddress{kAudioDevicePropertyNominalSampleRate,
                                   kAudioObjectPropertyScopeGlobal,
                                   kAudioObjectPropertyElementMain},
        AudioObjectPropertyAddress{kAudioDevicePropertyPreferredChannelsForStereo,
                                   kAudioObjectPropertyScopeOutput,
                                   kAudioObjectPropertyElementMain},
        AudioObjectPropertyAddress{kAudioDevicePropertyStreamConfiguration,
                                   kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain},
        AudioObjectPropertyAddress{kAudioDevicePropertyStreamConfiguration,
                                   kAudioObjectPropertyScopeOutput,
                                   kAudioObjectPropertyElementMain},
        AudioObjectPropertyAddress{kAudioSubTapPropertyDriftCompensation,
                                   kAudioObjectPropertyScopeGlobal,
                                   kAudioObjectPropertyElementMain},
        AudioObjectPropertyAddress{kAudioSubTapPropertyDriftCompensationQuality,
                                   kAudioObjectPropertyScopeGlobal,
                                   kAudioObjectPropertyElementMain},
        AudioObjectPropertyAddress{kAudioAggregateDevicePropertySubTapList,
                                   kAudioObjectPropertyScopeGlobal,
                                   kAudioObjectPropertyElementMain},
        AudioObjectPropertyAddress{kAudioDevicePropertyUsesVariableBufferFrameSizes,
                                   kAudioObjectPropertyScopeGlobal,
                                   kAudioObjectPropertyElementMain},
    };
    for (std::size_t n = 0; n < properties.size(); ++n) {
        resetFixture();
        hal.variableFrames = n == 7;
        auto p = prepare(request(state()));
        if (!p || hal.ios.empty())
            return;
        const auto activeIO = hal.ios.back();
        commit(p, state());
        Signal warm;
        warm.render(activeIO);
        CHECK(!warm.zero());
        if (n == 0)
            hal.nominalRate = 44100;
        if (n == 1)
            hal.preferredStereo = false;
        if (n == 2)
            hal.microphone = true;
        if (n == 3)
            hal.planar = true;
        const auto subTap = activeIO.device + hal.subTapOffset;
        if (n == 4)
            hal.driftCompensation = 0;
        if (n == 5)
            hal.driftQuality = kAudioAggregateDriftCompensationLowQuality;
        if (n == 6)
            ++hal.subTapOffset;
        if (n == 7)
            hal.maximumFrames = 128;
        const auto changedObject = n < 4 ? 801 : n < 6 ? subTap : activeIO.device;
        // Fake OS emits only this changed property, not an assumed related notification.
        // No assertion counts registrations: actual signal/status must show invalidation.
        const auto &property = properties[n];
        for (const auto &listener : hal.listeners) {
            if (listener.object != changedObject ||
                listener.property.mSelector != property.mSelector ||
                listener.property.mScope != property.mScope)
                continue;
            callback_observation::active = true;
            const auto changed = listener.callback(listener.object, 1, &property, listener.data);
            callback_observation::active = false;
            CHECK(changed == noErr);
        }
        Signal after;
        after.render(activeIO);
        CHECK(after.zero());
        const auto s = snapshot(p);
        CHECK(s.phase == FT_NATIVE_ROUTE_FAILED && s.failure.kind == FT_NATIVE_BINDING_CHANGED);
    }

    resetFixture();
    auto bindingRoute = prepare(request(state()));
    if (!bindingRoute || hal.ios.empty())
        return;
    const auto bindingIO = hal.ios.back();
    commit(bindingRoute, state());
    Signal warm;
    warm.render(bindingIO);
    CHECK(!warm.zero());
    // Invalid input is transactional: the still-valid old graph may continue.
    auto invalid = state(2, std::numeric_limits<float>::quiet_NaN());
    FTNativeError updateError{};
    CHECK(ft_native_route_update(bindingRoute.get(), &invalid, &updateError) == FT_NATIVE_FAILED);
    CHECK(updateError.kind == FT_NATIVE_FAILURE);
    Signal unchanged;
    unchanged.render(bindingIO);
    CHECK(!unchanged.zero() && snapshot(bindingRoute).failure.kind == FT_NATIVE_NO_FAILURE);
    // NRT can observe PID reuse/self before the corresponding listener is delivered.
    hal.selfPID = true;
    auto next = state(2, 0.75F);
    CHECK(ft_native_route_update(bindingRoute.get(), &next, &updateError) == FT_NATIVE_FAILED);
    CHECK(updateError.kind == FT_NATIVE_BINDING_CHANGED);
    Signal afterQuery;
    afterQuery.render(bindingIO);
    CHECK(afterQuery.zero());
    const auto failed = snapshot(bindingRoute);
    CHECK(failed.phase == FT_NATIVE_ROUTE_FAILED &&
          failed.failure.kind == FT_NATIVE_BINDING_CHANGED);
    CHECK(failed.callback_error_count == 0 &&
          failed.peak == 0); // NRT detection is not a callback error.
}
void copiedConfiguration() {
    resetFixture();
    std::array<float, 10> gains{};
    gains.fill(3);
    auto originalGains = gains;
    FTBiquadFilter filter{FT_BIQUAD_PEAKING, 1000, 3, 0.707};
    auto originalFilter = filter;
    auto original = state();
    original.processing.eq_gains_db = originalGains.data();
    original.processing.eq_gain_count = 10;
    original.processing.has_profile = true;
    original.processing.profile_filters = &originalFilter;
    original.processing.profile_filter_count = 1;
    original.processing.profile_optimized_rate = 48000;
    original.processing.profile_preamp_db = -3;
    original.processing.profile_preamp_enabled = true;
    auto borrowed = original;
    borrowed.processing.eq_gains_db = gains.data();
    borrowed.processing.profile_filters = &filter;
    char uid[] = "fixture-a";
    std::uint32_t process = 71;
    auto r = request(borrowed);
    r.output_uid = uid;
    r.process_objects = &process;
    auto p = prepare(r);
    if (!p || hal.ios.empty())
        return;
    const auto io = hal.ios.back();
    gains.fill(-12);
    filter.frequency = std::numeric_limits<double>::quiet_NaN();
    process = 99;
    std::memcpy(uid, "other-xxx", 9);
    commit(p, original);
    auto reference = prepare(request(original, "fixture-b"));
    if (!reference || hal.ios.empty())
        return;
    const auto referenceIO = hal.ios.back();
    commit(reference, original);
    Signal actual, expected;
    actual.render(io);
    expected.render(referenceIO);
    CHECK(actual.output == expected.output && !actual.zero());
    CHECK(snapshot(p).phase == FT_NATIVE_FIRST_APPLIED);
}
void coalescedCoverage() {
    invocations = 3;
    resetFixture();
    auto initial = state(1, 0.5F);
    initial.processing.loudness_compensation_enabled = true;
    initial.processing.loudness_volume = 0.25F;
    auto p = prepare(request(initial));
    if (!p || hal.ios.empty())
        return;
    const auto io = hal.ios.back();
    commit(p, initial);
    Signal warm;
    warm.render(io);
    CHECK(snapshot(p).applied_revision == 1);
    CHECK(ft_native_route_request_levels(p.get(), {3, 0.5F, false, 0.5F}) == FT_NATIVE_OK);
    Signal fast;
    fast.render(io);
    auto before = snapshot(p);
    CHECK(before.levels_revision == 3 && before.processing_revision == 1 &&
          before.applied_revision == 1);
    std::array<float, 10> gains{};
    gains.fill(6);
    auto two = initial;
    two.revision = 2;
    two.processing.eq_gains_db = gains.data();
    two.processing.eq_gain_count = 10;
    FTNativeError error{};
    CHECK(ft_native_route_update(p.get(), &two, &error) == FT_NATIVE_OK);
    auto three = two;
    three.revision = 3;
    three.processing.loudness_volume = 0.5F;
    CHECK(ft_native_route_update(p.get(), &three, &error) == FT_NATIVE_OK);
    auto reference = prepare(request(three, "fixture-b"));
    if (!reference || hal.ios.empty())
        return;
    const auto referenceIO = hal.ios.back();
    commit(reference, three);
    // Only EQ and LC are present, both newly prepared by this update. Initial gain is0.5
    // in both paths; no unchanged warmed history differs from the direct-final reference.
    Signal actual, expected;
    actual.render(io);
    expected.render(referenceIO);
    const auto after = snapshot(p);
    CHECK(after.processing_revision == 3 && after.levels_revision == 3 &&
          after.applied_revision == 3);
    CHECK(actual.output == expected.output && !actual.zero());
    p.reset();
    reference.reset();

    // Full2 is consumed after hot3. Its older muted/low target must not win.
    resetFixture();
    initial = state(1, 0.5F);
    p = prepare(request(initial));
    if (!p || hal.ios.empty())
        return;
    const auto hotIO = hal.ios.back();
    commit(p, initial);
    CHECK(ft_native_route_request_levels(p.get(), {3, 0.5F, false, 0.5F}) == FT_NATIVE_OK);
    two = state(2, 0.125F);
    two.muted = true;
    CHECK(ft_native_route_update(p.get(), &two, &error) == FT_NATIVE_OK);
    Signal hot;
    hot.render(hotIO);
    const auto hotSnapshot = snapshot(p);
    CHECK(hotSnapshot.processing_revision == 2 && hotSnapshot.levels_revision == 3 &&
          hotSnapshot.applied_revision == 2);
    CHECK(hot.output[0] == hot.input[0] * 0.5F && !hot.zero());
    p.reset();

    // Newer3 has no changed DSP bits, but must inherit unconsumed EQ2. On a
    // revision tie hot3 wins its different gain/mute values over full3.
    resetFixture();
    p = prepare(request(initial));
    if (!p || hal.ios.empty())
        return;
    const auto zeroMaskIO = hal.ios.back();
    commit(p, initial);
    CHECK(ft_native_route_request_levels(p.get(), {3, 0.5F, false, 0.5F}) == FT_NATIVE_OK);
    two.processing.eq_gain_count = 10;
    two.processing.eq_gains_db = gains.data();
    CHECK(ft_native_route_update(p.get(), &two, &error) == FT_NATIVE_OK);
    three = two;
    three.revision = 3;
    CHECK(ft_native_route_update(p.get(), &three, &error) == FT_NATIVE_OK);
    auto referenceState = three;
    referenceState.target_gain = 0.5F;
    referenceState.muted = false;
    reference = prepare(request(referenceState, "fixture-b"));
    if (!reference || hal.ios.empty())
        return;
    const auto zeroMaskReferenceIO = hal.ios.back();
    commit(reference, referenceState);
    Signal inherited, direct;
    inherited.render(zeroMaskIO);
    direct.render(zeroMaskReferenceIO);
    CHECK(inherited.output == direct.output && !inherited.zero());
    CHECK(snapshot(p).applied_revision == 3 && snapshot(p).levels_revision == 3);
}
struct Result {
    const char *id;
    void (*run)();
    std::size_t count = 0, checks = 0, failed = 0;
};
std::array<Result, 10> results{{
    {"Tests/NativeHALContractTests/main.cpp::latestCommitState", latestCommitState},
    {"Tests/NativeHALContractTests/main.cpp::acquisitionGuards", acquisitionGuards},
    {"Tests/NativeHALContractTests/main.cpp::capabilityAndCertificate", capabilityAndCertificate},
    {"Tests/NativeHALContractTests/main.cpp::partialAcquisition", partialAcquisition},
    {"Tests/NativeHALContractTests/main.cpp::boundedCleanupDebt", boundedCleanupDebt},
    {"Tests/NativeHALContractTests/main.cpp::savedTargetsAndPermit", savedTargetsAndPermit},
    {"Tests/NativeHALContractTests/main.cpp::callbackSilenceAndInput", callbackSilenceAndInput},
    {"Tests/NativeHALContractTests/main.cpp::lateCloseAndReuse", lateCloseAndReuse},
    {"Tests/NativeHALContractTests/main.cpp::copiedConfiguration", copiedConfiguration},
    {"Tests/NativeHALContractTests/main.cpp::coalescedCoverage", coalescedCoverage},
}};
bool report(const char *path, bool complete) {
    auto *f = std::fopen(path, "w");
    if (!f)
        return false;
    bool ok = std::fprintf(f, "{\"schema_version\":1,\"complete\":%s,\"cases\":[",
                           complete ? "true" : "false") >= 0;
    if (complete)
        for (std::size_t i = 0; i < results.size(); ++i) {
            const auto &r = results[i];
            ok &= std::fprintf(f,
                               "%s{\"id\":\"%s\",\"status\":\"%s\",\"invocations\":%zu,\"checks\":%"
                               "zu,\"failures\":%zu}",
                               i ? "," : "", r.id, r.failed ? "failed" : "passed", r.count,
                               r.checks, r.failed) >= 0;
        }
    ok &= std::fprintf(f,
                       "],\"real_system_hal_linked\":false,\"callback_allocations\":%zu,\"callback_"
                       "deletions\":%zu,\"owned_resources_at_end\":%zu}\n",
                       callback_observation::allocations.load(),
                       callback_observation::deletions.load(), hal.resources()) >= 0;
    const bool wrote = std::ferror(f) == 0, closed = std::fclose(f) == 0;
    return ok && wrote && closed;
}
} // namespace
int main(int argc, char **argv) {
    const bool inject = argc == 4 && std::strcmp(argv[3], "--inject-check-failure") == 0;
    if ((argc != 3 && !inject) || std::strcmp(argv[1], "--report") != 0)
        return 2;
    if (!report(argv[2], false))
        return 2;
    for (auto &r : results) {
        currentID = r.id;
        const auto before = failures, beforeChecks = checks;
        invocations = 1;
        if (inject && &r == &results.front())
            CHECK(false);
        r.run();
        CHECK(checks > beforeChecks);
        CHECK(hal.resources() == 0);
        CHECK(callback_observation::allocations == 0 && callback_observation::deletions == 0);
        r.count = invocations;
        r.checks = checks - beforeChecks;
        r.failed = failures - before;
        std::printf("%s: %s (%zu invocations/%zu always-on checks)\n", r.id,
                    r.failed ? "FAIL" : "PASS", r.count, r.checks);
    }
    if (!report(argv[2], true))
        return 2;
    return failures ? 1 : 0;
}
