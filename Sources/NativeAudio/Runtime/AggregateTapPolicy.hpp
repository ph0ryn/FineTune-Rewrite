// SPDX-License-Identifier: MIT
#pragma once
#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>
#include <cmath>
#include <limits>

namespace finetune::runtime {
struct AggregateTapPolicy {
    UInt32 driftCompensation;
    UInt32 driftQuality;
};

// Decode an actual composition read-back; never infer policy from a creation request.
inline bool decodeAggregateTapPolicy(CFTypeRef composition, CFStringRef expectedUID,
                                     AggregateTapPolicy &output) noexcept {
    if (!composition || CFGetTypeID(composition) != CFDictionaryGetTypeID() || !expectedUID)
        return false;
    const auto dictionary = static_cast<CFDictionaryRef>(composition);
    const auto taps = CFDictionaryGetValue(dictionary, CFSTR(kAudioAggregateDeviceTapListKey));
    if (!taps || CFGetTypeID(taps) != CFArrayGetTypeID())
        return false;
    const auto members = static_cast<CFArrayRef>(taps);
    if (CFArrayGetCount(members) != 1)
        return false;
    const auto member = CFArrayGetValueAtIndex(members, 0);
    if (!member || CFGetTypeID(member) != CFDictionaryGetTypeID())
        return false;
    const auto tap = static_cast<CFDictionaryRef>(member);
    const auto uid = CFDictionaryGetValue(tap, CFSTR(kAudioSubTapUIDKey));
    if (!uid || CFGetTypeID(uid) != CFStringGetTypeID() || !CFEqual(uid, expectedUID))
        return false;
    const auto number = [&](CFStringRef key, UInt32 maximum, UInt32 &value) {
        const auto object = CFDictionaryGetValue(tap, key);
        if (!object || CFGetTypeID(object) != CFNumberGetTypeID())
            return false;
        double observed = 0;
        if (!CFNumberGetValue(static_cast<CFNumberRef>(object), kCFNumberFloat64Type, &observed) ||
            !std::isfinite(observed) || observed < 0 || observed > maximum ||
            std::floor(observed) != observed)
            return false;
        value = static_cast<UInt32>(observed);
        return true;
    };
    AggregateTapPolicy observed{};
    if (!number(CFSTR(kAudioSubTapDriftCompensationKey), std::numeric_limits<UInt32>::max(),
                observed.driftCompensation) ||
        !number(CFSTR(kAudioSubTapDriftCompensationQualityKey), 128, observed.driftQuality))
        return false;
    output = observed;
    return true;
}
} // namespace finetune::runtime
