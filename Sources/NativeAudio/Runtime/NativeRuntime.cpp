// SPDX-License-Identifier: MIT
#include "AudioDSP/Dynamics.hpp"
#include "CallbackSlots.hpp"
#include "CallbackTiming.hpp"
#include "CoherentLevels.hpp"
#include "HalAPI.hpp"
#include "PreparedState.hpp"
#include <algorithm>
#include <bit>
#include <cstring>
#include <mutex>
#include <new>
#include <unistd.h>

namespace finetune::runtime {
static_assert(std::atomic<bool>::is_always_lock_free);
struct RenderState {
    explicit RenderState(FTNativeLevels initial)
        : levels(initial), cachedFastLevels(initial), cachedFullLevels(initial),
          cachedLevels(initial) {}
    CoherentLevels levels;
    CallbackTiming timing;
    FTNativeLevels cachedFastLevels, cachedFullLevels, cachedLevels;
    std::unique_ptr<FTPipeline, decltype(&ft_pipeline_destroy)> pipeline{nullptr,
                                                                         ft_pipeline_destroy};
    StateMailbox commands;
    FormatCertificate format;
    std::unique_ptr<float[]> input, output;
    AudioObjectID aggregate = kAudioObjectUnknown;
    float coefficient = 1;
    std::uint64_t installedRevision = 0; // Exclusive callback consumer after ready.
    std::atomic<bool> ready{false}, permit{false}, armed{false}, firstApplied{false},
        invalidated{false};
    std::atomic_flag executing = ATOMIC_FLAG_INIT;
    std::atomic<std::uint64_t> minimumRevision{0}, processingRevision{0}, levelsRevision{0},
        appliedRevision{0};
    std::atomic<std::uint64_t> callbacks{0}, callbackErrors{0}, errorWord{0};
    std::atomic<std::uint32_t> peak{0};
    std::atomic<bool> invalidationClaimed{false}, invalidationReady{false};
    FTNativeInvalidationSnapshot invalidation{}; // Written once by the claimant, then immutable.
};
struct Listener {
    AudioObjectID object;
    AudioObjectPropertyAddress property;
};
namespace {
// Trivial stable callback metadata is never destroyed/reallocated per route.
constinit CallbackSlots callbackSlots;
std::mutex registryWriter;
std::mutex ownersWriter;
constinit std::array<FTNativeRoute *, CallbackSlots::capacity> owners{};
constexpr std::int32_t invalidInput = -5100, invalidFormat = -5101, concurrentCallback = -5102;

std::uint64_t packError(FTNativeError error) noexcept {
    return std::uint64_t{static_cast<std::uint32_t>(error.code)} |
           (std::uint64_t{static_cast<std::uint32_t>(error.operation)} << 32) |
           (std::uint64_t{static_cast<std::uint32_t>(error.kind)} << 48);
}
FTNativeError unpackError(std::uint64_t value) noexcept {
    return {static_cast<FTNativeFailureKind>((value >> 48) & 0xFF),
            static_cast<FTNativeOperation>((value >> 32) & 0xFFFF),
            std::bit_cast<std::int32_t>(static_cast<std::uint32_t>(value))};
}
void clearOutput(AudioBufferList *output) noexcept {
    if (!output)
        return;
    for (UInt32 b = 0; b < output->mNumberBuffers; ++b)
        if (output->mBuffers[b].mData)
            std::memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
}
void recordError(RenderState &state, FTNativeError error) noexcept {
    state.errorWord.store(packError(error), std::memory_order_release);
    state.callbackErrors.fetch_add(1, std::memory_order_relaxed);
    state.peak.store(0, std::memory_order_relaxed);
}
FTNativeInvalidationSnapshot invalidationSnapshot(const RenderState &state) noexcept {
    if (!state.invalidationReady.load(std::memory_order_acquire))
        return {};
    return state.invalidation;
}
void invalidate(RenderState &state, CallbackCookie cookie, FTNativeOperation operation,
                const FTNativeInvalidationSnapshot &metadata) noexcept {
    // Close render admission before diagnostics. The existing callback lease protects the
    // record through publication; reclamation still waits for this reader to leave.
    state.permit.store(false, std::memory_order_release);
    recordError(state, failure(FT_NATIVE_BINDING_CHANGED, operation, invalidFormat));
    state.invalidated.store(true, std::memory_order_release);
    callbackSlots.close(cookie);
    bool expected = false;
    // One bounded attempt only. First claimant is diagnostic evidence, not causal ordering.
    if (state.invalidationClaimed.compare_exchange_strong(expected, true,
                                                          std::memory_order_relaxed)) {
        state.invalidation = metadata;
        state.invalidationReady.store(true, std::memory_order_release);
    }
}
// 0=valid, 1=normal disabled/absent data, 2=metadata violates the immutable certificate.
int frames(const AudioBufferList *buffers, const StereoLayout &layout, std::uint32_t maximum,
           std::uint32_t &count) noexcept {
    if (!buffers || buffers->mNumberBuffers != layout.bufferCount)
        return 2;
    count = 0;
    bool missing = false;
    for (UInt32 b = 0; b < layout.bufferCount; ++b) {
        const auto &buffer = buffers->mBuffers[b];
        const auto stride = layout.channels[b] * sizeof(float);
        if (buffer.mNumberChannels != layout.channels[b] || stride == 0 ||
            buffer.mDataByteSize % stride != 0)
            return 2;
        const auto current = static_cast<std::uint32_t>(buffer.mDataByteSize / stride);
        if (current > maximum || (b != 0 && current != count))
            return 2;
        count = current;
        if (!buffer.mData)
            missing = true;
        else if (reinterpret_cast<std::uintptr_t>(buffer.mData) % alignof(float) != 0)
            return 2;
    }
    return missing ? 1 : 0;
}
OSStatus audioCallback(AudioObjectID device, const AudioTimeStamp *now,
                       const AudioBufferList *input, const AudioTimeStamp *inputTime,
                       AudioBufferList *output, const AudioTimeStamp *outputTime,
                       void *data) noexcept CA_REALTIME_API {
    const auto cookie = CallbackCookie::fromOpaque(data);
    auto lease = callbackSlots.enter(cookie);
    if (!lease) {
        clearOutput(output);
        return noErr;
    }
    auto &state = *static_cast<RenderState *>(lease.context());
    if (!state.ready.load(std::memory_order_acquire) ||
        state.invalidated.load(std::memory_order_acquire)) {
        clearOutput(output);
        return noErr;
    }
    if (state.executing.test_and_set(std::memory_order_acquire)) {
        recordError(state, failure(FT_NATIVE_FAILURE, FT_NATIVE_PROCESS, concurrentCallback));
        clearOutput(output);
        return noErr;
    }
    struct Execution {
        std::atomic_flag &flag;
        ~Execution() { flag.clear(std::memory_order_release); }
    } execution{state.executing};
    state.callbacks.fetch_add(1, std::memory_order_relaxed);
    std::uint32_t inputFrames = 0, outputFrames = 0;
    const auto inputStatus =
        frames(input, state.format.input, state.format.maximumFrames, inputFrames);
    const auto outputStatus =
        frames(output, state.format.output, state.format.maximumFrames, outputFrames);
    if (device != state.aggregate || inputStatus == 2 || outputStatus != 0 ||
        inputFrames != outputFrames) {
        // Reuse the original validation results and precedence; do not inspect buffers again.
        FTNativeInvalidationSnapshot metadata{};
        metadata.source = FT_NATIVE_INVALIDATION_IO;
        metadata.reason = device != state.aggregate ? FT_NATIVE_INVALIDATION_IO_WRONG_DEVICE
                          : inputStatus == 2        ? FT_NATIVE_INVALIDATION_IO_INPUT_SHAPE
                          : outputStatus == 2       ? FT_NATIVE_INVALIDATION_IO_OUTPUT_SHAPE
                          : outputStatus == 1       ? FT_NATIVE_INVALIDATION_IO_ABSENT_OUTPUT
                                                    : FT_NATIVE_INVALIDATION_IO_FRAME_MISMATCH;
        metadata.observed_device_id = device;
        metadata.expected_device_id = state.aggregate;
        invalidate(state, cookie, FT_NATIVE_CERTIFY_FORMAT, metadata);
        clearOutput(output);
        return noErr;
    }
    const auto timing = state.timing.observe(now, inputTime, outputTime, inputFrames, outputFrames,
                                             inputStatus == 1 || inputFrames == 0);
    // An idle tap may advertise valid frames without source data. A certified nonzero output
    // callback establishes transport readiness, not capture authorization or first-applied audio.
    // Do not keep the old physical IO alive waiting for an idle app to produce samples.
    if (inputStatus == 1 || inputFrames == 0) {
        if (outputFrames != 0)
            state.armed.store(true, std::memory_order_release);
        clearOutput(output);
        return noErr;
    }
    if (state.format.input.bufferCount == 1) {
        std::memcpy(state.input.get(), input->mBuffers[0].mData, inputFrames * 2 * sizeof(float));
    } else {
        const auto *left = static_cast<const float *>(input->mBuffers[0].mData);
        const auto *right = static_cast<const float *>(input->mBuffers[1].mData);
        for (std::uint32_t f = 0; f < inputFrames; ++f) {
            state.input[f * 2] = left[f];
            state.input[f * 2 + 1] = right[f];
        }
    }
    state.levels.tryRead(state.cachedFastLevels); // Exactly one bounded attempt; keep the last
                                                  // coherent tuple on interference.
    state.commands.apply(state.pipeline.get(), state.installedRevision, state.cachedFullLevels);
    state.cachedLevels = state.cachedFastLevels.revision >= state.cachedFullLevels.revision
                             ? state.cachedFastLevels
                             : state.cachedFullLevels;
    const auto status =
        ft_pipeline_process(state.pipeline.get(), {state.input.get(), inputFrames, 2},
                            {state.output.get(), outputFrames, 2},
                            {state.cachedLevels.target_gain, 1, 1, state.coefficient, 0, 1});
    if (status != FT_PIPELINE_OK) {
        recordError(state, failure(FT_NATIVE_FAILURE, FT_NATIVE_PROCESS,
                                   static_cast<std::int32_t>(status)));
        clearOutput(output);
        return noErr;
    }
    state.processingRevision.store(state.installedRevision, std::memory_order_release);
    state.levelsRevision.store(state.cachedLevels.revision, std::memory_order_release);
    state.armed.store(true, std::memory_order_release);
    const bool permitRequested = state.permit.load(std::memory_order_acquire);
    const auto required = state.minimumRevision.load(std::memory_order_acquire);
    const bool permitted = permitRequested && state.installedRevision >= required &&
                           state.cachedLevels.revision >= required;
    if (!permitted || state.cachedLevels.muted) {
        clearOutput(output);
        state.peak.store(0, std::memory_order_release);
    } else {
        float peak = 0;
        for (std::uint32_t n = 0; n < outputFrames * 2; ++n)
            peak = std::max(peak, std::fabs(state.output[n]));
        state.peak.store(std::bit_cast<std::uint32_t>(peak), std::memory_order_release);
        if (state.format.output.bufferCount == 1) {
            std::memcpy(output->mBuffers[0].mData, state.output.get(),
                        outputFrames * 2 * sizeof(float));
        } else {
            auto *left = static_cast<float *>(output->mBuffers[0].mData);
            auto *right = static_cast<float *>(output->mBuffers[1].mData);
            for (std::uint32_t f = 0; f < outputFrames; ++f) {
                left[f] = state.output[f * 2];
                right[f] = state.output[f * 2 + 1];
            }
        }
    }
    if (permitted) {
        state.appliedRevision.store(std::min(state.installedRevision, state.cachedLevels.revision),
                                    std::memory_order_release);
        state.firstApplied.store(true, std::memory_order_release);
    }
    return noErr;
}
OSStatus propertyChanged(AudioObjectID object, UInt32 count,
                         const AudioObjectPropertyAddress *properties, void *data) noexcept {
    const auto cookie = CallbackCookie::fromOpaque(data);
    auto lease = callbackSlots.enter(cookie);
    if (!lease)
        return noErr;
    auto &state = *static_cast<RenderState *>(lease.context());
    FTNativeInvalidationSnapshot metadata{};
    metadata.source = FT_NATIVE_INVALIDATION_PROPERTY;
    metadata.reason = FT_NATIVE_INVALIDATION_PROPERTY_NOTIFICATION;
    metadata.property_object_id = object;
    metadata.property_count = count;
    if (count && properties) {
        metadata.has_property_address = true;
        metadata.property_selector = properties[0].mSelector;
        metadata.property_scope = properties[0].mScope;
        metadata.property_element = properties[0].mElement;
    }
    const auto operation =
        metadata.has_property_address && metadata.property_selector == kAudioProcessPropertyPID
            ? FT_NATIVE_RESOLVE_PROCESS
            : FT_NATIVE_CERTIFY_FORMAT;
    invalidate(state, cookie, operation, metadata);
    return noErr;
}
bool validLevels(FTNativeLevels levels) noexcept {
    return levels.revision != 0 && std::isfinite(levels.target_gain) && levels.target_gain >= 0 &&
           std::isfinite(levels.loudness_volume) && levels.loudness_volume >= 0 &&
           levels.loudness_volume <= 1;
}
FTNativeLevels levelsOf(const FTNativeOutputState &state) noexcept {
    return {state.revision, state.target_gain, state.muted, state.processing.loudness_volume};
}
bool validLayout(const StereoLayout &layout) noexcept {
    return layout.nativePackedFloat32 && std::isfinite(layout.sampleRate) &&
           layout.sampleRate >= 8000 && layout.sampleRate <= 384000 &&
           ((layout.bufferCount == 1 && layout.channels[0] == 2) ||
            (layout.bufferCount == 2 && layout.channels[0] == 1 && layout.channels[1] == 1));
}
bool sameLayout(const StereoLayout &a, const StereoLayout &b) noexcept {
    return a.sampleRate == b.sampleRate && a.bufferCount == b.bufferCount &&
           a.channels == b.channels && a.nativePackedFloat32 == b.nativePackedFloat32;
}
bool validCertificate(const FormatCertificate &value, const OutputDevice &output,
                      const TapDescription &tap) noexcept {
    return validLayout(value.input) && validLayout(value.output) && value.onlyOwnedTapInput &&
           value.intendedPhysicalOutput && value.ioStreamsEnabled && value.maximumFrames > 0 &&
           value.maximumFrames <= 65536 && value.subTap != kAudioObjectUnknown &&
           value.subTapDriftCompensation == 1 &&
           value.subTapDriftQuality == kAudioAggregateDriftCompensationHighQuality &&
           value.input.sampleRate == value.output.sampleRate &&
           value.output.sampleRate == output.output.sampleRate &&
           output.output.sampleRate == output.nominalSampleRate &&
           tap.format.mSampleRate == value.input.sampleRate && tap.format.mChannelsPerFrame == 2 &&
           nativeFloat32Format(tap.format);
}
void copyStats(const RenderState &state, FTNativeRouteSnapshot &snapshot) noexcept {
    snapshot.applied_revision = state.appliedRevision.load(std::memory_order_acquire);
    snapshot.levels_revision = state.levelsRevision.load(std::memory_order_acquire);
    snapshot.processing_revision = state.processingRevision.load(std::memory_order_acquire);
    snapshot.callback_count = state.callbacks.load(std::memory_order_relaxed);
    snapshot.callback_error_count = state.callbackErrors.load(std::memory_order_relaxed);
    snapshot.peak = std::bit_cast<float>(state.peak.load(std::memory_order_acquire));
    snapshot.failure = unpackError(state.errorWord.load(std::memory_order_acquire));
}
} // namespace
} // namespace finetune::runtime

struct FTNativeRoute {
    finetune::runtime::HalAPI api;
    finetune::runtime::OutputDevice physical;
    finetune::runtime::TapDescription tapDescription;
    std::vector<AudioObjectID> processes;
    std::vector<std::int32_t> pids;
    std::vector<finetune::runtime::Listener> listeners;
    std::unique_ptr<finetune::runtime::RenderState> render;
    finetune::runtime::CallbackCookie cookie;
    finetune::runtime::OwnedProcessing desired;
    AudioObjectID tap = kAudioObjectUnknown, aggregate = kAudioObjectUnknown;
    AudioDeviceIOProcID io = nullptr;
    FTNativePhase phase = FT_NATIVE_PREPARED;
    FTNativeError primary{}, cleanup{};
    FTNativeRouteSnapshot archive{};
    FTNativeTimingSnapshot timingArchive{};
    FTNativeInvalidationSnapshot invalidationArchive{};
    std::uint64_t accepted = 0;
    std::atomic<bool> cancelled{false};
    bool startAttempted = false, stopped = false, aggregateDestroyRequested = false;
};

namespace finetune::runtime {
namespace {
FTNativeRoute *allocateOwner() {
    std::lock_guard lock(ownersWriter);
    for (auto &entry : owners)
        if (!entry) {
            entry = new (std::nothrow) FTNativeRoute;
            return entry;
        }
    return nullptr;
}
void releaseOwner(FTNativeRoute *route) {
    std::lock_guard lock(ownersWriter);
    for (auto &entry : owners)
        if (entry == route) {
            entry = nullptr;
            delete route;
            return;
        }
}
FTNativeResult fail(FTNativeError value, FTNativeError *output) noexcept {
    if (output)
        *output = value;
    return FT_NATIVE_FAILED;
}
FTNativeError binding(FTNativeRoute &route) {
    if (route.cancelled.load(std::memory_order_acquire))
        return failure(FT_NATIVE_CANCELLED, FT_NATIVE_INPUT);
    if (!route.render || route.render->invalidated.load(std::memory_order_acquire))
        return failure(FT_NATIVE_BINDING_CHANGED, FT_NATIVE_CERTIFY_FORMAT);
    for (std::size_t i = 0; i < route.processes.size(); ++i) {
        std::int32_t pid = 0;
        const auto status = route.api.processPID(route.api.context, route.processes[i], pid);
        if (status != noErr || pid <= 0 || pid != route.pids[i] || pid == getpid()) {
            const auto error =
                failure(FT_NATIVE_BINDING_CHANGED, FT_NATIVE_RESOLVE_PROCESS, status);
            route.primary = error;
            route.phase = FT_NATIVE_ROUTE_FAILED;
            route.render->permit.store(false, std::memory_order_release);
            route.render->peak.store(0, std::memory_order_relaxed);
            route.render->invalidated.store(true, std::memory_order_release);
            callbackSlots.close(
                route.cookie); // The observer, not its caller, closes stale admission.
            return error;
        }
    }
    return {};
}
FTNativeError update(FTNativeRoute &route, const FTNativeOutputState &state) {
    if (!validLevels(levelsOf(state)))
        return failure(FT_NATIVE_FAILURE, FT_NATIVE_INPUT, invalidInput);
    if (state.revision < route.accepted)
        return failure(FT_NATIVE_CANCELLED, FT_NATIVE_INPUT);
    if (auto error = binding(route); error.kind != FT_NATIVE_NO_FAILURE)
        return error;
    route.render->commands.collect();
    if (state.revision == route.accepted)
        return {};
    OwnedProcessing desired;
    if (!OwnedProcessing::copy(state.processing, desired))
        return failure(FT_NATIVE_FAILURE, FT_NATIVE_INPUT, invalidInput);
    auto candidate = std::unique_ptr<StageCommand>(new (std::nothrow) StageCommand);
    if (!candidate)
        return failure(FT_NATIVE_UNAVAILABLE, FT_NATIVE_PREPARE_DSP);
    if (auto error = prepareStages(&route.desired, desired, route.render->format.input.sampleRate,
                                   candidate->stages);
        error.kind != FT_NATIVE_NO_FAILURE)
        return error;
    if (auto error = binding(route); error.kind != FT_NATIVE_NO_FAILURE)
        return error;
    candidate->revision = state.revision;
    candidate->fullLevels = levelsOf(state);
    route.render->commands.publish(std::move(candidate));
    route.desired = desired;
    route.accepted = state.revision;
    return {};
}
FTNativeError recheck(FTNativeRoute &route) {
    if (auto error = binding(route); error.kind != FT_NATIVE_NO_FAILURE)
        return error;
    OutputDevice current;
    if (auto error =
            route.api.inspectOutput(route.api.context, route.physical.uid.c_str(), current);
        error.kind != FT_NATIVE_NO_FAILURE)
        return error;
    if (current.id != route.physical.id || current.uid != route.physical.uid ||
        current.inputChannels != 0 || !current.stereoOrderKnown || current.aggregate ||
        !sameLayout(current.output, route.physical.output) ||
        current.nominalSampleRate != route.physical.nominalSampleRate)
        return failure(FT_NATIVE_BINDING_CHANGED, FT_NATIVE_RESOLVE_OUTPUT);
    TapDescription tap;
    auto status = route.api.inspectTap(route.api.context, route.tap, tap);
    if (status != noErr)
        return failure(FT_NATIVE_BINDING_CHANGED, FT_NATIVE_READ_TAP, status);
    FormatCertificate currentFormat;
    status = route.api.certify(route.api.context, route.aggregate, route.io, current, tap,
                               currentFormat);
    if (status != noErr || !validCertificate(currentFormat, current, tap) ||
        !sameLayout(currentFormat.input, route.render->format.input) ||
        !sameLayout(currentFormat.output, route.render->format.output) ||
        currentFormat.maximumFrames > route.render->format.maximumFrames ||
        currentFormat.subTap != route.render->format.subTap ||
        currentFormat.hasVariableBufferFrames != route.render->format.hasVariableBufferFrames ||
        currentFormat.inputStreams != route.render->format.inputStreams ||
        currentFormat.outputStreams != route.render->format.outputStreams)
        return failure(FT_NATIVE_BINDING_CHANGED, FT_NATIVE_CERTIFY_FORMAT, status);
    return binding(route);
}
FTNativeError start(FTNativeRoute &route, const FTNativeOutputState &state, bool permitted) {
    if (route.startAttempted)
        return failure(FT_NATIVE_FAILURE, FT_NATIVE_START, invalidInput);
    if (auto error = update(route, state); error.kind != FT_NATIVE_NO_FAILURE)
        return error;
    if (auto error = recheck(route); error.kind != FT_NATIVE_NO_FAILURE)
        return error;
    auto &render = *route.render;
    FTNativeLevels latest = levelsOf(state), fast{};
    if (render.levels.tryRead(fast) && fast.revision >= latest.revision)
        latest = fast;
    // Quiescent before Start: seed latest target without changing stage history or adding a
    // gain setter to the DSP public boundary. No unity/zero default reaches the first frame.
    std::unique_ptr<FTPipeline, decltype(&ft_pipeline_destroy)> seeded(
        ft_pipeline_create(latest.target_gain), ft_pipeline_destroy);
    if (!seeded)
        return failure(FT_NATIVE_UNAVAILABLE, FT_NATIVE_PREPARE_DSP);
    PreparedPipelineStages transfer;
    transfer.changedMask = PreparedPipelineStages::allChanged;
    finetune::native::swapPreparedPipelineStages(render.pipeline.get(), transfer);
    finetune::native::swapPreparedPipelineStages(seeded.get(), transfer);
    render.pipeline.swap(seeded);
    render.commands.apply(render.pipeline.get(), render.installedRevision, render.cachedFullLevels);
    render.commands.collect(); // NRT, before any active audio callback.
    render.minimumRevision.store(state.revision, std::memory_order_release);
    render.permit.store(permitted, std::memory_order_release);
    render.ready.store(true, std::memory_order_release);
    route.startAttempted = true;
    const auto status = route.api.start(route.api.context, route.aggregate, route.io);
    if (status != noErr) {
        render.permit.store(false, std::memory_order_release);
        return failure(FT_NATIVE_FAILURE, FT_NATIVE_START, status);
    }
    route.phase = permitted ? FT_NATIVE_COMMITTED : FT_NATIVE_STARTED;
    return binding(route);
}
OSStatus addWatch(FTNativeRoute &route, AudioObjectID object, AudioObjectPropertySelector selector,
                  AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    const Listener listener{object, {selector, scope, kAudioObjectPropertyElementMain}};
    const auto status = route.api.addListener(route.api.context, object, listener.property,
                                              propertyChanged, route.cookie.opaque());
    if (status == noErr)
        route.listeners.push_back(listener);
    return status;
}
FTNativeError installListeners(FTNativeRoute &route) {
    auto add = [&](AudioObjectID object, AudioObjectPropertySelector selector,
                   AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
        return addWatch(route, object, selector, scope);
    };
    for (auto object : route.processes)
        if (const auto status = add(object, kAudioProcessPropertyPID); status != noErr)
            return failure(FT_NATIVE_FAILURE, FT_NATIVE_INSTALL_LISTENERS, status);
    for (auto object : {route.physical.id, route.aggregate}) {
        if (const auto status = add(object, kAudioDevicePropertyDeviceIsAlive); status != noErr)
            return failure(FT_NATIVE_FAILURE, FT_NATIVE_INSTALL_LISTENERS, status);
        for (auto scope : {kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput}) {
            for (auto selector : std::array<AudioObjectPropertySelector, 2>{
                     kAudioDevicePropertyStreams, kAudioDevicePropertyStreamConfiguration})
                if (const auto status = add(object, selector, scope); status != noErr)
                    return failure(FT_NATIVE_FAILURE, FT_NATIVE_INSTALL_LISTENERS, status);
        }
    }
    if (const auto status = add(route.physical.id, kAudioDevicePropertyNominalSampleRate);
        status != noErr)
        return failure(FT_NATIVE_FAILURE, FT_NATIVE_INSTALL_LISTENERS, status);
    if (const auto status = add(route.physical.id, kAudioDevicePropertyPreferredChannelsForStereo,
                                kAudioObjectPropertyScopeOutput);
        status != noErr)
        return failure(FT_NATIVE_FAILURE, FT_NATIVE_INSTALL_LISTENERS, status);
    if (const auto status = add(route.tap, kAudioTapPropertyFormat); status != noErr)
        return failure(FT_NATIVE_FAILURE, FT_NATIVE_INSTALL_LISTENERS, status);
    if (route.render->format.hasVariableBufferFrames) {
        if (const auto status =
                add(route.aggregate, kAudioDevicePropertyUsesVariableBufferFrameSizes);
            status != noErr)
            return failure(FT_NATIVE_FAILURE, FT_NATIVE_INSTALL_LISTENERS, status);
    }
    // This route's private tap policy is immutable after creation; observe its composition.
    for (auto selector : std::array<AudioObjectPropertySelector, 6>{
             kAudioAggregateDevicePropertyComposition, kAudioAggregateDevicePropertyTapList,
             kAudioAggregateDevicePropertySubTapList,
             kAudioAggregateDevicePropertyFullSubDeviceList,
             kAudioAggregateDevicePropertyMainSubDevice, kAudioDevicePropertyBufferFrameSize})
        if (const auto status = add(route.aggregate, selector); status != noErr)
            return failure(FT_NATIVE_FAILURE, FT_NATIVE_INSTALL_LISTENERS, status);
    auto streams = route.physical.outputStreams;
    streams.insert(streams.end(), route.render->format.inputStreams.begin(),
                   route.render->format.inputStreams.end());
    streams.insert(streams.end(), route.render->format.outputStreams.begin(),
                   route.render->format.outputStreams.end());
    for (auto stream : streams) {
        for (auto selector :
             {kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyStartingChannel})
            if (const auto status = add(stream, selector); status != noErr)
                return failure(FT_NATIVE_FAILURE, FT_NATIVE_INSTALL_LISTENERS, status);
    }
    return {};
}
} // namespace

FTNativeResult prepareWithHal(const FTNativeRouteRequest *request, FTNativeRoute **output,
                              FTNativeError *error, const HalAPI &api) {
    if (output)
        *output = nullptr;
    if (error)
        *error = {};
    if (!request || !output)
        return fail(failure(FT_NATIVE_FAILURE, FT_NATIVE_INPUT, invalidInput), error);
    if (request->capture_session == 0)
        return fail(failure(FT_NATIVE_CAPTURE_NOT_REQUESTED, FT_NATIVE_INPUT), error);
    if (!api.hasCaptureUsageDescription(api.context))
        return fail(failure(FT_NATIVE_UNAVAILABLE, FT_NATIVE_USAGE_DESCRIPTION), error);
    if (!request->output_uid || !*request->output_uid || !request->process_objects ||
        request->process_count == 0 || request->process_count > 256 ||
        request->process_revision == 0 || request->route_generation == 0 ||
        !validLevels(levelsOf(request->initial_state)))
        return fail(failure(FT_NATIVE_FAILURE, FT_NATIVE_INPUT, invalidInput), error);
    OwnedProcessing desired;
    if (!OwnedProcessing::copy(request->initial_state.processing, desired))
        return fail(failure(FT_NATIVE_FAILURE, FT_NATIVE_INPUT, invalidInput), error);
    std::vector<AudioObjectID> selected(request->process_objects,
                                        request->process_objects + request->process_count);
    auto sorted = selected;
    std::sort(sorted.begin(), sorted.end());
    if (sorted.front() == 0 || std::adjacent_find(sorted.begin(), sorted.end()) != sorted.end())
        return fail(failure(FT_NATIVE_FAILURE, FT_NATIVE_RESOLVE_PROCESS, invalidInput), error);
    std::vector<std::int32_t> pids(selected.size());
    for (std::size_t i = 0; i < selected.size(); ++i) {
        const auto status = api.processPID(api.context, selected[i], pids[i]);
        if (status != noErr || pids[i] <= 0)
            return fail(failure(FT_NATIVE_BINDING_CHANGED, FT_NATIVE_RESOLVE_PROCESS, status),
                        error);
        if (pids[i] == getpid())
            return fail(failure(FT_NATIVE_UNSUPPORTED, FT_NATIVE_RESOLVE_PROCESS, invalidInput),
                        error);
    }
    OutputDevice physical;
    if (auto problem = api.inspectOutput(api.context, request->output_uid, physical);
        problem.kind != FT_NATIVE_NO_FAILURE)
        return fail(problem, error);
    if (physical.id == 0 || physical.uid != request->output_uid || physical.inputChannels != 0 ||
        physical.aggregate || !physical.stereoOrderKnown || !validLayout(physical.output) ||
        physical.nominalSampleRate != physical.output.sampleRate)
        return fail(failure(FT_NATIVE_UNSUPPORTED, FT_NATIVE_RESOLVE_OUTPUT, invalidFormat), error);
    auto *route = allocateOwner();
    if (!route)
        return fail(failure(FT_NATIVE_UNAVAILABLE, FT_NATIVE_INPUT), error);
    route->api = api;
    route->physical = std::move(physical);
    route->processes = std::move(selected);
    route->pids = std::move(pids);
    route->desired = desired;
    auto abort = [&](FTNativeError problem) {
        route->primary = problem;
        route->phase = FT_NATIVE_ROUTE_FAILED;
        FTNativeError cleanup{};
        const auto result = ft_native_route_retire(route, &cleanup);
        if (result == FT_NATIVE_OK) {
            ft_native_route_release(route);
        } else
            *output = route;
        return fail(problem, error);
    };
    auto status = api.createTap(api.context, route->processes.data(),
                                static_cast<UInt32>(route->processes.size()), route->tap);
    if (status != noErr || route->tap == 0)
        return abort(failure(FT_NATIVE_FAILURE, FT_NATIVE_CREATE_TAP, status));
    status = api.inspectTap(api.context, route->tap, route->tapDescription);
    if (status != noErr)
        return abort(failure(FT_NATIVE_FAILURE, FT_NATIVE_READ_TAP, status));
    if (route->tapDescription.uid.empty() || !nativeFloat32Format(route->tapDescription.format) ||
        route->tapDescription.format.mChannelsPerFrame != 2 ||
        route->tapDescription.format.mSampleRate != route->physical.output.sampleRate)
        return abort(failure(FT_NATIVE_UNSUPPORTED, FT_NATIVE_READ_TAP, invalidFormat));
    status = api.createAggregate(api.context, route->physical.uid.c_str(),
                                 route->tapDescription.uid.c_str(), route->aggregate);
    if (status != noErr || route->aggregate == 0)
        return abort(failure(FT_NATIVE_FAILURE, FT_NATIVE_CREATE_AGGREGATE, status));
    route->render.reset(new (std::nothrow) RenderState(levelsOf(request->initial_state)));
    if (!route->render)
        return abort(failure(FT_NATIVE_UNAVAILABLE, FT_NATIVE_PREPARE_DSP));
    {
        std::lock_guard lock(registryWriter);
        route->cookie = callbackSlots.publish(route->render.get());
    }
    if (!route->cookie.valid())
        return abort(failure(FT_NATIVE_UNAVAILABLE, FT_NATIVE_PREPARE_DSP));
    status = api.createIOProc(api.context, route->aggregate, audioCallback, route->cookie.opaque(),
                              route->io);
    if (status != noErr || !route->io)
        return abort(failure(FT_NATIVE_FAILURE, FT_NATIVE_CREATE_IOPROC, status));
    status = api.certify(api.context, route->aggregate, route->io, route->physical,
                         route->tapDescription, route->render->format);
    if (status != noErr)
        return abort(failure(FT_NATIVE_FAILURE, FT_NATIVE_CERTIFY_FORMAT, status));
    auto &render = *route->render;
    if (!validCertificate(render.format, route->physical, route->tapDescription))
        return abort(failure(FT_NATIVE_UNSUPPORTED, FT_NATIVE_CERTIFY_FORMAT, invalidFormat));
    render.input.reset(new (std::nothrow) float[render.format.maximumFrames * 2]);
    render.output.reset(new (std::nothrow) float[render.format.maximumFrames * 2]);
    render.pipeline.reset(ft_pipeline_create(request->initial_state.target_gain));
    if (!render.input || !render.output || !render.pipeline)
        return abort(failure(FT_NATIVE_UNAVAILABLE, FT_NATIVE_PREPARE_DSP));
    PreparedPipelineStages initial;
    if (auto problem = prepareStages(nullptr, desired, render.format.input.sampleRate, initial);
        problem.kind != FT_NATIVE_NO_FAILURE)
        return abort(problem);
    finetune::native::swapPreparedPipelineStages(render.pipeline.get(), initial);
    render.installedRevision = request->initial_state.revision;
    render.aggregate = route->aggregate;
    render.coefficient = finetune::dsp::timeConstantCoefficient(
        30, 1000.0F / static_cast<float>(render.format.input.sampleRate));
    route->accepted = request->initial_state.revision;
    if (auto problem = installListeners(*route); problem.kind != FT_NATIVE_NO_FAILURE)
        return abort(problem);
    if (auto problem = recheck(*route); problem.kind != FT_NATIVE_NO_FAILURE)
        return abort(problem);
    *output = route;
    return FT_NATIVE_OK;
}
} // namespace finetune::runtime

using namespace finetune::runtime;
extern "C" FTNativeResult ft_native_route_prepare(const FTNativeRouteRequest *request,
                                                  FTNativeRoute **route, FTNativeError *failure) {
    return prepareWithHal(request, route, failure, systemHalAPI());
}
extern "C" FTNativeResult ft_native_route_update(FTNativeRoute *route,
                                                 const FTNativeOutputState *state,
                                                 FTNativeError *error) {
    if (!route || !state)
        return fail(failure(FT_NATIVE_FAILURE, FT_NATIVE_INPUT, invalidInput), error);
    if (error)
        *error = {};
    const auto problem = update(*route, *state);
    return problem.kind == FT_NATIVE_NO_FAILURE ? FT_NATIVE_OK : fail(problem, error);
}
extern "C" FTNativeResult ft_native_route_start_muted(FTNativeRoute *route,
                                                      const FTNativeOutputState *state,
                                                      FTNativeError *error) {
    if (!route || !state)
        return fail(failure(FT_NATIVE_FAILURE, FT_NATIVE_INPUT, invalidInput), error);
    if (error)
        *error = {};
    const auto problem = start(*route, *state, false);
    if (problem.kind == FT_NATIVE_NO_FAILURE)
        return FT_NATIVE_OK;
    route->primary = problem;
    route->phase = FT_NATIVE_ROUTE_FAILED;
    ft_native_route_cancel(route);
    return fail(problem, error);
}
extern "C" FTNativeResult ft_native_route_commit(FTNativeRoute *route,
                                                 const FTNativeOutputState *state,
                                                 FTNativeError *error) {
    if (!route || !state)
        return fail(failure(FT_NATIVE_FAILURE, FT_NATIVE_INPUT, invalidInput), error);
    if (error)
        *error = {};
    FTNativeError problem{};
    if (!route->startAttempted)
        problem = start(*route, *state, true);
    else {
        problem = update(*route, *state);
        if (problem.kind == FT_NATIVE_NO_FAILURE &&
            !route->render->armed.load(std::memory_order_acquire))
            problem = failure(FT_NATIVE_UNAVAILABLE, FT_NATIVE_START, invalidInput);
        if (problem.kind == FT_NATIVE_NO_FAILURE) {
            route->render->minimumRevision.store(state->revision, std::memory_order_release);
            route->render->permit.store(true, std::memory_order_release);
            route->phase = FT_NATIVE_COMMITTED;
        }
    }
    if (problem.kind == FT_NATIVE_NO_FAILURE)
        return FT_NATIVE_OK;
    route->primary = problem;
    route->phase = FT_NATIVE_ROUTE_FAILED;
    ft_native_route_cancel(route);
    return fail(problem, error);
}
extern "C" FTNativeResult ft_native_route_request_levels(FTNativeRoute *route,
                                                         FTNativeLevels levels) {
    if (!route || !validLevels(levels) || route->cancelled.load(std::memory_order_acquire))
        return FT_NATIVE_FAILED;
    auto lease = callbackSlots.enter(route->cookie);
    if (!lease)
        return FT_NATIVE_FAILED;
    static_cast<RenderState *>(lease.context())->levels.publish(levels);
    return FT_NATIVE_OK;
}
extern "C" void ft_native_route_cancel(FTNativeRoute *route) {
    if (!route)
        return;
    route->cancelled.store(true, std::memory_order_release);
    auto lease = callbackSlots.enter(route->cookie);
    if (lease)
        static_cast<RenderState *>(lease.context())->permit.store(false, std::memory_order_release);
    callbackSlots.close(route->cookie);
}
extern "C" FTNativeResult ft_native_route_snapshot(const FTNativeRoute *route,
                                                   FTNativeRouteSnapshot *snapshot) {
    if (!route || !snapshot)
        return FT_NATIVE_FAILED;
    *snapshot = route->archive;
    snapshot->phase = route->phase;
    snapshot->accepted_revision = route->accepted;
    if (route->render) {
        route->render->commands.collect(); // Same serialized NRT lane; never caller MainActor.
        const bool invalidated = route->render->invalidated.load(std::memory_order_acquire);
        const bool firstApplied = route->render->firstApplied.load(std::memory_order_acquire);
        const bool armed = route->render->armed.load(std::memory_order_acquire);
        copyStats(*route->render,
                  *snapshot); // Acquiring firstApplied precedes its revision/stat reads.
        if (route->phase != FT_NATIVE_RETIRING && route->phase != FT_NATIVE_RETIRED &&
            route->phase != FT_NATIVE_ROUTE_FAILED) {
            if (invalidated)
                snapshot->phase = FT_NATIVE_ROUTE_FAILED;
            else if (firstApplied)
                snapshot->phase = FT_NATIVE_FIRST_APPLIED;
            else if (route->phase != FT_NATIVE_COMMITTED && armed)
                snapshot->phase = FT_NATIVE_ARMED;
        }
    }
    if (route->primary.kind != FT_NATIVE_NO_FAILURE)
        snapshot->failure = route->primary;
    snapshot->cleanup_failure = route->cleanup;
    return FT_NATIVE_OK;
}
extern "C" FTNativeResult ft_native_route_enable_timing(FTNativeRoute *route,
                                                        FTNativeError *error) {
    if (error)
        *error = {};
    if (!route || !route->render || route->startAttempted || route->phase != FT_NATIVE_PREPARED ||
        route->cancelled.load(std::memory_order_acquire))
        return fail(failure(FT_NATIVE_FAILURE, FT_NATIVE_INPUT, invalidInput), error);
    if (!route->render->timing.enable(route->render->format.output.sampleRate))
        return fail(failure(FT_NATIVE_UNAVAILABLE, FT_NATIVE_INPUT, invalidInput), error);
    return FT_NATIVE_OK;
}
extern "C" FTNativeResult ft_native_route_timing_snapshot(const FTNativeRoute *route,
                                                          FTNativeTimingSnapshot *snapshot) {
    if (!route || !snapshot)
        return FT_NATIVE_FAILED;
    *snapshot = route->render ? route->render->timing.snapshot() : route->timingArchive;
    return FT_NATIVE_OK;
}
extern "C" FTNativeResult ft_native_route_invalidation(const FTNativeRoute *route,
                                                       FTNativeInvalidationSnapshot *snapshot) {
    if (!route || !snapshot)
        return FT_NATIVE_FAILED;
    *snapshot = route->render ? invalidationSnapshot(*route->render) : route->invalidationArchive;
    return FT_NATIVE_OK;
}
extern "C" FTNativeResult ft_native_route_retire(FTNativeRoute *route, FTNativeError *error) {
    if (!route)
        return fail(failure(FT_NATIVE_FAILURE, FT_NATIVE_INPUT, invalidInput), error);
    if (error)
        *error = {};
    if (route->phase == FT_NATIVE_RETIRED)
        return FT_NATIVE_OK;
    ft_native_route_cancel(route);
    route->phase = FT_NATIVE_RETIRING;
    if (route->render) {
        if (route->cookie.valid()) {
            ReclaimResult result;
            {
                std::lock_guard lock(registryWriter);
                result = callbackSlots.reclaim(route->cookie);
            }
            if (result.state == ReclaimState::pendingReaders)
                return FT_NATIVE_PENDING;
            if (result.state != ReclaimState::reclaimed)
                return fail(failure(FT_NATIVE_FAILURE, FT_NATIVE_INPUT, invalidInput), error);
        }
        copyStats(*route->render, route->archive);
        route->timingArchive = route->render->timing.snapshot();
        route->invalidationArchive = invalidationSnapshot(*route->render);
        route->render
            .reset(); // All DSP/stage/window/scratch destruction is NRT after actual reader-zero.
    }
    auto cleanup = [&](OSStatus status, FTNativeOperation operation) {
        if (status == noErr || status == kAudioHardwareBadObjectError)
            return FT_NATIVE_OK;
        const auto problem = failure(FT_NATIVE_FAILURE, operation, status);
        if (route->cleanup.kind == FT_NATIVE_NO_FAILURE)
            route->cleanup = problem;
        return fail(problem, error);
    };
    // Device APIs can report !dev after external removal of our private aggregate.
    // The status alone is not absence evidence; a separate successful query must agree.
    auto aggregateDeviceCleanup = [&](OSStatus status, FTNativeOperation operation) {
        if (status == kAudioHardwareBadDeviceError && route->aggregate) {
            bool present = true;
            if (route->api.aggregatePresent(route->api.context, route->aggregate, present) ==
                    noErr &&
                !present)
                return FT_NATIVE_OK;
        }
        return cleanup(status, operation);
    };
    if (route->startAttempted && !route->stopped && route->io) {
        const auto result = aggregateDeviceCleanup(
            route->api.stop(route->api.context, route->aggregate, route->io), FT_NATIVE_STOP);
        if (result != FT_NATIVE_OK)
            return result;
        route->stopped = true;
    }
    if (route->io) {
        const auto result = aggregateDeviceCleanup(
            route->api.destroyIOProc(route->api.context, route->aggregate, route->io),
            FT_NATIVE_DESTROY_IOPROC);
        if (result != FT_NATIVE_OK)
            return result;
        route->io = nullptr;
    }
    while (!route->listeners.empty()) {
        const auto listener = route->listeners.back();
        const auto result = cleanup(route->api.removeListener(route->api.context, listener.object,
                                                              listener.property, propertyChanged,
                                                              route->cookie.opaque()),
                                    FT_NATIVE_REMOVE_LISTENER);
        if (result != FT_NATIVE_OK)
            return result;
        route->listeners.pop_back();
    }
    if (route->aggregate) {
        if (!route->aggregateDestroyRequested) {
            const auto result = aggregateDeviceCleanup(
                route->api.destroyAggregate(route->api.context, route->aggregate),
                FT_NATIVE_DESTROY_AGGREGATE);
            if (result != FT_NATIVE_OK)
                return result;
            route->aggregateDestroyRequested = true;
        }
        bool present = true;
        const auto result =
            cleanup(route->api.aggregatePresent(route->api.context, route->aggregate, present),
                    FT_NATIVE_AWAIT_AGGREGATE_REMOVAL);
        if (result != FT_NATIVE_OK)
            return result;
        if (present)
            return FT_NATIVE_PENDING;
        route->aggregate = kAudioObjectUnknown;
    }
    if (route->tap) {
        const auto result =
            cleanup(route->api.destroyTap(route->api.context, route->tap), FT_NATIVE_DESTROY_TAP);
        if (result != FT_NATIVE_OK)
            return result;
        route->tap = kAudioObjectUnknown;
    }
    route->phase = FT_NATIVE_RETIRED;
    return FT_NATIVE_OK;
}
extern "C" FTNativeResult ft_native_route_release(FTNativeRoute *route) {
    if (!route)
        return FT_NATIVE_FAILED;
    if (route->phase != FT_NATIVE_RETIRED)
        return FT_NATIVE_PENDING;
    releaseOwner(route);
    return FT_NATIVE_OK;
}
extern "C" FTNativeResult ft_native_describe_output(const char *uid,
                                                    FTNativeOutputDescription *description,
                                                    FTNativeError *error) {
    if (!uid || !*uid || !description)
        return fail(failure(FT_NATIVE_FAILURE, FT_NATIVE_INPUT, invalidInput), error);
    if (error)
        *error = {};
    OutputDevice device;
    const auto &api = systemHalAPI();
    if (auto problem = api.inspectOutput(api.context, uid, device);
        problem.kind != FT_NATIVE_NO_FAILURE)
        return fail(problem, error);
    *description = {device.id, device.inputChannels, device.outputChannels,
                    device.output.sampleRate,
                    validLayout(device.output) && device.stereoOrderKnown};
    return FT_NATIVE_OK;
}
