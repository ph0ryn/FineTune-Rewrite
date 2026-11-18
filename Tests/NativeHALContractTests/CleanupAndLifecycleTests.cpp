// SPDX-License-Identifier: MIT
#include "HALContractHarness.hpp"

namespace native_hal_contract {
namespace {

void partialAcquisition() {
    inputs = 9;
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
    REQUIRE(p);
    hal.fault = Fault::start;
    auto s = state();
    FTNativeError error{};
    CHECK(ft_native_route_commit(p.get(), &s, &error) == FT_NATIVE_FAILED);
    CHECK(error.code == acquisitionError && error.operation == FT_NATIVE_START);
    p.reset();
    CHECK(hal.resources() == 0 && hal.stops == 1);
}

void aggregateTapPolicyDecoding() {
    resetFixture();
    inputs = 0;
    const auto uidKey = CFSTR(kAudioSubTapUIDKey);
    const auto driftKey = CFSTR(kAudioSubTapDriftCompensationKey);
    const auto qualityKey = CFSTR(kAudioSubTapDriftCompensationQualityKey);
    const auto tapsKey = CFSTR(kAudioAggregateDeviceTapListKey);
    const auto expectedUID = CFSTR("fixture-owned-tap");
    auto tap = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks,
                                         &kCFTypeDictionaryValueCallBacks);
    auto composition = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks,
                                                 &kCFTypeDictionaryValueCallBacks);
    const auto setNumber = [&](CFStringRef key, CFNumberType type, const void *value) {
        auto number = CFNumberCreate(nullptr, type, value);
        CFDictionarySetValue(tap, key, number);
        CFRelease(number);
    };
    const auto setMembers = [&](CFIndex count, CFTypeRef member) {
        const void *members[]{member, member};
        auto list = CFArrayCreate(nullptr, members, count, &kCFTypeArrayCallBacks);
        CFDictionarySetValue(composition, tapsKey, list);
        CFRelease(list);
    };
    const auto verify = [&](const char *label, CFTypeRef object, CFStringRef uid, bool valid,
                            UInt32 drift = 1,
                            UInt32 quality = kAudioAggregateDriftCompensationHighQuality) {
        ++inputs;
        AggregateTapPolicy policy{17, 19};
        check(decodeAggregateTapPolicy(object, uid, policy) == valid, label);
        CHECK(policy.driftCompensation == (valid ? drift : 17));
        CHECK(policy.driftQuality == (valid ? quality : 19));
    };
    const SInt32 one = 1, high = kAudioAggregateDriftCompensationHighQuality;
    setNumber(driftKey, kCFNumberSInt32Type, &one);
    setNumber(qualityKey, kCFNumberSInt32Type, &high);
    CFDictionarySetValue(tap, uidKey, expectedUID);
    setMembers(1, tap);
    verify("integer policy", composition, expectedUID, true);
    verify("missing composition", nullptr, expectedUID, false);
    verify("wrong composition type", CFSTR("not a dictionary"), expectedUID, false);
    verify("missing expected UID", composition, nullptr, false);
    verify("different expected UID", composition, CFSTR("another tap"), false);
    CFDictionaryRemoveValue(composition, tapsKey);
    verify("missing tap list", composition, expectedUID, false);
    CFDictionarySetValue(composition, tapsKey, CFSTR("not an array"));
    verify("wrong tap list type", composition, expectedUID, false);
    setMembers(0, tap);
    verify("empty tap list", composition, expectedUID, false);
    setMembers(2, tap);
    verify("duplicate owned UID", composition, expectedUID, false);
    setMembers(1, CFSTR("not a tap dictionary"));
    verify("wrong tap entry type", composition, expectedUID, false);
    setMembers(1, tap);
    CFDictionaryRemoveValue(tap, uidKey);
    verify("missing tap UID", composition, expectedUID, false);
    CFDictionarySetValue(tap, uidKey, kCFBooleanTrue);
    verify("wrong tap UID type", composition, expectedUID, false);
    CFDictionarySetValue(tap, uidKey, CFSTR("another tap"));
    verify("wrong tap UID", composition, expectedUID, false);
    CFDictionarySetValue(tap, uidKey, expectedUID);
    for (auto key : {driftKey, qualityKey}) {
        CFDictionaryRemoveValue(tap, key);
        verify("missing policy number", composition, expectedUID, false);
        CFDictionarySetValue(tap, key, kCFBooleanTrue);
        verify("boolean is not the SDK CFNumber", composition, expectedUID, false);
        CFDictionarySetValue(tap, key, CFSTR("1"));
        verify("string is not a number", composition, expectedUID, false);
        for (const double value : {-1.0, 0.5, std::numeric_limits<double>::infinity(),
                                   std::numeric_limits<double>::quiet_NaN(),
                                   double(std::numeric_limits<UInt32>::max()) + 1.0}) {
            setNumber(key, kCFNumberFloat64Type, &value);
            verify("invalid numeric range or precision", composition, expectedUID, false);
        }
        setNumber(key, kCFNumberSInt32Type, key == driftKey ? &one : &high);
    }
    for (const double drift : {0.0, 1.0, 2.0, double(std::numeric_limits<UInt32>::max())}) {
        setNumber(driftKey, kCFNumberFloat64Type, &drift);
        verify("observed drift is not normalized or defaulted", composition, expectedUID, true,
               static_cast<UInt32>(drift));
    }
    setNumber(driftKey, kCFNumberSInt32Type, &one);
    for (const double quality :
         {0.0, double(kAudioAggregateDriftCompensationLowQuality), 128.0, 129.0, 96.5}) {
        setNumber(qualityKey, kCFNumberFloat64Type, &quality);
        verify("observed quality is preserved or rejected", composition, expectedUID,
               quality <= 128 && std::floor(quality) == quality, 1, static_cast<UInt32>(quality));
    }
    CFRelease(composition);
    CFRelease(tap);
}

void privateSubTapUsesAggregatePolicy() {
    resetFixture();
    hal.rejectPrivateSubTapListeners = true;
    auto p = prepare(request(state()));
    REQUIRE(p && !hal.ios.empty());
    const auto io = hal.ios.back();
    commit(p, state());
    Signal signal;
    signal.render(io);
    CHECK(signal.output[0] == signal.input[0] * state().target_gain);
    CHECK(snapshot(p).phase == FT_NATIVE_FIRST_APPLIED);
    p.reset();
    CHECK(hal.resources() == 0);
}

void aggregateCompositionInvalidates() {
    resetFixture();
    auto p = prepare(request(state()));
    REQUIRE(p && !hal.ios.empty());
    const auto io = hal.ios.back();
    commit(p, state());
    Signal warm;
    warm.render(io);
    CHECK(!warm.zero());
    const auto identity = hal.subTapOffset;
    const AudioObjectPropertyAddress property{kAudioAggregateDevicePropertyComposition,
                                              kAudioObjectPropertyScopeGlobal,
                                              kAudioObjectPropertyElementMain};
    for (const auto &listener : hal.listeners) {
        if (listener.object != io.device || listener.property.mSelector != property.mSelector ||
            listener.property.mScope != property.mScope)
            continue;
        callback_observation::active = true;
        const auto changed = listener.callback(listener.object, 1, &property, listener.data);
        callback_observation::active = false;
        CHECK(changed == noErr);
    }
    CHECK(hal.subTapOffset == identity);
    Signal after;
    after.render(io);
    CHECK(after.zero());
    const auto s = snapshot(p);
    CHECK(s.phase == FT_NATIVE_ROUTE_FAILED && s.failure.kind == FT_NATIVE_BINDING_CHANGED);
    p.reset();
    CHECK(hal.resources() == 0);
}

void compositionListenerFailureIsPrimary() {
    inputs = 2;
    for (const bool cleanupDebt : {false, true}) {
        resetFixture();
        hal.rejectCompositionListener = true;
        if (cleanupDebt)
            hal.cleanupFault = Fault::destroyTap;
        auto r = request(state());
        FTNativeRoute *raw = nullptr;
        FTNativeError error{};
        CHECK(ft_native_route_prepare(&r, &raw, &error) == FT_NATIVE_FAILED);
        Route owner(raw);
        CHECK(error.kind == FT_NATIVE_FAILURE && error.operation == FT_NATIVE_INSTALL_LISTENERS);
        CHECK(error.code == compositionListenerError && hal.starts == 0);
        if (cleanupDebt) {
            CHECK(owner != nullptr);
            if (owner) {
                const auto s = snapshot(owner);
                CHECK(s.failure.code == compositionListenerError &&
                      s.failure.operation == FT_NATIVE_INSTALL_LISTENERS);
                CHECK(s.cleanup_failure.code == cleanupError &&
                      s.cleanup_failure.operation == FT_NATIVE_DESTROY_TAP);
            }
        } else {
            CHECK(!owner && hal.resources() == 0);
        }
        owner.reset();
        CHECK(hal.resources() == 0);
    }
}

void boundedCleanupDebt() {
    inputs = 3;
    resetFixture();
    hal.fault = Fault::tap;
    hal.cleanupFault = Fault::destroyTap;
    auto r = request(state());
    FTNativeRoute *raw = nullptr;
    FTNativeError error{};
    CHECK(ft_native_route_prepare(&r, &raw, &error) == FT_NATIVE_FAILED);
    Route debt(raw);
    CHECK(debt != nullptr && hal.taps.size() == 1);
    REQUIRE(debt);
    auto s = snapshot(debt);
    CHECK(s.failure.code == acquisitionError && s.cleanup_failure.code == cleanupError);
    CHECK(ft_native_route_release(debt.get()) == FT_NATIVE_PENDING);
    debt.reset();
    CHECK(hal.resources() == 0);

    resetFixture();
    auto active = prepare(request(state()));
    REQUIRE(active);
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

void disappearedAggregateCleanup() {
    inputs = 2;
    for (const bool started : {true, false}) {
        resetFixture();
        auto p = prepare(request(state()));
        REQUIRE(p && !hal.ios.empty() && !hal.listeners.empty());
        const auto io = hal.ios.back();
        const auto listeners = hal.listeners; // Queued OS callbacks can outlive registrations.
        if (started) {
            commit(p, state());
            Signal before;
            before.render(io);
            CHECK(!before.zero());
        }
        const auto &listener = listeners.back();
        CHECK(listener.callback(listener.object, 1, &listener.property, listener.data) == noErr);
        const auto invalidated = snapshot(p);
        CHECK(invalidated.failure.kind == FT_NATIVE_BINDING_CHANGED);
        CHECK(invalidated.failure.code == -5101);
        hal.disappearAggregate(io.device);
        CHECK(!hal.listeners.empty() && !hal.taps.empty());
        FTNativeError error{};
        CHECK(ft_native_route_retire(p.get(), &error) == FT_NATIVE_OK);
        const auto retired = snapshot(p);
        CHECK(retired.phase == FT_NATIVE_RETIRED && hal.resources() == 0);
        CHECK(retired.failure.code == invalidated.failure.code &&
              retired.failure.operation == invalidated.failure.operation);
        CHECK(retired.cleanup_failure.kind == FT_NATIVE_NO_FAILURE);
        CHECK(hal.presenceQueries == (started ? 4U : 3U));
        CHECK(ft_native_route_release(p.get()) == FT_NATIVE_OK);
        (void)p.release();
        // A reused slot must reject the old IO/listener cookies, not touch its new route.
        auto replacement = prepare(request(state()));
        commit(replacement, state());
        for (const auto &late : listeners)
            CHECK(late.callback(late.object, 1, &late.property, late.data) == noErr);
        Signal late;
        late.render(io);
        CHECK(late.zero());
        CHECK(snapshot(replacement).failure.kind == FT_NATIVE_NO_FAILURE);
        Signal current;
        current.render(hal.ios.back());
        CHECK(!current.zero());
        replacement.reset();
        CHECK(hal.resources() == 0);
    }
}

void aggregateBadDeviceCounterexamples() {
    inputs = 18;
    for (const auto operation :
         {FT_NATIVE_STOP, FT_NATIVE_DESTROY_IOPROC, FT_NATIVE_DESTROY_AGGREGATE}) {
        // Present aggregate; failed probes with false out-param (including raw !obj/!dev);
        // and an unrelated operation error even when the aggregate really disappeared.
        for (unsigned mode = 0; mode < 6; ++mode) {
            resetFixture();
            auto p = prepare(request(state()));
            REQUIRE(p && !hal.ios.empty());
            const auto aggregate = hal.ios.back().device;
            if (operation == FT_NATIVE_STOP)
                commit(p, state());
            const auto original = mode == 5 ? cleanupError : kAudioHardwareBadDeviceError;
            if (operation == FT_NATIVE_STOP)
                hal.stopStatus = original;
            if (operation == FT_NATIVE_DESTROY_IOPROC)
                hal.destroyIOStatus = original;
            if (operation == FT_NATIVE_DESTROY_AGGREGATE)
                hal.destroyAggregateStatus = original;
            if (mode > 0 && mode < 5) {
                hal.overridePresence = true;
                hal.presenceValue = false;
                hal.presenceStatus = mode == 1   ? cleanupError
                                     : mode == 2 ? kAudioHardwareBadObjectError
                                     : mode == 3 ? kAudioHardwareBadDeviceError
                                                 : acquisitionError;
            }
            if (mode == 5)
                hal.disappearAggregate(aggregate);
            FTNativeError error{};
            CHECK(ft_native_route_retire(p.get(), &error) == FT_NATIVE_FAILED);
            CHECK(error.operation == operation && error.code == original);
            CHECK(ft_native_route_release(p.get()) == FT_NATIVE_PENDING);
            const auto debt = snapshot(p);
            CHECK(debt.cleanup_failure.operation == operation &&
                  debt.cleanup_failure.code == original);
            CHECK(debt.phase == FT_NATIVE_RETIRING);
            CHECK(!hal.taps.empty() && hal.resources() > 0);
            const auto expectedProbes =
                mode == 5 ? (operation == FT_NATIVE_DESTROY_AGGREGATE ? 1U : 0U) : 1U;
            CHECK(hal.presenceQueries == expectedProbes);
            if (mode != 5) {
                CHECK(hal.aggregateExists(aggregate));
                if (operation != FT_NATIVE_DESTROY_AGGREGATE)
                    CHECK(!hal.ios.empty() && !hal.listeners.empty());
            }
            // A new explicit request may succeed only after the actual injected fault clears.
            hal.stopStatus = hal.destroyIOStatus = hal.destroyAggregateStatus = noErr;
            hal.overridePresence = false;
            CHECK(ft_native_route_retire(p.get(), &error) == FT_NATIVE_OK);
            CHECK(snapshot(p).cleanup_failure.code == original);
            CHECK(snapshot(p).cleanup_failure.operation == operation);
            CHECK(hal.resources() == 0);
            p.reset();
        }
    }
}

void disappearedAggregateSurvivingDebt() {
    inputs = 6;
    for (unsigned mode = 0; mode < 6; ++mode) {
        resetFixture();
        auto p = prepare(request(state()));
        REQUIRE(p && !hal.ios.empty());
        commit(p, state());
        const auto aggregate = hal.ios.back().device;
        const auto tap = hal.taps.back().id;
        const auto listener = hal.listeners.back();
        CHECK(listener.callback(listener.object, 1, &listener.property, listener.data) == noErr);
        hal.disappearAggregate(aggregate);
        const auto primary = snapshot(p).failure;
        const auto operation = mode >= 4 ? FT_NATIVE_DESTROY_TAP : FT_NATIVE_REMOVE_LISTENER;
        const auto status = mode == 3 || mode == 5 ? kAudioHardwareBadDeviceError : cleanupError;
        if (mode >= 4)
            hal.destroyTapStatus = status;
        else {
            hal.removeListenerFailureObject = mode == 0 ? 801 : mode == 1 ? 71 : tap;
            hal.removeListenerStatus = status;
        }
        FTNativeError error{};
        CHECK(ft_native_route_retire(p.get(), &error) == FT_NATIVE_FAILED);
        CHECK(error.operation == operation && error.code == status);
        CHECK(ft_native_route_release(p.get()) == FT_NATIVE_PENDING);
        CHECK(!hal.taps.empty());
        CHECK(snapshot(p).failure.code == primary.code);
        CHECK(snapshot(p).failure.kind == primary.kind &&
              snapshot(p).failure.operation == primary.operation);
        CHECK(snapshot(p).cleanup_failure.operation == operation);
        CHECK(snapshot(p).cleanup_failure.code == status);
        hal.destroyTapStatus = noErr;
        hal.removeListenerFailureObject = kAudioObjectUnknown;
        CHECK(ft_native_route_retire(p.get(), &error) == FT_NATIVE_OK);
        CHECK(snapshot(p).failure.code == primary.code);
        CHECK(snapshot(p).failure.kind == primary.kind &&
              snapshot(p).failure.operation == primary.operation);
        CHECK(snapshot(p).cleanup_failure.operation == operation);
        CHECK(snapshot(p).cleanup_failure.code == status);
        CHECK(hal.resources() == 0);
        p.reset();
    }
}

void savedTargetsAndPermit() {
    inputs = 3;
    resetFixture();
    auto a = prepare(request(state(1, 0.25F)));
    REQUIRE(a && !hal.ios.empty());
    const auto ioA = hal.ios.back();
    commit(a, state(1, 0.25F));
    auto b = prepare(request(state(1, 0.75F), "fixture-b"));
    REQUIRE(b && !hal.ios.empty());
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
    REQUIRE(p && !hal.ios.empty());
    const auto io = hal.ios.back();
    commit(p, muted);
    Signal signal;
    signal.render(io);
    CHECK(signal.zero() && snapshot(p).applied_revision == 1 && snapshot(p).peak == 0);
    p.reset();

    resetFixture();
    hal.planar = true;
    p = prepare(request(state(1, 0.5F)));
    REQUIRE(p && !hal.ios.empty());
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
    inputs = 3;
    for (unsigned mode = 0; mode < 3; ++mode) {
        resetFixture();
        auto p = prepare(request(state()));
        REQUIRE(p && !hal.ios.empty());
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

constexpr std::array<CaseUnit, 11> cases{{
    {"Tests/NativeHALContractTests/main.cpp::partialAcquisition", partialAcquisition},
    {"Tests/NativeHALContractTests/main.cpp::privateSubTapUsesAggregatePolicy",
     privateSubTapUsesAggregatePolicy},
    {"Tests/NativeHALContractTests/main.cpp::aggregateCompositionInvalidates",
     aggregateCompositionInvalidates},
    {"Tests/NativeHALContractTests/main.cpp::compositionListenerFailureIsPrimary",
     compositionListenerFailureIsPrimary},
    {"Tests/NativeHALContractTests/main.cpp::aggregateTapPolicyDecoding",
     aggregateTapPolicyDecoding},
    {"Tests/NativeHALContractTests/main.cpp::boundedCleanupDebt", boundedCleanupDebt},
    {"Tests/NativeHALContractTests/main.cpp::disappearedAggregateCleanup",
     disappearedAggregateCleanup},
    {"Tests/NativeHALContractTests/main.cpp::aggregateBadDeviceCounterexamples",
     aggregateBadDeviceCounterexamples},
    {"Tests/NativeHALContractTests/main.cpp::disappearedAggregateSurvivingDebt",
     disappearedAggregateSurvivingDebt},
    {"Tests/NativeHALContractTests/main.cpp::savedTargetsAndPermit", savedTargetsAndPermit},
    {"Tests/NativeHALContractTests/main.cpp::callbackSilenceAndInput", callbackSilenceAndInput},
}};

} // namespace

std::span<const CaseUnit> cleanupAndLifecycleCases() noexcept { return cases; }

} // namespace native_hal_contract
