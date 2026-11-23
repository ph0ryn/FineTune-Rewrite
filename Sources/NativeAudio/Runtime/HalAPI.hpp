#pragma once

#include "NativeAudioRuntime.h"
#include <CoreAudio/CoreAudio.h>
#include <array>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

namespace finetune::runtime {

inline bool nativeFloat32Format(const AudioStreamBasicDescription &format) noexcept {
    const auto planar = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const UInt32 allowed =
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    return format.mFormatID == kAudioFormatLinearPCM && std::isfinite(format.mSampleRate) &&
           format.mSampleRate >= 8000 && format.mSampleRate <= 384000 &&
           (format.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)) ==
               (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked) &&
           (format.mFormatFlags & ~allowed) == 0 && format.mBitsPerChannel == 32 &&
           format.mChannelsPerFrame >= 1 && format.mChannelsPerFrame <= 2 &&
           format.mFramesPerPacket == 1 &&
           format.mBytesPerFrame == sizeof(float) * (planar ? 1 : format.mChannelsPerFrame) &&
           format.mBytesPerPacket == format.mBytesPerFrame;
}

// NRT metadata only. Callbacks use the certified fixed layout, never this API table.
struct StereoLayout {
    double sampleRate = 0;
    std::uint32_t bufferCount = 0;
    std::array<std::uint32_t, 2> channels{};
    bool nativePackedFloat32 = false;
};
inline bool bluetoothTransport(UInt32 transport) noexcept {
    return transport == kAudioDeviceTransportTypeBluetooth ||
           transport == kAudioDeviceTransportTypeBluetoothLE;
}

// Bluetooth, virtual and unresolvable transports cannot be assumed to have a crystal clock domain
// independent of the process tap. Enabling drift there makes the HAL insert/delete samples.
inline bool sharesClockDomain(UInt32 transport) noexcept {
    return bluetoothTransport(transport) || transport == kAudioDeviceTransportTypeVirtual ||
           transport == kAudioDeviceTransportTypeUnknown;
}

struct OutputDevice {
    AudioObjectID id = kAudioObjectUnknown;
    std::string uid;
    std::uint32_t inputChannels = 0;
    std::uint32_t outputChannels = 0;
    double nominalSampleRate = 0;
    UInt32 transportType = 0;
    StereoLayout output;
    bool stereoOrderKnown = false;
    bool aggregate = false;
    std::vector<AudioObjectID> outputStreams;
};

// Fail closed: only a device with a known independent clock domain gets drift compensation.
// An unresolvable transport must not silently opt into sample insertion/deletion.
inline UInt32 expectedDriftCompensation(const OutputDevice &output) noexcept {
    return sharesClockDomain(output.transportType) ? 0 : 1;
}
struct TapDescription {
    AudioObjectID id = kAudioObjectUnknown;
    std::string uid;
    AudioStreamBasicDescription format{};
};
struct FormatCertificate {
    StereoLayout input;
    StereoLayout output;
    std::uint32_t maximumFrames = 0;
    AudioObjectID subTap = kAudioObjectUnknown;
    std::string clockDeviceUID;
    UInt32 subTapDriftCompensation = 0;
    UInt32 subTapDriftQuality = 0;
    bool hasVariableBufferFrames = false;
    bool onlyOwnedTapInput = false;
    bool intendedPhysicalOutput = false;
    bool ioStreamsEnabled = false;
    std::vector<AudioObjectID> inputStreams;
    std::vector<AudioObjectID> outputStreams;
};

struct HalAPI {
    void *context = nullptr;
    bool (*hasCaptureUsageDescription)(void *) = nullptr;
    OSStatus (*processPID)(void *, AudioObjectID, std::int32_t &) = nullptr;
    FTNativeError (*inspectOutput)(void *, const char *, OutputDevice &) = nullptr;
    OSStatus (*createTap)(void *, const AudioObjectID *, std::uint32_t, AudioObjectID &) = nullptr;
    OSStatus (*inspectTap)(void *, AudioObjectID, TapDescription &) = nullptr;
    OSStatus (*destroyTap)(void *, AudioObjectID) = nullptr;
    OSStatus (*createAggregate)(void *, const OutputDevice &, const char *,
                                AudioObjectID &) = nullptr;
    OSStatus (*destroyAggregate)(void *, AudioObjectID) = nullptr;
    // noErr/present=false only after an actual bad-object observation, not a guessed delay.
    OSStatus (*aggregatePresent)(void *, AudioObjectID, bool &) = nullptr;
    OSStatus (*createIOProc)(void *, AudioObjectID, AudioDeviceIOProc, void *,
                             AudioDeviceIOProcID &) = nullptr;
    OSStatus (*destroyIOProc)(void *, AudioObjectID, AudioDeviceIOProcID) = nullptr;
    OSStatus (*certify)(void *, AudioObjectID, AudioDeviceIOProcID, const OutputDevice &,
                        const TapDescription &, FormatCertificate &) = nullptr;
    // Read-only re-check of the aggregate's immutable clock and sub-tap policy. Core Audio can
    // change these without emitting a Composition notification, so certification alone is not
    // proof that a live route still has the binding it was prepared with.
    bool (*policyStillValid)(void *, AudioObjectID, const char *, const char *, UInt32,
                             UInt32) = nullptr;
    OSStatus (*start)(void *, AudioObjectID, AudioDeviceIOProcID) = nullptr;
    OSStatus (*stop)(void *, AudioObjectID, AudioDeviceIOProcID) = nullptr;
    OSStatus (*addListener)(void *, AudioObjectID, AudioObjectPropertyAddress,
                            AudioObjectPropertyListenerProc, void *) = nullptr;
    OSStatus (*removeListener)(void *, AudioObjectID, AudioObjectPropertyAddress,
                               AudioObjectPropertyListenerProc, void *) = nullptr;
};

const HalAPI &systemHalAPI() noexcept;
// Production prepare delegates here; only the private C++ contract suite supplies a fake.
FTNativeResult prepareWithHal(const FTNativeRouteRequest *, FTNativeRoute **, FTNativeError *,
                              const HalAPI &);

inline FTNativeError failure(FTNativeFailureKind kind, FTNativeOperation operation,
                             std::int32_t code = 0) noexcept {
    return {kind, operation, code};
}
} // namespace finetune::runtime
