// SPDX-License-Identifier: MIT
#pragma once
#include "../../Sources/NativeAudio/Runtime/HalAPI.hpp"
#include "../../Sources/NativeAudio/Runtime/StreamLayout.hpp"
#include <algorithm>
#include <cstring>
#include <string>
#include <unistd.h>
#include <vector>

namespace native_hal_fixture {
using namespace finetune::runtime;
enum class Fault {
    none,
    tap,
    aggregate,
    io,
    certify,
    listener,
    start,
    stop,
    destroyIO,
    removeListener,
    destroyAggregate,
    destroyTap
};
constexpr OSStatus acquisitionError = -7311, cleanupError = -7312, compositionListenerError = -7313;
struct IO {
    AudioObjectID device;
    AudioDeviceIOProcID id;
    AudioDeviceIOProc callback;
    void *data;
    bool running = false;
};
struct Listener {
    AudioObjectID object;
    AudioObjectPropertyAddress property;
    AudioObjectPropertyListenerProc callback;
    void *data;
};
struct Tap {
    AudioObjectID id;
    TapDescription description;
};
struct Aggregate {
    AudioObjectID id;
    std::string outputUID;
    std::string tapUID;
    bool destroyRequested = false;
};
struct FakeHAL {
    bool usage = true, selfPID = false, microphone = false, unsupportedOutput = false;
    bool mismatchedOutputUID = false, aggregateOutput = false;
    bool wrongTapFormat = false, wrongRate = false, wrongCertificate = false, planar = false;
    bool wrongPhysicalOutput = false;
    bool partial = true, holdAggregate = false;
    Fault fault = Fault::none, cleanupFault = Fault::none;
    OSStatus stopStatus = noErr, destroyIOStatus = noErr, destroyAggregateStatus = noErr;
    OSStatus destroyTapStatus = noErr;
    OSStatus presenceStatus = noErr;
    bool overridePresence = false, presenceValue = true;
    AudioObjectID removeListenerFailureObject = kAudioObjectUnknown;
    OSStatus removeListenerStatus = cleanupError;
    std::uint32_t presenceQueries = 0;
    bool disabledStreams = false, oversized = false, preferredStereo = true;
    bool variableFrames = false, missingSubTap = false;
    bool rejectPrivateSubTapListeners = false, rejectCompositionListener = false;
    bool rejectBufferRangeListener = false, rejectBufferSizeListener = false;
    UInt32 driftCompensation = 1, driftQuality = kAudioAggregateDriftCompensationHighQuality;
    UInt32 maximumFrames = 64, subTapOffset = 4000, inputFirstChannel = 1;
    double nominalRate = 48000;
    std::uint32_t creates = 0, starts = 0, stops = 0, nextID = 1000, listenerAttempts = 0;
    std::vector<Tap> taps;
    std::vector<Aggregate> aggregates;
    std::vector<IO> ios;
    std::vector<Listener> listeners;
    std::size_t resources() const {
        return taps.size() + aggregates.size() + ios.size() + listeners.size();
    }
    bool fails(Fault point) const { return fault == point || cleanupFault == point; }
    bool aggregateExists(AudioObjectID id) const {
        return std::any_of(aggregates.begin(), aggregates.end(),
                           [id](const auto &a) { return a.id == id; });
    }
    void disappearAggregate(AudioObjectID id) {
        std::erase_if(aggregates, [id](const auto &a) { return a.id == id; });
        std::erase_if(ios, [id](const auto &io) { return io.device == id; });
        // Physical device/stream, process and tap objects survive this external loss.
        std::erase_if(listeners, [id](const auto &l) {
            return l.object == id || l.object == id + 1000 || l.object == id + 2000;
        });
    }
    static FakeHAL &at(void *c) { return *static_cast<FakeHAL *>(c); }
    static StereoLayout stereo(bool isPlanar = false) {
        return {48000, isPlanar ? 2U : 1U,
                isPlanar ? std::array<std::uint32_t, 2>{1, 1} : std::array<std::uint32_t, 2>{2, 0},
                true};
    }
    static AudioStreamBasicDescription asbd() {
        AudioStreamBasicDescription f{};
        f.mSampleRate = 48000;
        f.mFormatID = kAudioFormatLinearPCM;
        f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        f.mBytesPerPacket = 8;
        f.mFramesPerPacket = 1;
        f.mBytesPerFrame = 8;
        f.mChannelsPerFrame = 2;
        f.mBitsPerChannel = 32;
        return f;
    }
    HalAPI api() {
        HalAPI a{};
        a.context = this;
        a.hasCaptureUsageDescription = [](void *c) { return at(c).usage; };
        a.processPID = [](void *c, AudioObjectID object, std::int32_t &pid) -> OSStatus {
            pid = at(c).selfPID || object == 99 ? getpid() : getpid() + 1;
            return noErr;
        };
        a.inspectOutput = [](void *c, const char *uid, OutputDevice &out) -> FTNativeError {
            if (!c)
                return failure(FT_NATIVE_FAILURE, FT_NATIVE_RESOLVE_OUTPUT, acquisitionError);
            auto &f = at(c);
            if (!uid || (std::strcmp(uid, "fixture-a") != 0 && std::strcmp(uid, "fixture-b") != 0))
                return failure(FT_NATIVE_UNAVAILABLE, FT_NATIVE_RESOLVE_OUTPUT, acquisitionError);
            out = {};
            out.id = std::strcmp(uid, "fixture-a") == 0 ? 801 : 802;
            out.uid = f.mismatchedOutputUID ? std::string(uid) + "-other" : uid;
            out.inputChannels = f.microphone ? 1 : 0;
            out.aggregate = f.aggregateOutput;
            out.outputChannels = 2;
            out.nominalSampleRate = f.nominalRate;
            out.output = stereo(f.planar);
            out.output.nativePackedFloat32 = !f.unsupportedOutput;
            out.stereoOrderKnown = f.preferredStereo;
            out.outputStreams = {out.id + 100};
            return {};
        };
        a.createTap = [](void *c, const AudioObjectID *, std::uint32_t,
                         AudioObjectID &id) -> OSStatus {
            auto &f = at(c);
            ++f.creates;
            if (f.fault == Fault::tap && !f.partial)
                return acquisitionError;
            id = f.nextID++;
            TapDescription d;
            d.id = id;
            d.uid = "tap-" + std::to_string(id);
            d.format = asbd();
            if (f.wrongTapFormat)
                d.format.mBitsPerChannel = 16;
            f.taps.push_back({id, d});
            return f.fault == Fault::tap ? acquisitionError : noErr;
        };
        a.inspectTap = [](void *c, AudioObjectID id, TapDescription &out) -> OSStatus {
            for (const auto &t : at(c).taps)
                if (t.id == id) {
                    out = t.description;
                    return noErr;
                }
            return acquisitionError;
        };
        a.destroyTap = [](void *c, AudioObjectID id) -> OSStatus {
            auto &f = at(c);
            if (f.destroyTapStatus != noErr)
                return f.destroyTapStatus;
            if (f.fails(Fault::destroyTap))
                return cleanupError;
            std::erase_if(f.taps, [id](const auto &t) { return t.id == id; });
            return noErr;
        };
        a.createAggregate = [](void *c, const char *output, const char *tap,
                               AudioObjectID &id) -> OSStatus {
            auto &f = at(c);
            ++f.creates;
            if (f.fault == Fault::aggregate && !f.partial)
                return acquisitionError;
            id = f.nextID++;
            f.aggregates.push_back({id, output, tap});
            return f.fault == Fault::aggregate ? acquisitionError : noErr;
        };
        a.destroyAggregate = [](void *c, AudioObjectID id) -> OSStatus {
            auto &f = at(c);
            if (f.destroyAggregateStatus != noErr)
                return f.destroyAggregateStatus;
            if (!f.aggregateExists(id))
                return kAudioHardwareBadDeviceError;
            if (f.fails(Fault::destroyAggregate))
                return cleanupError;
            for (auto &a : f.aggregates)
                if (a.id == id)
                    a.destroyRequested = true;
            if (!f.holdAggregate)
                std::erase_if(f.aggregates, [id](const auto &a) { return a.id == id; });
            return noErr;
        };
        a.aggregatePresent = [](void *c, AudioObjectID id, bool &present) -> OSStatus {
            auto &f = at(c);
            ++f.presenceQueries;
            if (f.overridePresence) {
                present = f.presenceValue;
                return f.presenceStatus;
            }
            // Query cannot manufacture disappearance before a destroy request.
            if (!f.holdAggregate)
                std::erase_if(f.aggregates,
                              [id](const auto &a) { return a.id == id && a.destroyRequested; });
            present = std::any_of(f.aggregates.begin(), f.aggregates.end(),
                                  [id](const auto &a) { return a.id == id; });
            return noErr;
        };
        a.createIOProc = [](void *c, AudioObjectID device, AudioDeviceIOProc callback, void *data,
                            AudioDeviceIOProcID &id) -> OSStatus {
            auto &f = at(c);
            ++f.creates;
            if (f.fault == Fault::io && !f.partial)
                return acquisitionError;
            id = reinterpret_cast<AudioDeviceIOProcID>(std::uintptr_t(f.nextID++ * 16));
            f.ios.push_back({device, id, callback, data});
            return f.fault == Fault::io ? acquisitionError : noErr;
        };
        a.destroyIOProc = [](void *c, AudioObjectID device, AudioDeviceIOProcID id) -> OSStatus {
            auto &f = at(c);
            if (f.destroyIOStatus != noErr)
                return f.destroyIOStatus;
            if (!f.aggregateExists(device))
                return kAudioHardwareBadDeviceError;
            if (f.fails(Fault::destroyIO))
                return cleanupError;
            if (std::any_of(f.ios.begin(), f.ios.end(),
                            [id](const auto &i) { return i.id == id && i.running; }))
                return cleanupError;
            std::erase_if(f.ios, [id](const auto &i) { return i.id == id; });
            return noErr;
        };
        a.certify = [](void *c, AudioObjectID device, AudioDeviceIOProcID,
                       const OutputDevice &physical, const TapDescription &,
                       FormatCertificate &out) -> OSStatus {
            auto &f = at(c);
            if (f.fault == Fault::certify)
                return acquisitionError;
            out = {};
            auto format = asbd();
            if (f.wrongRate)
                format.mSampleRate = 44100;
            if (f.planar) {
                format.mFormatFlags |= kAudioFormatFlagIsNonInterleaved;
                format.mBytesPerFrame = format.mBytesPerPacket = sizeof(float);
            }
            const auto configuration = stereo(f.planar);
            const StreamFormatObservation observed[]{{format, f.inputFirstChannel}};
            out.onlyOwnedTapInput = !f.wrongCertificate && physical.inputChannels == 0;
            out.intendedPhysicalOutput = !f.wrongPhysicalOutput;
            const auto origin = out.onlyOwnedTapInput && out.intendedPhysicalOutput
                                    ? StreamChannelOrigin::ownedTapInput
                                    : StreamChannelOrigin::device;
            out.input = decodeStereoLayout(
                std::span(configuration.channels.data(), configuration.bufferCount), observed,
                origin);
            out.output = physical.output;
            out.maximumFrames = f.oversized ? 65537 : f.maximumFrames;
            out.subTap = f.missingSubTap ? kAudioObjectUnknown : device + f.subTapOffset;
            out.subTapDriftCompensation = f.driftCompensation;
            out.subTapDriftQuality = f.driftQuality;
            out.hasVariableBufferFrames = f.variableFrames;
            out.ioStreamsEnabled = !f.disabledStreams;
            out.inputStreams = {device + 1000};
            out.outputStreams = {device + 2000};
            return noErr;
        };
        a.start = [](void *c, AudioObjectID, AudioDeviceIOProcID id) -> OSStatus {
            auto &f = at(c);
            ++f.starts;
            for (auto &i : f.ios)
                if (i.id == id)
                    i.running = true;
            return f.fault == Fault::start ? acquisitionError : noErr;
        };
        a.stop = [](void *c, AudioObjectID device, AudioDeviceIOProcID id) -> OSStatus {
            auto &f = at(c);
            ++f.stops;
            if (f.stopStatus != noErr)
                return f.stopStatus;
            if (!f.aggregateExists(device))
                return kAudioHardwareBadDeviceError;
            if (f.fails(Fault::stop))
                return cleanupError;
            for (auto &i : f.ios)
                if (i.id == id)
                    i.running = false;
            return noErr;
        };
        a.addListener = [](void *c, AudioObjectID object, AudioObjectPropertyAddress p,
                           AudioObjectPropertyListenerProc callback, void *data) -> OSStatus {
            auto &f = at(c);
            ++f.listenerAttempts;
            if (f.fault == Fault::listener && f.listenerAttempts == 3)
                return acquisitionError;
            if (f.rejectPrivateSubTapListeners &&
                (p.mSelector == kAudioSubTapPropertyDriftCompensation ||
                 p.mSelector == kAudioSubTapPropertyDriftCompensationQuality) &&
                std::any_of(f.aggregates.begin(), f.aggregates.end(), [&](const auto &aggregate) {
                    return object == aggregate.id + f.subTapOffset;
                }))
                return kAudioHardwareBadObjectError;
            if (f.rejectCompositionListener &&
                p.mSelector == kAudioAggregateDevicePropertyComposition &&
                std::any_of(f.aggregates.begin(), f.aggregates.end(),
                            [&](const auto &aggregate) { return object == aggregate.id; }))
                return compositionListenerError;
            if (((f.rejectBufferRangeListener &&
                  p.mSelector == kAudioDevicePropertyBufferFrameSizeRange) ||
                 (f.rejectBufferSizeListener &&
                  p.mSelector == kAudioDevicePropertyBufferFrameSize)) &&
                std::any_of(f.aggregates.begin(), f.aggregates.end(),
                            [&](const auto &aggregate) { return object == aggregate.id; }))
                return kAudioHardwareUnknownPropertyError;
            f.listeners.push_back({object, p, callback, data});
            return noErr;
        };
        a.removeListener = [](void *c, AudioObjectID object, AudioObjectPropertyAddress p,
                              AudioObjectPropertyListenerProc callback, void *data) -> OSStatus {
            auto &f = at(c);
            if (object == f.removeListenerFailureObject)
                return f.removeListenerStatus;
            if (f.fails(Fault::removeListener))
                return cleanupError;
            const auto before = f.listeners.size();
            std::erase_if(f.listeners, [&](const auto &l) {
                return l.object == object && l.property.mSelector == p.mSelector &&
                       l.property.mScope == p.mScope && l.callback == callback && l.data == data;
            });
            if (before == f.listeners.size())
                return kAudioHardwareBadObjectError;
            return noErr;
        };
        return a;
    }
};
inline FakeHAL hal;
} // namespace native_hal_fixture

// Test executable supplies the external OS provider. SystemHal.mm is never linked.
namespace finetune::runtime {
const HalAPI &systemHalAPI() noexcept {
    static const HalAPI api = native_hal_fixture::hal.api();
    return api;
}
} // namespace finetune::runtime
