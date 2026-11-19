// SPDX-License-Identifier: MIT
#include "HALContractHarness.hpp"

namespace native_hal_contract {
namespace {

void latestCommitState() {
    inputs = 2;
    for (const auto gains : {std::array{0.25F, 0.75F}, std::array{0.75F, 0.25F}}) {
        CHECK(hal.resources() == 0);
        hal = FakeHAL{};
        auto p = prepare(request(state(1, gains[0])));
        REQUIRE(p && !hal.ios.empty());
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

void acquisitionGuards() {
    inputs = 3;
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
    inputs = 11;
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

void resolveOutputRejections() {
    inputs = 6;
    // Each condition reports its own local code: a field failure that only exists while the
    // device settles must stay attributable after the state has changed.
    const std::int32_t expected[] = {
        FT_NATIVE_OUTPUT_IDENTITY_MISMATCH,
        FT_NATIVE_OUTPUT_CAPTURE_CHANNELS,
        FT_NATIVE_OUTPUT_AGGREGATE,
        FT_NATIVE_OUTPUT_STEREO_ORDER,
        FT_NATIVE_OUTPUT_LAYOUT,
        FT_NATIVE_OUTPUT_RATE_MISMATCH,
    };
    for (unsigned mode = 0; mode < 6; ++mode) {
        resetFixture();
        if (mode == 0)
            hal.mismatchedOutputUID = true;
        if (mode == 1)
            hal.microphone = true;
        if (mode == 2)
            hal.aggregateOutput = true;
        if (mode == 3)
            hal.preferredStereo = false;
        if (mode == 4)
            hal.unsupportedOutput = true;
        if (mode == 5)
            hal.nominalRate = 44100;
        const auto r = request(state());
        FTNativeRoute *p = nullptr;
        FTNativeError error{};
        CHECK(ft_native_route_prepare(&r, &p, &error) == FT_NATIVE_FAILED);
        CHECK(p == nullptr && hal.creates == 0 && hal.starts == 0 && hal.resources() == 0);
        CHECK(error.kind == FT_NATIVE_UNSUPPORTED);
        CHECK(error.operation == FT_NATIVE_RESOLVE_OUTPUT);
        CHECK(error.code == expected[mode]);
    }
    // A device that passes every condition still prepares.
    resetFixture();
    auto r = prepare(request(state()));
    CHECK(r != nullptr);
}

void switchWithOffsetTapInput() {
    inputs = 3;
    for (const UInt32 origin : {3U, 5U, 7U}) {
        resetFixture();
        auto initial = state();
        auto old = prepare(request(initial));
        CHECK(old);
        if (!old)
            continue;
        commit(old, initial);
        const auto oldIO = hal.ios.back();
        hal.inputFirstChannel = origin;
        auto candidate = prepare(request(initial, "fixture-b"));
        CHECK(candidate);
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
    REQUIRE(old);
    commit(old, initial);
    auto candidate = prepare(request(initial, "fixture-b"));
    REQUIRE(candidate);
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
    inputs = 6;
    for (unsigned mode = 0; mode < 6; ++mode) {
        resetFixture();
        auto initial = state();
        auto candidate = prepare(request(initial));
        CHECK(candidate);
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
    inputs = 0;
    const UInt32 interleaved[]{2}, planar[]{1, 1}, extra[]{1, 1, 1};
    auto stereo = FakeHAL::asbd();
    auto mono = stereo;
    mono.mChannelsPerFrame = 1;
    mono.mBytesPerFrame = mono.mBytesPerPacket = sizeof(float);
    const auto verify = [&](std::span<const UInt32> channels,
                            std::span<const StreamFormatObservation> streams, bool device,
                            bool ownedTap) {
        ++inputs;
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
        ++inputs;
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

void bluetoothTapPolicy() {
    inputs = 4;
    // A Bluetooth output shares its clock with the process tap: drift compensation is off.
    resetFixture();
    hal.bluetooth = true;
    hal.driftCompensation = 0;
    auto bt = prepare(request(state()));
    REQUIRE(bt);
    CHECK(hal.requestedDrift == 0);
    CHECK(snapshot(bt).failure.kind == FT_NATIVE_NO_FAILURE);
    bt.reset();
    CHECK(hal.resources() == 0);

    // A read-back that disagrees with the transport's policy is still rejected.
    resetFixture();
    hal.bluetooth = true;
    hal.wrongDrift = true;
    FTNativeRoute *p = nullptr;
    FTNativeError error{};
    const auto r = request(state());
    CHECK(ft_native_route_prepare(&r, &p, &error) == FT_NATIVE_FAILED);
    CHECK(p == nullptr && hal.starts == 0 && hal.resources() == 0);
    CHECK(error.kind == FT_NATIVE_UNSUPPORTED && error.operation == FT_NATIVE_CERTIFY_FORMAT);
    CHECK(error.code == -5101);

    // Wired outputs keep requesting and certifying drift compensation.
    resetFixture();
    auto wired = prepare(request(state()));
    REQUIRE(wired);
    CHECK(hal.requestedDrift == 1);
}

constexpr std::array<CaseUnit, 9> cases{{
    {"Tests/NativeHALContractTests/main.cpp::latestCommitState", latestCommitState},
    {"Tests/NativeHALContractTests/main.cpp::acquisitionGuards", acquisitionGuards},
    {"Tests/NativeHALContractTests/main.cpp::capabilityAndCertificate", capabilityAndCertificate},
    {"Tests/NativeHALContractTests/main.cpp::resolveOutputRejections", resolveOutputRejections},
    {"Tests/NativeHALContractTests/main.cpp::switchWithOffsetTapInput", switchWithOffsetTapInput},
    {"Tests/NativeHALContractTests/main.cpp::idleTransportCanHandoffWithoutSourceSamples",
     idleTransportCanHandoffWithoutSourceSamples},
    {"Tests/NativeHALContractTests/main.cpp::idleTransportRejectsInvalidReadiness",
     idleTransportRejectsInvalidReadiness},
    {"Tests/NativeHALContractTests/main.cpp::streamLayoutChannelOrigins",
     streamLayoutChannelOrigins},
    {"Tests/NativeHALContractTests/main.cpp::bluetoothTapPolicy", bluetoothTapPolicy},
}};

} // namespace

std::span<const CaseUnit> acquisitionAndFormatCases() noexcept { return cases; }

} // namespace native_hal_contract
