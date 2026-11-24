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

// Enable sub-tap drift compensation on all transports, including Bluetooth/BLE.
// AirPods A2DP adaptive latency temporarily warps the BT HAL delivery clock by +/-10%
// (multiplier 0.9 / 1.1) when shifting between 60ms and 100ms modes; with drift compensation
// disabled, the uncompensated tap ring buffer shifts into collision and corrupts tap input
// until latency reverts or the route is rebuilt.
inline UInt32 expectedDriftCompensation(const OutputDevice &) noexcept { return 1; }
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
    std::string clockSourceUID;
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
