// SPDX-License-Identifier: MIT
// Non-real-time CoreAudio/Objective-C boundary. No function here is called by an IOProc.
#include "AggregateTapPolicy.hpp"
#include "HalAPI.hpp"
#include "StreamLayout.hpp"
#include <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>
#include <cstring>
#include <memory>
#include <os/log.h>

namespace finetune::runtime {
namespace {
struct CFGuard {
    CFTypeRef value = nullptr;
    explicit CFGuard(CFTypeRef object) : value(object) {}
    ~CFGuard() {
        if (value)
            CFRelease(value);
    }
    CFGuard(const CFGuard &) = delete;
    CFGuard &operator=(const CFGuard &) = delete;
};
AudioObjectPropertyAddress
address(AudioObjectPropertySelector selector,
        AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    return {selector, scope, kAudioObjectPropertyElementMain};
}
OSStatus certificationFailure(OSStatus status, const char *role, const char *api,
                              const AudioObjectPropertyAddress &property) {
    if (role && status != noErr)
        os_log_error(OS_LOG_DEFAULT,
                     "FineTune certifyFormat role=%{public}s api=%{public}s selector=0x%{public}x "
                     "scope=0x%{public}x native_code=%{public}d",
                     role, api, property.mSelector, property.mScope, status);
    return status;
}
template <class T>
OSStatus scalar(AudioObjectID object, AudioObjectPropertySelector selector, T &value,
                AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal,
                const char *role = nullptr) {
    auto property = address(selector, scope);
    UInt32 bytes = sizeof(T);
    const auto status = AudioObjectGetPropertyData(object, &property, 0, nullptr, &bytes, &value);
    if (status != noErr)
        return certificationFailure(status, role, "AudioObjectGetPropertyData", property);
    return bytes == sizeof(T) ? OSStatus{0}
                              : static_cast<OSStatus>(kAudioHardwareBadPropertySizeError);
}
template <class T>
OSStatus array(AudioObjectID object, AudioObjectPropertySelector selector, std::vector<T> &values,
               AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal,
               const char *role = nullptr) {
    auto property = address(selector, scope);
    UInt32 bytes = 0;
    auto status = AudioObjectGetPropertyDataSize(object, &property, 0, nullptr, &bytes);
    if (status != noErr)
        return certificationFailure(status, role, "AudioObjectGetPropertyDataSize", property);
    if (bytes % sizeof(T) != 0)
        return kAudioHardwareBadPropertySizeError;
    values.resize(bytes / sizeof(T));
    if (bytes == 0)
        return noErr;
    status = AudioObjectGetPropertyData(object, &property, 0, nullptr, &bytes, values.data());
    if (status == noErr && bytes % sizeof(T) == 0)
        values.resize(bytes / sizeof(T));
    if (status != noErr)
        return certificationFailure(status, role, "AudioObjectGetPropertyData", property);
    return bytes % sizeof(T) == 0 ? OSStatus{0}
                                  : static_cast<OSStatus>(kAudioHardwareBadPropertySizeError);
}
OSStatus copyString(CFStringRef value, std::string &output) {
    if (!value || CFGetTypeID(value) != CFStringGetTypeID())
        return kAudioHardwareIllegalOperationError;
    const auto capacity =
        CFStringGetMaximumSizeForEncoding(CFStringGetLength(value), kCFStringEncodingUTF8) + 1;
    if (capacity <= 0)
        return kAudioHardwareIllegalOperationError;
    std::vector<char> bytes(static_cast<std::size_t>(capacity));
    if (!CFStringGetCString(value, bytes.data(), capacity, kCFStringEncodingUTF8))
        return kAudioHardwareIllegalOperationError;
    output.assign(bytes.data());
    return noErr;
}
OSStatus stringProperty(AudioObjectID object, AudioObjectPropertySelector selector,
                        std::string &value) {
    CFStringRef text = nullptr;
    const auto status = scalar(object, selector, text);
    CFGuard guard(text);
    return status == noErr ? copyString(text, value) : status;
}
OSStatus channelConfiguration(AudioObjectID object, AudioObjectPropertyScope scope,
                              std::vector<UInt32> &channels, const char *role = nullptr) {
    auto property = address(kAudioDevicePropertyStreamConfiguration, scope);
    UInt32 bytes = 0;
    auto status = AudioObjectGetPropertyDataSize(object, &property, 0, nullptr, &bytes);
    if (status != noErr)
        return certificationFailure(status, role, "AudioObjectGetPropertyDataSize", property);
    if (bytes < offsetof(AudioBufferList, mBuffers))
        return kAudioHardwareBadPropertySizeError;
    std::vector<std::byte> storage(bytes);
    status = AudioObjectGetPropertyData(object, &property, 0, nullptr, &bytes, storage.data());
    if (status != noErr)
        return certificationFailure(status, role, "AudioObjectGetPropertyData", property);
    const auto *buffers = reinterpret_cast<const AudioBufferList *>(storage.data());
    const auto needed =
        offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * buffers->mNumberBuffers;
    if (needed > bytes)
        return kAudioHardwareBadPropertySizeError;
    channels.clear();
    for (UInt32 i = 0; i < buffers->mNumberBuffers; ++i)
        channels.push_back(buffers->mBuffers[i].mNumberChannels);
    return noErr;
}
OSStatus layout(AudioObjectID device, AudioObjectPropertyScope scope, StereoLayout &result,
                std::vector<AudioObjectID> &streams, std::uint32_t *totalChannels = nullptr,
                const char *role = nullptr,
                StreamChannelOrigin origin = StreamChannelOrigin::device) {
    std::vector<UInt32> channels;
    auto status = channelConfiguration(device, scope, channels, role);
    if (status != noErr)
        return status;
    status = array(device, kAudioDevicePropertyStreams, streams, scope, role);
    if (status != noErr)
        return status;
    result = {};
    if (totalChannels) {
        *totalChannels = 0;
        for (const auto count : channels)
            *totalChannels += count;
    }
    if (!((channels.size() == 1 && channels[0] == 2) ||
          (channels.size() == 2 && channels[0] == 1 && channels[1] == 1)))
        return noErr;
    if (streams.empty() || streams.size() > 2)
        return noErr;
    std::vector<StreamFormatObservation> observed;
    for (const auto stream : streams) {
        StreamFormatObservation value{};
        status = scalar(stream, kAudioStreamPropertyVirtualFormat, value.format,
                        kAudioObjectPropertyScopeGlobal, role);
        if (status != noErr)
            return status;
        status = scalar(stream, kAudioStreamPropertyStartingChannel, value.firstChannel,
                        kAudioObjectPropertyScopeGlobal, role);
        if (status != noErr)
            return status;
        observed.push_back(value);
    }
    result = decodeStereoLayout(channels, observed, origin);
    return noErr;
}
bool hasUsage(void *) {
    const auto bundle = CFBundleGetMainBundle();
    const auto value =
        bundle
            ? CFBundleGetValueForInfoDictionaryKey(bundle, CFSTR("NSAudioCaptureUsageDescription"))
            : nullptr;
    return value && CFGetTypeID(value) == CFStringGetTypeID() &&
           CFStringGetLength(static_cast<CFStringRef>(value)) != 0;
}
OSStatus processPID(void *, AudioObjectID object, std::int32_t &pid) {
    return scalar(object, kAudioProcessPropertyPID, pid);
}
FTNativeError inspectOutput(void *, const char *uid, OutputDevice &output) {
    const auto text = CFStringCreateWithCString(nullptr, uid, kCFStringEncodingUTF8);
    CFGuard guard(text);
    if (!text)
        return failure(FT_NATIVE_UNSUPPORTED, FT_NATIVE_RESOLVE_OUTPUT);
    auto property = address(kAudioHardwarePropertyTranslateUIDToDevice);
    UInt32 bytes = sizeof(output.id);
    auto status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, sizeof(text),
                                             &text, &bytes, &output.id);
    if (status != noErr || output.id == kAudioObjectUnknown)
        return failure(FT_NATIVE_UNAVAILABLE, FT_NATIVE_RESOLVE_OUTPUT, status);
    status = stringProperty(output.id, kAudioDevicePropertyDeviceUID, output.uid);
    if (status != noErr)
        return failure(FT_NATIVE_FAILURE, FT_NATIVE_RESOLVE_OUTPUT, status);
    std::vector<UInt32> inputs;
    status = channelConfiguration(output.id, kAudioObjectPropertyScopeInput, inputs);
    if (status != noErr)
        return failure(FT_NATIVE_FAILURE, FT_NATIVE_RESOLVE_OUTPUT, status);
    for (const auto count : inputs)
        output.inputChannels += count;
    AudioClassID type = 0;
    status = scalar(output.id, kAudioObjectPropertyClass, type);
    if (status != noErr)
        return failure(FT_NATIVE_FAILURE, FT_NATIVE_RESOLVE_OUTPUT, status);
    output.aggregate = type == kAudioAggregateDeviceClassID;
    status = scalar(output.id, kAudioDevicePropertyNominalSampleRate, output.nominalSampleRate);
    if (status != noErr)
        return failure(FT_NATIVE_FAILURE, FT_NATIVE_RESOLVE_OUTPUT, status);
    status = scalar(output.id, kAudioDevicePropertyTransportType, output.transportType);
    if (status != noErr)
        return failure(FT_NATIVE_FAILURE, FT_NATIVE_RESOLVE_OUTPUT, status);
    status = layout(output.id, kAudioObjectPropertyScopeOutput, output.output, output.outputStreams,
                    &output.outputChannels);
    if (status != noErr)
        return failure(FT_NATIVE_FAILURE, FT_NATIVE_RESOLVE_OUTPUT, status);
    UInt32 stereo[2]{};
    auto stereoProperty =
        address(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput);
    bytes = sizeof(stereo);
    status = AudioObjectGetPropertyData(output.id, &stereoProperty, 0, nullptr, &bytes, stereo);
    output.stereoOrderKnown =
        status == noErr && bytes == sizeof(stereo) && stereo[0] == 1 && stereo[1] == 2;
    return {};
}
OSStatus createTap(void *, const AudioObjectID *processes, std::uint32_t count,
                   AudioObjectID &tap) {
    @autoreleasepool {
        NSMutableArray<NSNumber *> *objects = [NSMutableArray arrayWithCapacity:count];
        for (UInt32 i = 0; i < count; ++i)
            [objects addObject:@(processes[i])];
        CATapDescription *description =
            [[CATapDescription alloc] initStereoMixdownOfProcesses:objects];
        description.name = @"FineTune Process Route";
        [description setPrivate:YES];
        description.muteBehavior = CATapMutedWhenTapped;
        const auto status = AudioHardwareCreateProcessTap(description, &tap);
#if !__has_feature(objc_arc)
        [description release];
#endif
        return status;
    }
}
OSStatus inspectTap(void *, AudioObjectID tap, TapDescription &output) {
    output.id = tap;
    auto status = stringProperty(tap, kAudioTapPropertyUID, output.uid);
    return status == noErr ? scalar(tap, kAudioTapPropertyFormat, output.format) : status;
}
OSStatus createAggregate(void *, const OutputDevice &physical, const char *tapUID,
                         AudioObjectID &aggregate) {
    auto subDevice = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    auto tap = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks,
                                         &kCFTypeDictionaryValueCallBacks);
    auto composition = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks,
                                                 &kCFTypeDictionaryValueCallBacks);
    CFGuard a(subDevice), b(tap), c(composition);
    auto destination =
        CFStringCreateWithCString(nullptr, physical.uid.c_str(), kCFStringEncodingUTF8);
    auto source = CFStringCreateWithCString(nullptr, tapUID, kCFStringEncodingUTF8);
    auto uuid = CFUUIDCreate(nullptr);
    CFGuard d(destination), e(source), f(uuid);
    auto identifier = uuid ? CFUUIDCreateString(nullptr, uuid) : nullptr;
    CFGuard g(identifier);
    const SInt32 zero = 0, one = 1, quality = kAudioAggregateDriftCompensationHighQuality;
    auto off = CFNumberCreate(nullptr, kCFNumberSInt32Type, &zero);
    auto on = CFNumberCreate(nullptr, kCFNumberSInt32Type, &one);
    auto driftQuality = CFNumberCreate(nullptr, kCFNumberSInt32Type, &quality);
    CFGuard h(off), i(on), j(driftQuality);
    if (!subDevice || !tap || !composition || !destination || !source || !uuid || !identifier ||
        !off || !on || !driftQuality)
        return kAudioHardwareUnspecifiedError;
    CFDictionarySetValue(subDevice, CFSTR(kAudioSubDeviceUIDKey), destination);
    CFDictionarySetValue(subDevice, CFSTR(kAudioSubDeviceInputChannelsKey), off);
    CFDictionarySetValue(tap, CFSTR(kAudioSubTapUIDKey), source);
    CFDictionarySetValue(tap, CFSTR(kAudioSubTapDriftCompensationKey),
                         expectedDriftCompensation(physical) ? on : off);
    CFDictionarySetValue(tap, CFSTR(kAudioSubTapDriftCompensationQualityKey), driftQuality);
    const void *members[]{subDevice}, *taps[]{tap};
    auto memberList = CFArrayCreate(nullptr, members, 1, &kCFTypeArrayCallBacks);
    auto tapList = CFArrayCreate(nullptr, taps, 1, &kCFTypeArrayCallBacks);
    CFGuard k(memberList), l(tapList);
    if (!memberList || !tapList)
        return kAudioHardwareUnspecifiedError;
    CFDictionarySetValue(composition, CFSTR(kAudioAggregateDeviceNameKey),
                         CFSTR("FineTune Process Route"));
    CFDictionarySetValue(composition, CFSTR(kAudioAggregateDeviceUIDKey), identifier);
    CFDictionarySetValue(composition, CFSTR(kAudioAggregateDeviceMainSubDeviceKey), destination);
    CFDictionarySetValue(composition, CFSTR(kAudioAggregateDeviceClockDeviceKey), destination);
    CFDictionarySetValue(composition, CFSTR(kAudioAggregateDeviceSubDeviceListKey), memberList);
    CFDictionarySetValue(composition, CFSTR(kAudioAggregateDeviceTapListKey), tapList);
    CFDictionarySetValue(composition, CFSTR(kAudioAggregateDeviceIsPrivateKey), on);
    CFDictionarySetValue(composition, CFSTR(kAudioAggregateDeviceIsStackedKey), off);
    CFDictionarySetValue(composition, CFSTR(kAudioAggregateDeviceTapAutoStartKey), off);
    return AudioHardwareCreateAggregateDevice(composition, &aggregate);
}
bool oneString(CFArrayRef list, const std::string &expected) {
    if (!list || CFGetTypeID(list) != CFArrayGetTypeID() || CFArrayGetCount(list) != 1)
        return false;
    const auto value = CFArrayGetValueAtIndex(list, 0);
    std::string observed;
    return value && copyString(static_cast<CFStringRef>(value), observed) == noErr &&
           observed == expected;
}
OSStatus streamUsage(AudioObjectID device, AudioDeviceIOProcID io, AudioObjectPropertyScope scope,
                     std::size_t count) {
    const auto bytes =
        offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + count * sizeof(UInt32);
    std::vector<std::byte> storage(bytes);
    auto *usage = reinterpret_cast<AudioHardwareIOProcStreamUsage *>(storage.data());
    usage->mIOProc = reinterpret_cast<void *>(io);
    usage->mNumberStreams = static_cast<UInt32>(count);
    for (std::size_t n = 0; n < count; ++n)
        usage->mStreamIsOn[n] = 1;
    auto property = address(kAudioDevicePropertyIOProcStreamUsage, scope);
    auto status = AudioObjectSetPropertyData(device, &property, 0, nullptr,
                                             static_cast<UInt32>(bytes), usage);
    if (status != noErr)
        return certificationFailure(status, "certifyFormat.streamUsage",
                                    "AudioObjectSetPropertyData", property);
    UInt32 actual = static_cast<UInt32>(bytes);
    status = AudioObjectGetPropertyData(device, &property, 0, nullptr, &actual, usage);
    if (status != noErr)
        return certificationFailure(status, "certifyFormat.streamUsage",
                                    "AudioObjectGetPropertyData", property);
    if (actual != bytes || usage->mNumberStreams != count)
        return kAudioHardwareBadPropertySizeError;
    for (std::size_t n = 0; n < count; ++n)
        if (!usage->mStreamIsOn[n])
            return kAudioHardwareIllegalOperationError;
    return noErr;
}
OSStatus certify(void *, AudioObjectID aggregate, AudioDeviceIOProcID io,
                 const OutputDevice &physical, const TapDescription &tap,
                 FormatCertificate &output) {
    CFArrayRef devices = nullptr, taps = nullptr;
    CFStringRef master = nullptr;
    auto status = scalar(aggregate, kAudioAggregateDevicePropertyFullSubDeviceList, devices,
                         kAudioObjectPropertyScopeGlobal, "certifyFormat.aggregate");
    CFGuard a(devices);
    if (status != noErr)
        return status;
    status = scalar(aggregate, kAudioAggregateDevicePropertyTapList, taps,
                    kAudioObjectPropertyScopeGlobal, "certifyFormat.aggregate");
    CFGuard b(taps);
    if (status != noErr)
        return status;
    status = scalar(aggregate, kAudioAggregateDevicePropertyMainSubDevice, master,
                    kAudioObjectPropertyScopeGlobal, "certifyFormat.aggregate");
    CFGuard c(master);
    if (status != noErr)
        return status;
    std::string masterUID;
    status = copyString(master, masterUID);
    if (status != noErr)
        return status;
    output.intendedPhysicalOutput = oneString(devices, physical.uid) && masterUID == physical.uid;
    output.onlyOwnedTapInput = physical.inputChannels == 0 && oneString(taps, tap.uid);
    std::vector<AudioObjectID> subTaps;
    status = array(aggregate, kAudioAggregateDevicePropertySubTapList, subTaps,
                   kAudioObjectPropertyScopeGlobal, "certifyFormat.aggregate");
    if (status != noErr)
        return status;
    if (subTaps.size() != 1 || subTaps.front() == kAudioObjectUnknown)
        return kAudioHardwareUnsupportedOperationError;
    // Active-member identity, not an assumption that child properties are addressable.
    output.subTap = subTaps.front();
    CFDictionaryRef composition = nullptr;
    status = scalar(aggregate, kAudioAggregateDevicePropertyComposition, composition,
                    kAudioObjectPropertyScopeGlobal, "certifyFormat.aggregate");
    CFGuard compositionGuard(composition);
    if (status != noErr)
        return status;
    auto expectedUID = CFStringCreateWithCString(nullptr, tap.uid.c_str(), kCFStringEncodingUTF8);
    CFGuard uidGuard(expectedUID);
    if (!expectedUID)
        return kAudioHardwareUnspecifiedError;
    const auto clock =
        CFDictionaryGetValue(composition, CFSTR(kAudioAggregateDeviceClockDeviceKey));
    if (!clock || CFGetTypeID(clock) != CFStringGetTypeID() ||
        copyString(static_cast<CFStringRef>(clock), output.clockDeviceUID) != noErr)
        return kAudioHardwareUnsupportedOperationError;
    CFStringRef clockSource = nullptr;
    if (scalar(aggregate, kAudioAggregateDevicePropertyClockDevice, clockSource,
               kAudioObjectPropertyScopeGlobal, "certifyFormat.clockSource") != noErr)
        return kAudioHardwareUnsupportedOperationError;
    CFGuard sourceGuard(clockSource);
    if (!clockSource || CFGetTypeID(clockSource) != CFStringGetTypeID() ||
        copyString(clockSource, output.clockSourceUID) != noErr)
        return kAudioHardwareUnsupportedOperationError;
    AggregateTapPolicy policy{};
    if (!decodeAggregateTapPolicy(composition, expectedUID, policy))
        return kAudioHardwareUnsupportedOperationError;
    output.subTapDriftCompensation = policy.driftCompensation;
    output.subTapDriftQuality = policy.driftQuality;
    const auto inputOrigin = output.onlyOwnedTapInput && output.intendedPhysicalOutput
                                 ? StreamChannelOrigin::ownedTapInput
                                 : StreamChannelOrigin::device;
    status = layout(aggregate, kAudioObjectPropertyScopeInput, output.input, output.inputStreams,
                    nullptr, "certifyFormat.inputLayout", inputOrigin);
    if (status != noErr)
        return status;
    status = layout(aggregate, kAudioObjectPropertyScopeOutput, output.output, output.outputStreams,
                    nullptr, "certifyFormat.outputLayout");
    if (status != noErr)
        return status;
    // Certify actual IO capacity, not the device's configurable frame-size range.
    UInt32 currentFrames = 0;
    status = scalar(aggregate, kAudioDevicePropertyBufferFrameSize, currentFrames,
                    kAudioObjectPropertyScopeGlobal, "certifyFormat.aggregate");
    if (status != noErr)
        return status;
    if (currentFrames == 0 || currentFrames > 65536)
        return kAudioHardwareUnsupportedOperationError;
    output.maximumFrames = currentFrames;
    const AudioObjectPropertyAddress variableProperty{
        kAudioDevicePropertyUsesVariableBufferFrameSizes, kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    output.hasVariableBufferFrames = AudioObjectHasProperty(aggregate, &variableProperty);
    if (output.hasVariableBufferFrames) {
        UInt32 largest = 0;
        status = scalar(aggregate, kAudioDevicePropertyUsesVariableBufferFrameSizes, largest,
                        kAudioObjectPropertyScopeGlobal, "certifyFormat.aggregate");
        if (status != noErr)
            return status; // Only absence selects fixed buffers; read failure is an error.
        if (largest < currentFrames || largest > 65536)
            return kAudioHardwareUnsupportedOperationError;
        output.maximumFrames = largest;
    }
    status = streamUsage(aggregate, io, kAudioObjectPropertyScopeInput, output.inputStreams.size());
    if (status != noErr)
        return status;
    status =
        streamUsage(aggregate, io, kAudioObjectPropertyScopeOutput, output.outputStreams.size());
    output.ioStreamsEnabled = status == noErr;
    return status;
}
OSStatus aggregatePresent(void *, AudioObjectID object, bool &present) {
    AudioClassID type = 0;
    const auto status = scalar(object, kAudioObjectPropertyClass, type);
    if (status == kAudioHardwareBadObjectError) {
        present = false;
        return noErr;
    }
    if (status == noErr)
        present = true;
    return status;
}
} // namespace

const HalAPI &systemHalAPI() noexcept {
    static const HalAPI api{
        nullptr,
        hasUsage,
        processPID,
        inspectOutput,
        createTap,
        inspectTap,
        [](void *, AudioObjectID tap) { return AudioHardwareDestroyProcessTap(tap); },
        createAggregate,
        [](void *, AudioObjectID aggregate) {
            return AudioHardwareDestroyAggregateDevice(aggregate);
        },
        aggregatePresent,
        [](void *, AudioObjectID device, AudioDeviceIOProc callback, void *data,
           AudioDeviceIOProcID &io) {
            return AudioDeviceCreateIOProcID(device, callback, data, &io);
        },
        [](void *, AudioObjectID device, AudioDeviceIOProcID io) {
            return AudioDeviceDestroyIOProcID(device, io);
        },
        certify,
        [](void *, AudioObjectID device, AudioDeviceIOProcID io) {
            return AudioDeviceStart(device, io);
        },
        [](void *, AudioObjectID device, AudioDeviceIOProcID io) {
            return AudioDeviceStop(device, io);
        },
        [](void *, AudioObjectID object, AudioObjectPropertyAddress property,
           AudioObjectPropertyListenerProc callback, void *data) {
            return AudioObjectAddPropertyListener(object, &property, callback, data);
        },
        [](void *, AudioObjectID object, AudioObjectPropertyAddress property,
           AudioObjectPropertyListenerProc callback, void *data) {
            return AudioObjectRemovePropertyListener(object, &property, callback, data);
        }};
    return api;
}
} // namespace finetune::runtime
