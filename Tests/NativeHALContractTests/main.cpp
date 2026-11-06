// SPDX-License-Identifier: MIT
// Real C exports + real runtime/DSP, only the external OS provider is replaced.
#include "../../Sources/NativeAudio/Runtime/AggregateTapPolicy.hpp"
#include "AllocationWatch.hpp"
#include "FakeHAL.hpp"
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <mach/mach_time.h>
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
void switchWithOffsetTapInput() {
    invocations = 3;
    for (const UInt32 origin : {3U, 5U, 7U}) {
        resetFixture();
        auto initial = state();
        auto old = prepare(request(initial));
        if (!old)
            continue;
        commit(old, initial);
        const auto oldIO = hal.ios.back();
        hal.inputFirstChannel = origin;
        auto candidate = prepare(request(initial, "fixture-b"));
        if (!candidate)
            continue;
        const auto candidateIO = hal.ios.back();
        FTNativeError error{};
        CHECK(ft_native_route_start_muted(candidate.get(), &initial, &error) == FT_NATIVE_OK);
        Signal warm;
        warm.render(candidateIO);
        CHECK(warm.zero() && snapshot(candidate).phase == FT_NATIVE_ARMED);
        old.reset();
        commit(candidate, initial);
        Signal signal;
        signal.render(candidateIO);
        for (std::size_t n = 0; n < signal.input.size(); ++n)
            CHECK(std::fabs(signal.output[n] - signal.input[n] * initial.target_gain) < 1e-7F);
        CHECK(snapshot(candidate).phase == FT_NATIVE_FIRST_APPLIED);
        Signal lateOld;
        lateOld.render(oldIO);
        CHECK(lateOld.zero());
        Signal malformed;
        malformed.in.mBuffers[0].mDataByteSize -= sizeof(float);
        malformed.render(candidateIO);
        CHECK(malformed.zero() && snapshot(candidate).failure.kind == FT_NATIVE_BINDING_CHANGED);
    }
}
void idleTransportCanHandoffWithoutSourceSamples() {
    resetFixture();
    auto initial = state();
    auto old = prepare(request(initial));
    if (!old)
        return;
    commit(old, initial);
    auto candidate = prepare(request(initial, "fixture-b"));
    if (!candidate)
        return;
    const auto io = hal.ios.back();
    FTNativeError error{};
    CHECK(ft_native_route_start_muted(candidate.get(), &initial, &error) == FT_NATIVE_OK);
    // Zero frames cannot establish an operational output clock.
    Signal empty;
    empty.in.mBuffers[0].mDataByteSize = empty.out.mBuffers[0].mDataByteSize = 0;
    empty.render(io);
    CHECK(snapshot(candidate).phase == FT_NATIVE_STARTED);
    // A certified output callback with absent source payload is ordinary idle transport.
    Signal idle;
    idle.in.mBuffers[0].mData = nullptr;
    idle.render(io);
    const auto armed = snapshot(candidate);
    CHECK(idle.zero() && armed.phase == FT_NATIVE_ARMED);
    CHECK(armed.failure.kind == FT_NATIVE_NO_FAILURE && armed.callback_error_count == 0);
    CHECK(armed.processing_revision == 0 && armed.levels_revision == 0 &&
          armed.applied_revision == 0);
    // Retire the old physical IO before committing, even though the app has not played yet.
    old.reset();
    auto latest = state(2, 0.5F);
    CHECK(ft_native_route_commit(candidate.get(), &latest, &error) == FT_NATIVE_OK);
    Signal stillIdle;
    stillIdle.in.mBuffers[0].mData = nullptr;
    stillIdle.render(io);
    CHECK(stillIdle.zero() && snapshot(candidate).applied_revision == 0);
    CHECK(snapshot(candidate).phase == FT_NATIVE_COMMITTED);
    Signal resumed;
    resumed.render(io);
    // Preserve the replacement's existing per-frame gain ramp; idle never advanced its history.
    const auto firstGain = resumed.output[0] / resumed.input[0];
    const auto lastGain = resumed.output[30] / resumed.input[30];
    CHECK(firstGain > initial.target_gain && firstGain < latest.target_gain);
    CHECK(lastGain > firstGain && lastGain < latest.target_gain);
    CHECK(resumed.output[1] / resumed.input[1] == firstGain);
    CHECK(snapshot(candidate).phase == FT_NATIVE_FIRST_APPLIED);
    CHECK(snapshot(candidate).applied_revision == latest.revision);
    candidate.reset();
    CHECK(hal.resources() == 0);
}
void idleTransportRejectsInvalidReadiness() {
    invocations = 6;
    for (unsigned mode = 0; mode < 6; ++mode) {
        resetFixture();
        auto initial = state();
        auto candidate = prepare(request(initial));
        if (!candidate)
            continue;
        const auto io = hal.ios.back();
        FTNativeError error{};
        CHECK(ft_native_route_start_muted(candidate.get(), &initial, &error) == FT_NATIVE_OK);
        Signal idle;
        idle.in.mBuffers[0].mData = nullptr;
        switch (mode) {
        case 0:
            idle.in.mNumberBuffers = 0;
            break;
        case 1:
            idle.in.mBuffers[0].mNumberChannels = 1;
            break;
        case 2:
            idle.in.mBuffers[0].mDataByteSize -= sizeof(float);
            break;
        case 3:
            idle.in.mBuffers[0].mDataByteSize -= 2 * sizeof(float);
            break;
        case 4:
            idle.out.mBuffers[0].mData = nullptr;
            break;
        case 5:
            ft_native_route_cancel(candidate.get());
            break;
        }
        idle.render(io);
        const auto observed = snapshot(candidate);
        CHECK(idle.zero() || mode == 4); // A disabled output cannot be written.
        CHECK(observed.phase != FT_NATIVE_ARMED && observed.phase != FT_NATIVE_FIRST_APPLIED);
        CHECK(observed.processing_revision == 0 && observed.applied_revision == 0);
        CHECK(observed.callback_error_count == (mode == 5 ? 0 : 1));
        CHECK(observed.failure.kind ==
              (mode == 5 ? FT_NATIVE_NO_FAILURE : FT_NATIVE_BINDING_CHANGED));
        candidate.reset();
        CHECK(hal.resources() == 0);
    }
}
void streamLayoutChannelOrigins() {
    resetFixture();
    invocations = 0;
    const UInt32 interleaved[]{2}, planar[]{1, 1}, extra[]{1, 1, 1};
    auto stereo = FakeHAL::asbd();
    auto mono = stereo;
    mono.mChannelsPerFrame = 1;
    mono.mBytesPerFrame = mono.mBytesPerPacket = sizeof(float);
    const auto verify = [&](std::span<const UInt32> channels,
                            std::span<const StreamFormatObservation> streams, bool device,
                            bool ownedTap) {
        ++invocations;
        CHECK(decodeStereoLayout(channels, streams).nativePackedFloat32 == device);
        CHECK(decodeStereoLayout(channels, streams, StreamChannelOrigin::ownedTapInput)
                  .nativePackedFloat32 == ownedTap);
    };
    for (const UInt32 origin : {0U, 1U, 3U, 5U, std::numeric_limits<UInt32>::max()}) {
        const StreamFormatObservation observed[]{{stereo, origin}};
        verify(interleaved, observed, origin == 1,
               origin != 0 && origin != std::numeric_limits<UInt32>::max());
    }
    for (const auto channels : {std::array<UInt32, 2>{1, 2},
                                {5, 6},
                                {5, 7},
                                {5, 5},
                                {6, 5},
                                {0, 1},
                                {std::numeric_limits<UInt32>::max(), 0}}) {
        const StreamFormatObservation observed[]{{mono, channels[0]}, {mono, channels[1]}};
        verify(planar, observed, channels[0] == 1,
               (channels[0] == 1 && channels[1] == 2) || (channels[0] == 5 && channels[1] == 6));
    }
    const StreamFormatObservation interleavedStream[]{{stereo, 5}};
    verify(planar, interleavedStream, false, false);
    auto split = stereo;
    split.mFormatFlags |= kAudioFormatFlagIsNonInterleaved;
    split.mBytesPerFrame = split.mBytesPerPacket = sizeof(float);
    const StreamFormatObservation planarStream[]{{split, 5}};
    verify(planar, planarStream, false, true);
    verify(interleaved, planarStream, false, false);
    stereo.mBitsPerChannel = 16;
    const StreamFormatObservation invalidFormat[]{{stereo, 5}};
    verify(interleaved, invalidFormat, false, false);
    auto differentRate = mono;
    differentRate.mSampleRate = 44100;
    const StreamFormatObservation mixedRates[]{{mono, 5}, {differentRate, 6}};
    verify(planar, mixedRates, false, false);
    const StreamFormatObservation threeStreams[]{{mono, 5}, {mono, 6}, {mono, 7}};
    verify(extra, threeStreams, false, false);
    verify(planar, threeStreams, false, false);
    verify(interleaved, {}, false, false);
    verify({}, interleavedStream, false, false);
    for (const bool foreignTap : {false, true}) {
        resetFixture();
        ++invocations;
        hal.inputFirstChannel = 5;
        hal.wrongCertificate = foreignTap;
        hal.wrongPhysicalOutput = !foreignTap;
        auto r = request(state());
        FTNativeRoute *p = nullptr;
        FTNativeError error{};
        CHECK(ft_native_route_prepare(&r, &p, &error) == FT_NATIVE_FAILED);
        CHECK(error.kind == FT_NATIVE_UNSUPPORTED && hal.starts == 0);
        CHECK(p == nullptr && hal.resources() == 0);
        Route unexpected(p);
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
void aggregateTapPolicyDecoding() {
    resetFixture();
    invocations = 0;
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
        ++invocations;
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
    if (!p || hal.ios.empty())
        return;
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
    if (!p || hal.ios.empty())
        return;
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
    invocations = 2;
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
void ioCapacityDoesNotRequireRangeListener() {
    invocations = 2;
    for (bool variable : {false, true}) {
        resetFixture();
        // The fake supplies a valid IO certificate, not execution of SystemHal's SDK getter.
        // Exercise the real C consumer without a nominal configuration-range property.
        hal.variableFrames = variable;
        hal.rejectBufferRangeListener = true;
        auto p = prepare(request(state()));
        if (!p || hal.ios.empty())
            continue;
        const auto io = hal.ios.back();
        commit(p, state());
        Signal signal;
        signal.render(io);
        CHECK(signal.output[0] == signal.input[0] * state().target_gain);
        CHECK(signal.output[1] == signal.input[1] * state().target_gain);
        const auto observed = snapshot(p);
        CHECK(observed.phase == FT_NATIVE_FIRST_APPLIED);
        CHECK(observed.failure.kind == FT_NATIVE_NO_FAILURE);
        p.reset();
        CHECK(hal.resources() == 0);
    }
}
void bufferFrameSizeChangeInvalidates() {
    invocations = 2;
    for (bool variable : {false, true}) {
        resetFixture();
        hal.variableFrames = variable;
        auto p = prepare(request(state()));
        if (!p || hal.ios.empty())
            continue;
        const auto io = hal.ios.back();
        commit(p, state());
        Signal before;
        before.render(io);
        CHECK(!before.zero());
        hal.maximumFrames = 128;
        const AudioObjectPropertyAddress property{kAudioDevicePropertyBufferFrameSize,
                                                  kAudioObjectPropertyScopeGlobal,
                                                  kAudioObjectPropertyElementMain};
        // Emit only the actual-size notification, not a coincident range/vfsz change.
        for (const auto &listener : hal.listeners) {
            if (listener.object != io.device || listener.property.mSelector != property.mSelector ||
                listener.property.mScope != property.mScope)
                continue;
            callback_observation::active = true;
            const auto changed = listener.callback(listener.object, 1, &property, listener.data);
            callback_observation::active = false;
            CHECK(changed == noErr);
        }
        Signal after;
        after.render(io);
        CHECK(after.zero());
        const auto observed = snapshot(p);
        CHECK(observed.phase == FT_NATIVE_ROUTE_FAILED);
        CHECK(observed.failure.kind == FT_NATIVE_BINDING_CHANGED &&
              observed.failure.operation == FT_NATIVE_CERTIFY_FORMAT);
        CHECK(observed.callback_error_count == 1);
        p.reset();
        CHECK(hal.resources() == 0);
    }
}
void bufferFrameSizeListenerFailureRetainsDebt() {
    invocations = 2;
    for (bool debt : {false, true}) {
        resetFixture();
        hal.rejectBufferSizeListener = true;
        if (debt)
            hal.cleanupFault = Fault::destroyIO;
        auto r = request(state());
        FTNativeRoute *raw = nullptr;
        FTNativeError error{};
        CHECK(ft_native_route_prepare(&r, &raw, &error) == FT_NATIVE_FAILED);
        CHECK(error.kind == FT_NATIVE_FAILURE && error.operation == FT_NATIVE_INSTALL_LISTENERS &&
              error.code == kAudioHardwareUnknownPropertyError);
        CHECK(hal.starts == 0);
        Route owner(raw);
        if (debt) {
            CHECK(owner != nullptr && hal.resources() != 0);
            if (owner) {
                const auto observed = snapshot(owner);
                CHECK(observed.failure.code == kAudioHardwareUnknownPropertyError);
                CHECK(observed.cleanup_failure.operation == FT_NATIVE_DESTROY_IOPROC &&
                      observed.cleanup_failure.code == cleanupError);
            }
        } else {
            CHECK(owner == nullptr && hal.resources() == 0);
        }
        hal.cleanupFault = Fault::none;
        owner.reset();
        CHECK(hal.resources() == 0);
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
        AudioObjectPropertyAddress{kAudioAggregateDevicePropertyComposition,
                                   kAudioObjectPropertyScopeGlobal,
                                   kAudioObjectPropertyElementMain},
        AudioObjectPropertyAddress{kAudioAggregateDevicePropertyComposition,
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
        if (n == 4)
            hal.driftCompensation = 0;
        if (n == 5)
            hal.driftQuality = kAudioAggregateDriftCompensationLowQuality;
        if (n == 6)
            ++hal.subTapOffset;
        if (n == 7)
            hal.maximumFrames = 128;
        const auto changedObject = n < 4 ? 801 : activeIO.device;
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
FTNativeTimingSnapshot timingSnapshot(const Route &p) {
    FTNativeTimingSnapshot result{};
    CHECK(ft_native_route_timing_snapshot(p.get(), &result) == FT_NATIVE_OK);
    return result;
}
void enableTiming(const Route &p) {
    FTNativeError error{};
    CHECK(ft_native_route_enable_timing(p.get(), &error) == FT_NATIVE_OK);
    CHECK(error.kind == FT_NATIVE_NO_FAILURE);
}
bool sameTiming(const FTNativeTimingSnapshot &a, const FTNativeTimingSnapshot &b) {
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
void timingDisabledByDefault() {
    resetFixture();
    auto p = prepare(request(state()));
    if (!p || hal.ios.empty())
        return;
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
    invocations = 4;
    FTNativeError error{};
    FTNativeTimingSnapshot unused{};
    CHECK(ft_native_route_enable_timing(nullptr, &error) == FT_NATIVE_FAILED);
    CHECK(ft_native_route_enable_timing(nullptr, nullptr) == FT_NATIVE_FAILED);
    CHECK(ft_native_route_timing_snapshot(nullptr, &unused) == FT_NATIVE_FAILED);
    CHECK(ft_native_route_timing_snapshot(nullptr, nullptr) == FT_NATIVE_FAILED);
    for (unsigned mode = 0; mode < 4; ++mode) {
        resetFixture();
        auto p = prepare(request(state()));
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
    if (!p || hal.ios.empty())
        return;
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
    invocations = 10;
    TimingClock clock;
    for (bool inputLane : {false, true})
        for (double delta : {48.0, -16.0, 0.0, 15.0, 17.0}) {
            resetFixture();
            auto p = prepare(request(state()));
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
    if (!p || hal.ios.empty())
        return;
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
    invocations = 11;
    TimingClock clock;
    for (unsigned lane = 0; lane < 3; ++lane)
        for (unsigned mode = 0; mode < 4; ++mode) {
            if (lane == 0 && mode >= 2)
                continue; // HAL host time is integral, so only null/missing flag apply.
            resetFixture();
            auto p = prepare(request(state()));
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
    if (!p || hal.ios.empty())
        return;
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
    if (!p || hal.ios.empty())
        return;
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
    if (!disabled || hal.ios.empty())
        return;
    const auto disabledIO = hal.ios.back();
    auto enabled = prepare(request(initial, "fixture-b"));
    if (!enabled || hal.ios.empty())
        return;
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
    if (!p || hal.ios.empty())
        return;
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
struct Result {
    const char *id;
    void (*run)();
    std::size_t count = 0, checks = 0, failed = 0;
};
std::array<Result, 30> results{{
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
    {"Tests/NativeHALContractTests/main.cpp::latestCommitState", latestCommitState},
    {"Tests/NativeHALContractTests/main.cpp::acquisitionGuards", acquisitionGuards},
    {"Tests/NativeHALContractTests/main.cpp::capabilityAndCertificate", capabilityAndCertificate},
    {"Tests/NativeHALContractTests/main.cpp::switchWithOffsetTapInput", switchWithOffsetTapInput},
    {"Tests/NativeHALContractTests/main.cpp::idleTransportCanHandoffWithoutSourceSamples",
     idleTransportCanHandoffWithoutSourceSamples},
    {"Tests/NativeHALContractTests/main.cpp::idleTransportRejectsInvalidReadiness",
     idleTransportRejectsInvalidReadiness},
    {"Tests/NativeHALContractTests/main.cpp::streamLayoutChannelOrigins",
     streamLayoutChannelOrigins},
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
    {"Tests/NativeHALContractTests/main.cpp::savedTargetsAndPermit", savedTargetsAndPermit},
    {"Tests/NativeHALContractTests/main.cpp::callbackSilenceAndInput", callbackSilenceAndInput},
    {"Tests/NativeHALContractTests/main.cpp::lateCloseAndReuse", lateCloseAndReuse},
    {"Tests/NativeHALContractTests/main.cpp::copiedConfiguration", copiedConfiguration},
    {"Tests/NativeHALContractTests/main.cpp::coalescedCoverage", coalescedCoverage},
    {"Tests/NativeHALContractTests/main.cpp::ioCapacityDoesNotRequireRangeListener",
     ioCapacityDoesNotRequireRangeListener},
    {"Tests/NativeHALContractTests/main.cpp::bufferFrameSizeChangeInvalidates",
     bufferFrameSizeChangeInvalidates},
    {"Tests/NativeHALContractTests/main.cpp::bufferFrameSizeListenerFailureRetainsDebt",
     bufferFrameSizeListenerFailureRetainsDebt},
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
