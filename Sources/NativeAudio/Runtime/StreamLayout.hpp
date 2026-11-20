#pragma once
#include "HalAPI.hpp"
#include <limits>
#include <span>

namespace finetune::runtime {
struct StreamFormatObservation {
    AudioStreamBasicDescription format;
    UInt32 firstChannel;
};

enum class StreamChannelOrigin { device, ownedTapInput };

// NRT decoding of observed stream formats against the actual IO buffer configuration.
// Device channel numbers are not buffer offsets. Only a sole-owned tap input may start above 1;
// physical and aggregate outputs must still certify the actual device's channels 1 and 2.
inline StereoLayout
decodeStereoLayout(std::span<const UInt32> channels,
                   std::span<const StreamFormatObservation> streams,
                   StreamChannelOrigin origin = StreamChannelOrigin::device) noexcept {
    if (!((channels.size() == 1 && channels[0] == 2) ||
          (channels.size() == 2 && channels[0] == 1 && channels[1] == 1)) ||
        streams.empty() || streams.size() > 2)
        return {};
    const std::uint64_t firstChannel =
        origin == StreamChannelOrigin::ownedTapInput ? streams.front().firstChannel : 1;
    if (firstChannel == 0)
        return {};
    auto nextChannel = firstChannel;
    std::array<UInt32, 2> formatBuffers{};
    std::size_t bufferCount = 0;
    const auto sampleRate = streams.front().format.mSampleRate;
    for (const auto &stream : streams) {
        const auto &format = stream.format;
        if (!nativeFloat32Format(format) || stream.firstChannel != nextChannel ||
            format.mSampleRate != sampleRate)
            return {};
        nextChannel += format.mChannelsPerFrame;
        if (nextChannel - 1 > std::numeric_limits<UInt32>::max())
            return {};
        const auto planar = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
        const auto buffers = planar ? format.mChannelsPerFrame : 1;
        for (UInt32 n = 0; n < buffers; ++n) {
            if (bufferCount == formatBuffers.size())
                return {};
            formatBuffers[bufferCount++] = planar ? 1 : format.mChannelsPerFrame;
        }
    }
    if (nextChannel - firstChannel != 2 || bufferCount != channels.size())
        return {};
    for (std::size_t n = 0; n < channels.size(); ++n)
        if (formatBuffers[n] != channels[n])
            return {};
    return {sampleRate, static_cast<UInt32>(bufferCount), formatBuffers, true};
}
} // namespace finetune::runtime
