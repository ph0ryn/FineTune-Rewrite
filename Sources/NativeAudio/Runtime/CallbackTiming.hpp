// SPDX-License-Identifier: MIT
#pragma once

#include "NativeAudioRuntime.h"
#include <CoreAudio/CoreAudio.h>
#include <algorithm>
#include <atomic>
#include <bit>
#include <cmath>
#include <cstdint>
#include <mach/mach_time.h>

namespace finetune::runtime {
// One exclusive IOProc writer; NRT reads independent, approximate cumulative atomics.
// Enabled only before ready is release-published. No reset/control decisions while running.
class CallbackTiming {
    static_assert(std::atomic<std::uint64_t>::is_always_lock_free);
    struct SampleTrack {
        bool havePrevious = false;
        double previous = 0;
        std::uint32_t previousFrames = 0;
        std::atomic<std::uint64_t> missing{0}, jumps{0}, maximumError{0}, latest{0};
        bool observe(const AudioTimeStamp *time, std::uint32_t frames) noexcept {
            if (!time || !(time->mFlags & kAudioTimeStampSampleTimeValid) ||
                !std::isfinite(time->mSampleTime)) {
                missing.fetch_add(1, std::memory_order_relaxed);
                havePrevious = false;
                return false;
            }
            if (havePrevious) {
                const auto error = std::fabs((time->mSampleTime - previous) - previousFrames);
                if (error > 1)
                    jumps.fetch_add(1, std::memory_order_relaxed);
                maximum(maximumError, error);
            }
            previous = time->mSampleTime;
            previousFrames = frames;
            havePrevious = true;
            latest.store(std::bit_cast<std::uint64_t>(previous), std::memory_order_relaxed);
            return true;
        }
    } input, output;
    bool enabled = false, haveEntry = false, haveHost = false, haveOffset = false;
    double sampleRate = 0, nanosPerTick = 0, ticksPerFrame = 0, previousOffset = 0;
    std::uint64_t previousEntry = 0, previousHost = 0;
    std::uint32_t previousHostFrames = 0;
    std::atomic<std::uint64_t> callbacks{0}, idle{0}, missingHost{0}, nonincreasingHost{0},
        largeHostGaps{0}, overBudget{0}, maxEntryGap{0}, maxDuration{0}, maxHostGap{0},
        latestOffset{0}, maxOffsetChange{0}, discontinuities{0};
    std::atomic<std::uint32_t> validMask{0}, maxSampleDelta{0};

    static void maximum(std::atomic<std::uint64_t> &destination, std::uint64_t value) noexcept {
        // Single exclusive callback writer: no CAS loop, lock or retry.
        if (value > destination.load(std::memory_order_relaxed))
            destination.store(value, std::memory_order_relaxed);
    }
    static void maximum(std::atomic<std::uint64_t> &destination, double value) noexcept {
        if (value > std::bit_cast<double>(destination.load(std::memory_order_relaxed)))
            destination.store(std::bit_cast<std::uint64_t>(value), std::memory_order_relaxed);
    }
    static double readDouble(const std::atomic<std::uint64_t> &value) noexcept {
        return std::bit_cast<double>(value.load(std::memory_order_relaxed));
    }
    void finish(std::uint64_t entry, std::uint32_t frames) noexcept {
        const auto duration = mach_absolute_time() - entry;
        maximum(maxDuration, duration);
        if (frames && duration > frames * ticksPerFrame)
            overBudget.fetch_add(1, std::memory_order_relaxed);
    }

  public:
    // NRT, before AudioDeviceStart/ready publication; repeated enable does not reset counters.
    bool enable(double rate) noexcept {
        if (enabled)
            return true;
        mach_timebase_info_data_t timebase{};
        if (mach_timebase_info(&timebase) != KERN_SUCCESS || !timebase.numer || !timebase.denom ||
            !std::isfinite(rate) || rate <= 0)
            return false;
        sampleRate = rate;
        nanosPerTick = static_cast<double>(timebase.numer) / timebase.denom;
        ticksPerFrame = 1e9 / (nanosPerTick * rate);
        enabled = true;
        return true;
    }
    struct Measurement {
        CallbackTiming *owner;
        std::uint64_t entry;
        std::uint32_t frames;
        Measurement(CallbackTiming *owner, std::uint64_t entry, std::uint32_t frames)
            : owner(owner), entry(entry), frames(frames) {}
        Measurement(const Measurement &) = delete;
        ~Measurement() {
            if (owner)
                owner->finish(entry, frames);
        }
    };
    Measurement observe(const AudioTimeStamp *now, const AudioTimeStamp *inputTime,
                        const AudioTimeStamp *outputTime, std::uint32_t inputFrames,
                        std::uint32_t outputFrames, bool isIdle) noexcept {
        if (!enabled)
            return {nullptr, 0, 0};
        const auto entry = mach_absolute_time();
        if (haveEntry)
            maximum(maxEntryGap, entry - previousEntry);
        haveEntry = true;
        previousEntry = entry;
        callbacks.fetch_add(1, std::memory_order_relaxed);
        if (isIdle)
            idle.fetch_add(1, std::memory_order_relaxed);
        std::uint32_t valid = 0;
        if (now && (now->mFlags & kAudioTimeStampHostTimeValid)) {
            valid |= 1;
            if (haveHost) {
                if (now->mHostTime <= previousHost)
                    nonincreasingHost.fetch_add(1, std::memory_order_relaxed);
                else {
                    const auto gap = now->mHostTime - previousHost;
                    maximum(maxHostGap, gap);
                    if (previousHostFrames && gap > 2 * previousHostFrames * ticksPerFrame)
                        largeHostGaps.fetch_add(1, std::memory_order_relaxed);
                }
            }
            previousHost = now->mHostTime;
            previousHostFrames = outputFrames;
            haveHost = true;
        } else {
            missingHost.fetch_add(1, std::memory_order_relaxed);
            haveHost = false;
        }
        const bool inputValid = input.observe(inputTime, inputFrames);
        const bool outputValid = output.observe(outputTime, outputFrames);
        if (inputValid)
            valid |= 2;
        if (outputValid)
            valid |= 4;
        if (inputValid && outputValid) {
            const auto offset = outputTime->mSampleTime - inputTime->mSampleTime;
            if (std::isfinite(offset)) {
                if (haveOffset)
                    maximum(maxOffsetChange, std::fabs(offset - previousOffset));
                previousOffset = offset;
                haveOffset = true;
                latestOffset.store(std::bit_cast<std::uint64_t>(offset), std::memory_order_relaxed);
            } else
                haveOffset = false;
        } else
            haveOffset = false;
        validMask.store(valid, std::memory_order_relaxed);
        return {this, entry, outputFrames};
    }
    // Rendered-output waveform check. Counts adjacent jumps that dwarf the smoothed local
    // mean step, which is what an inserted/deleted sample or a discontinuity sounds like.
    void observeOutput(const float *samples, std::uint32_t count) noexcept {
        if (!enabled || !samples || count < 2)
            return;
        // Output is always interleaved stereo. Compare each channel to its own previous
        // frame; comparing adjacent array slots would count the L/R boundary as a jump.
        float peakDelta = 0;
        std::uint64_t spikes = 0;
        constexpr float threshold = 0.2F;
        for (std::uint32_t n = 2; n < count; ++n) {
            const float delta = std::fabs(samples[n] - samples[n - 2]);
            if (delta > peakDelta)
                peakDelta = delta;
            if (delta > threshold)
                ++spikes;
        }
        const auto deltaBits = std::bit_cast<std::uint32_t>(peakDelta);
        if (deltaBits > maxSampleDelta.load(std::memory_order_relaxed))
            maxSampleDelta.store(deltaBits, std::memory_order_relaxed);
        discontinuities.fetch_add(spikes, std::memory_order_relaxed);
    }
    FTNativeTimingSnapshot snapshot() const noexcept {
        FTNativeTimingSnapshot value{};
        value.enabled = enabled;
        value.sample_rate = sampleRate;
        value.last_valid_mask = validMask.load(std::memory_order_relaxed);
        value.observed_callbacks = callbacks.load(std::memory_order_relaxed);
        value.idle_callbacks = idle.load(std::memory_order_relaxed);
        value.missing_now_host = missingHost.load(std::memory_order_relaxed);
        value.missing_input_sample = input.missing.load(std::memory_order_relaxed);
        value.missing_output_sample = output.missing.load(std::memory_order_relaxed);
        value.nonincreasing_now_host = nonincreasingHost.load(std::memory_order_relaxed);
        value.host_gaps_over_two_periods = largeHostGaps.load(std::memory_order_relaxed);
        value.input_sample_jumps = input.jumps.load(std::memory_order_relaxed);
        value.output_sample_jumps = output.jumps.load(std::memory_order_relaxed);
        value.callbacks_over_nominal_period = overBudget.load(std::memory_order_relaxed);
        value.max_callback_gap_ns = maxEntryGap.load(std::memory_order_relaxed) * nanosPerTick;
        value.max_callback_duration_ns = maxDuration.load(std::memory_order_relaxed) * nanosPerTick;
        value.max_now_host_gap_ns = maxHostGap.load(std::memory_order_relaxed) * nanosPerTick;
        value.max_input_step_error_frames = readDouble(input.maximumError);
        value.max_output_step_error_frames = readDouble(output.maximumError);
        value.last_input_sample_time = readDouble(input.latest);
        value.last_output_sample_time = readDouble(output.latest);
        value.last_io_offset_frames = readDouble(latestOffset);
        value.max_io_offset_change_frames = readDouble(maxOffsetChange);
        value.max_output_sample_delta =
            std::bit_cast<float>(maxSampleDelta.load(std::memory_order_relaxed));
        value.output_discontinuities = discontinuities.load(std::memory_order_relaxed);
        return value;
    }
};
} // namespace finetune::runtime
