#include "HALContractHarness.hpp"

#include <barrier>
#include <thread>

namespace native_hal_contract {
namespace {

void invalidationInitialAndNoninvalidatingErrors() {
    inputs = 3;
    resetFixture();
    FTNativeInvalidationSnapshot result{};
    CHECK(ft_native_route_invalidation(nullptr, &result) == FT_NATIVE_FAILED);
    CHECK(ft_native_route_invalidation(nullptr, nullptr) == FT_NATIVE_FAILED);
    for (unsigned mode = 0; mode < 3; ++mode) {
        auto p = prepare(request(state()));
        REQUIRE(p && !hal.ios.empty());
        CHECK(ft_native_route_invalidation(p.get(), nullptr) == FT_NATIVE_FAILED);
        CHECK(sameInvalidation(invalidation(p), {}));
        commit(p, state());
        Signal signal;
        if (mode == 1)
            signal.in.mBuffers[0].mData = nullptr; // Normal idle is not invalidation.
        if (mode == 2)
            signal.input[0] = std::numeric_limits<float>::quiet_NaN(); // DSP error, not binding.
        signal.render(hal.ios.back());
        CHECK(sameInvalidation(invalidation(p), {}));
        CHECK(snapshot(p).callback_error_count == (mode == 2 ? 1U : 0U));
        FTNativeError error{};
        CHECK(ft_native_route_retire(p.get(), &error) == FT_NATIVE_OK);
        CHECK(sameInvalidation(invalidation(p), {}));
        p.reset();
        CHECK(hal.resources() == 0);
    }
}

void invalidationPropertyMetadataAndArchive() {
    inputs = 5;
    for (unsigned mode = 0; mode < 5; ++mode) {
        resetFixture();
        auto p = prepare(request(state()));
        REQUIRE(p && !hal.ios.empty() && !hal.listeners.empty());
        const auto io = hal.ios.back();
        const auto listener = hal.listeners.front();
        commit(p, state());
        const AudioObjectPropertyAddress properties[]{
            {mode == 4 ? AudioObjectPropertySelector(kAudioProcessPropertyPID)
                       : AudioObjectPropertySelector(kAudioDevicePropertyDeviceIsAlive),
             kAudioObjectPropertyScopeOutput, 7},
            {kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeInput, 9}};
        const AudioObjectPropertyAddress zero{};
        const auto count = mode == 0 ? 0U : mode == 2 ? 1U : 2U;
        const auto *addresses = mode == 1 ? nullptr : mode == 2 ? &zero : properties;
        const auto a = callback_observation::allocations.load(),
                   d = callback_observation::deletions.load();
        callback_observation::active = true;
        const auto status = listener.callback(71, count, addresses, listener.data);
        callback_observation::active = false;
        CHECK(status == noErr);
        CHECK(callback_observation::allocations == a && callback_observation::deletions == d);
        const auto record = invalidation(p);
        CHECK(record.source == FT_NATIVE_INVALIDATION_PROPERTY);
        CHECK(record.reason == FT_NATIVE_INVALIDATION_PROPERTY_NOTIFICATION);
        CHECK(record.property_object_id == 71 && record.property_count == count);
        CHECK(record.has_property_address == (count != 0 && addresses != nullptr));
        CHECK(record.property_selector ==
              (record.has_property_address ? addresses[0].mSelector : 0));
        CHECK(record.property_scope == (record.has_property_address ? addresses[0].mScope : 0));
        CHECK(record.property_element == (record.has_property_address ? addresses[0].mElement : 0));
        CHECK(record.observed_device_id == 0 && record.expected_device_id == 0);
        const auto failed = snapshot(p);
        CHECK(failed.failure.kind == FT_NATIVE_BINDING_CHANGED && failed.failure.code == -5101);
        CHECK(failed.failure.operation ==
              (mode == 4 ? FT_NATIVE_RESOLVE_PROCESS : FT_NATIVE_CERTIFY_FORMAT));
        CHECK(failed.callback_error_count == 1);
        Signal silent;
        silent.render(io);
        CHECK(silent.zero());
        CHECK(listener.callback(999, 1, &zero, listener.data) == noErr);
        CHECK(sameInvalidation(invalidation(p), record));
        FTNativeError error{};
        if (mode == 3) {
            hal.holdAggregate = true;
            CHECK(ft_native_route_retire(p.get(), &error) == FT_NATIVE_PENDING);
            CHECK(
                sameInvalidation(invalidation(p), record)); // Render already reader-zero/reclaimed.
            hal.holdAggregate = false;
        }
        CHECK(ft_native_route_retire(p.get(), &error) == FT_NATIVE_OK);
        CHECK(sameInvalidation(invalidation(p), record));
        CHECK(listener.callback(999, 1, &zero, listener.data) == noErr);
        silent.render(io);
        CHECK(silent.zero() && sameInvalidation(invalidation(p), record));
        CHECK(ft_native_route_release(p.get()) == FT_NATIVE_OK);
        (void)p.release();
        auto replacement = prepare(request(state()));
        commit(replacement, state());
        CHECK(listener.callback(999, 1, &zero, listener.data) == noErr);
        silent.render(io);
        CHECK(silent.zero() && sameInvalidation(invalidation(replacement), {}));
        replacement.reset();
        CHECK(hal.resources() == 0);
    }
}

void invalidationIOReasonsAndPrecedence() {
    inputs = 7;
    constexpr std::array reasons{
        FT_NATIVE_INVALIDATION_IO_WRONG_DEVICE,   FT_NATIVE_INVALIDATION_IO_INPUT_SHAPE,
        FT_NATIVE_INVALIDATION_IO_OUTPUT_SHAPE,   FT_NATIVE_INVALIDATION_IO_ABSENT_OUTPUT,
        FT_NATIVE_INVALIDATION_IO_FRAME_MISMATCH, FT_NATIVE_INVALIDATION_IO_INPUT_SHAPE,
        FT_NATIVE_INVALIDATION_IO_OUTPUT_SHAPE};
    for (unsigned mode = 0; mode < reasons.size(); ++mode) {
        resetFixture();
        auto p = prepare(request(state()));
        REQUIRE(p && !hal.ios.empty() && !hal.listeners.empty());
        auto io = hal.ios.back();
        const auto aggregate = io.device;
        const auto listener = hal.listeners.back();
        commit(p, state());
        Signal signal;
        if (mode == 0) {
            io.device = 999;
            signal.in.mBuffers[0].mNumberChannels = 1; // Wrong device wins both shape failures.
            signal.out.mBuffers[0].mNumberChannels = 1;
        }
        if (mode == 1 || mode == 5)
            signal.in.mBuffers[0].mNumberChannels = 1;
        if (mode == 2 || mode == 5)
            signal.out.mBuffers[0].mNumberChannels = 1;
        if (mode == 3) {
            signal.out.mBuffers[0].mData = nullptr;
            signal.out.mBuffers[0].mDataByteSize /= 2; // Absent output precedes frame mismatch.
        }
        if (mode == 4)
            signal.in.mBuffers[0].mDataByteSize /= 2;
        if (mode == 6) {
            // Missing output list is shape, without inventing an output-buffer observation.
            const auto a = callback_observation::allocations.load(),
                       d = callback_observation::deletions.load();
            callback_observation::active = true;
            AudioTimeStamp timestamp{};
            AudioBufferList *absent = nullptr;
            const auto status = io.callback(io.device, &timestamp, &signal.in, &timestamp, absent,
                                            &timestamp, io.data);
            callback_observation::active = false;
            CHECK(status == noErr);
            CHECK(callback_observation::allocations == a && callback_observation::deletions == d);
        } else {
            signal.render(io);
            if (mode != 3)
                CHECK(signal.zero());
            else
                CHECK(signal.output[0] == 0.875F); // Absent output data is not dereferenced.
        }
        const auto record = invalidation(p);
        CHECK(record.source == FT_NATIVE_INVALIDATION_IO && record.reason == reasons[mode]);
        CHECK(record.observed_device_id == io.device && record.expected_device_id == aggregate);
        CHECK(record.property_object_id == 0 && record.property_count == 0 &&
              !record.has_property_address && record.property_selector == 0 &&
              record.property_scope == 0 && record.property_element == 0);
        const auto failed = snapshot(p);
        CHECK(failed.failure.kind == FT_NATIVE_BINDING_CHANGED &&
              failed.failure.operation == FT_NATIVE_CERTIFY_FORMAT && failed.failure.code == -5101);
        CHECK(failed.callback_error_count == 1 && failed.phase == FT_NATIVE_ROUTE_FAILED);
        CHECK(listener.callback(listener.object, 1, &listener.property, listener.data) == noErr);
        CHECK(sameInvalidation(invalidation(p), record));
        FTNativeError error{};
        CHECK(ft_native_route_retire(p.get(), &error) == FT_NATIVE_OK);
        CHECK(sameInvalidation(invalidation(p), record));
        Signal late;
        late.render(io);
        CHECK(late.zero() && sameInvalidation(invalidation(p), record));
        p.reset();
        CHECK(hal.resources() == 0);
    }
}

void invalidationConcurrentPropertyClaims() {
    inputs = 32;
    for (unsigned iteration = 0; iteration < inputs; ++iteration) {
        resetFixture();
        auto p = prepare(request(state()));
        REQUIRE(p && !hal.listeners.empty());
        const auto listener = hal.listeners.back();
        const AudioObjectPropertyAddress addresses[]{
            {kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeInput, 3},
            {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeOutput, 5}};
        std::barrier start(3);
        OSStatus statuses[2]{};
        auto invoke = [&](unsigned index) {
            start.arrive_and_wait();
            statuses[index] = listener.callback(810 + index, 1, &addresses[index], listener.data);
        };
        std::thread first(invoke, 0), second(invoke, 1);
        start.arrive_and_wait();
        // NRT getter can race publication; each successful read is NONE or one complete tuple.
        for (unsigned read = 0; read < 16; ++read) {
            const auto record = invalidation(p);
            if (record.source == FT_NATIVE_INVALIDATION_NONE) {
                CHECK(sameInvalidation(record, {}));
                continue;
            }
            const auto index = record.property_object_id == 810 ? 0U : 1U;
            CHECK(record.property_object_id == 810 + index);
            CHECK(record.source == FT_NATIVE_INVALIDATION_PROPERTY &&
                  record.reason == FT_NATIVE_INVALIDATION_PROPERTY_NOTIFICATION);
            CHECK(record.has_property_address && record.property_count == 1);
            CHECK(record.property_selector == addresses[index].mSelector &&
                  record.property_scope == addresses[index].mScope &&
                  record.property_element == addresses[index].mElement);
        }
        first.join();
        second.join();
        CHECK(statuses[0] == noErr && statuses[1] == noErr);
        const auto record = invalidation(p);
        CHECK(record.source == FT_NATIVE_INVALIDATION_PROPERTY);
        CHECK(record.property_object_id == 810 || record.property_object_id == 811);
        const auto winner = record.property_object_id == 810 ? 0U : 1U;
        CHECK(record.reason == FT_NATIVE_INVALIDATION_PROPERTY_NOTIFICATION &&
              record.has_property_address && record.property_count == 1);
        CHECK(record.property_selector == addresses[winner].mSelector &&
              record.property_scope == addresses[winner].mScope &&
              record.property_element == addresses[winner].mElement);
        CHECK(sameInvalidation(invalidation(p), record));
        const auto failed = snapshot(p);
        CHECK(failed.failure.kind == FT_NATIVE_BINDING_CHANGED &&
              failed.failure.operation == FT_NATIVE_CERTIFY_FORMAT && failed.failure.code == -5101);
        CHECK(failed.callback_error_count >= 1 && failed.callback_error_count <= 2);
        FTNativeError error{};
        CHECK(ft_native_route_retire(p.get(), &error) == FT_NATIVE_OK);
        CHECK(sameInvalidation(invalidation(p), record));
        p.reset();
        CHECK(hal.resources() == 0);
    }
}

void ioCapacityDoesNotRequireRangeListener() {
    inputs = 2;
    for (bool variable : {false, true}) {
        resetFixture();
        // The fake supplies a valid IO certificate, not execution of SystemHal's SDK getter.
        // Exercise the real C consumer without a nominal configuration-range property.
        hal.variableFrames = variable;
        hal.rejectBufferRangeListener = true;
        auto p = prepare(request(state()));
        CHECK(p && !hal.ios.empty());
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
    inputs = 2;
    for (bool variable : {false, true}) {
        resetFixture();
        hal.variableFrames = variable;
        auto p = prepare(request(state()));
        CHECK(p && !hal.ios.empty());
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
    inputs = 2;
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
    inputs = 10;
    resetFixture();
    auto a = prepare(request(state()));
    REQUIRE(a && !hal.ios.empty() && !hal.listeners.empty());
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
    REQUIRE(b && !hal.ios.empty());
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
        REQUIRE(p && !hal.ios.empty());
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
    REQUIRE(bindingRoute && !hal.ios.empty());
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
    REQUIRE(p && !hal.ios.empty());
    const auto io = hal.ios.back();
    gains.fill(-12);
    filter.frequency = std::numeric_limits<double>::quiet_NaN();
    process = 99;
    std::memcpy(uid, "other-xxx", 9);
    commit(p, original);
    auto reference = prepare(request(original, "fixture-b"));
    REQUIRE(reference && !hal.ios.empty());
    const auto referenceIO = hal.ios.back();
    commit(reference, original);
    Signal actual, expected;
    actual.render(io);
    expected.render(referenceIO);
    CHECK(actual.output == expected.output && !actual.zero());
    CHECK(snapshot(p).phase == FT_NATIVE_FIRST_APPLIED);
}

void coalescedCoverage() {
    inputs = 3;
    resetFixture();
    auto initial = state(1, 0.5F);
    initial.processing.loudness_compensation_enabled = true;
    initial.processing.loudness_volume = 0.25F;
    auto p = prepare(request(initial));
    REQUIRE(p && !hal.ios.empty());
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
    REQUIRE(reference && !hal.ios.empty());
    const auto referenceIO = hal.ios.back();
    commit(reference, three);
    // Only EQ and LC are present, both newly prepared by this update. Initial gain is 0.5
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
    REQUIRE(p && !hal.ios.empty());
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
    REQUIRE(p && !hal.ios.empty());
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
    REQUIRE(reference && !hal.ios.empty());
    const auto zeroMaskReferenceIO = hal.ios.back();
    commit(reference, referenceState);
    Signal inherited, direct;
    inherited.render(zeroMaskIO);
    direct.render(zeroMaskReferenceIO);
    CHECK(inherited.output == direct.output && !inherited.zero());
    CHECK(snapshot(p).applied_revision == 3 && snapshot(p).levels_revision == 3);
}

constexpr std::array<CaseUnit, 10> cases{{
    {"Tests/NativeHALContractTests/main.cpp::invalidationInitialAndNoninvalidatingErrors",
     invalidationInitialAndNoninvalidatingErrors},
    {"Tests/NativeHALContractTests/main.cpp::invalidationPropertyMetadataAndArchive",
     invalidationPropertyMetadataAndArchive},
    {"Tests/NativeHALContractTests/main.cpp::invalidationIOReasonsAndPrecedence",
     invalidationIOReasonsAndPrecedence},
    {"Tests/NativeHALContractTests/main.cpp::invalidationConcurrentPropertyClaims",
     invalidationConcurrentPropertyClaims},
    {"Tests/NativeHALContractTests/main.cpp::ioCapacityDoesNotRequireRangeListener",
     ioCapacityDoesNotRequireRangeListener},
    {"Tests/NativeHALContractTests/main.cpp::bufferFrameSizeChangeInvalidates",
     bufferFrameSizeChangeInvalidates},
    {"Tests/NativeHALContractTests/main.cpp::bufferFrameSizeListenerFailureRetainsDebt",
     bufferFrameSizeListenerFailureRetainsDebt},
    {"Tests/NativeHALContractTests/main.cpp::lateCloseAndReuse", lateCloseAndReuse},
    {"Tests/NativeHALContractTests/main.cpp::copiedConfiguration", copiedConfiguration},
    {"Tests/NativeHALContractTests/main.cpp::coalescedCoverage", coalescedCoverage},
}};

} // namespace

std::span<const CaseUnit> invalidationAndUpdateCases() noexcept { return cases; }

} // namespace native_hal_contract
