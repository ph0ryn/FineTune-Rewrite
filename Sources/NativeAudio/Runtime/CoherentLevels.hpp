// SPDX-License-Identifier: MIT
#pragma once

#include "NativeAudioRuntime.h"
#include <atomic>
#include <bit>
#include <cstdint>

namespace finetune::runtime {

// One serialized non-RT producer. Payload fields are atomic too: unlike an ordinary
// non-atomic seqlock this has no C++ data race. RT makes ONE attempt and keeps its
// previous coherent tuple on interference; it never spins/waits for the producer.
class CoherentLevels {
  public:
    explicit CoherentLevels(FTNativeLevels initial) noexcept { publish(initial); }
    static_assert(std::atomic<std::uint64_t>::is_always_lock_free);
    static_assert(std::atomic<std::uint32_t>::is_always_lock_free);

    bool publish(FTNativeLevels value) noexcept {
        if (value.revision < producerRevision_) {
            return false;
        }
        sequence_.fetch_add(1, std::memory_order_seq_cst);
        gainMute_.store(std::uint64_t{std::bit_cast<std::uint32_t>(value.target_gain)} |
                            (std::uint64_t{value.muted ? 1U : 0U} << 32),
                        std::memory_order_seq_cst);
        volume_.store(std::bit_cast<std::uint32_t>(value.loudness_volume),
                      std::memory_order_seq_cst);
        revision_.store(value.revision, std::memory_order_seq_cst);
        sequence_.fetch_add(1, std::memory_order_seq_cst);
        producerRevision_ = value.revision;
        return true;
    }

    bool tryRead(FTNativeLevels &output) const noexcept {
        const auto begin = sequence_.load(std::memory_order_seq_cst);
        if ((begin & 1U) != 0) {
            return false;
        }
        const auto gainMute = gainMute_.load(std::memory_order_seq_cst);
        const auto volume = volume_.load(std::memory_order_seq_cst);
        const auto revision = revision_.load(std::memory_order_seq_cst);
        if (sequence_.load(std::memory_order_seq_cst) != begin) {
            return false;
        }
        output = {revision, std::bit_cast<float>(static_cast<std::uint32_t>(gainMute)),
                  ((gainMute >> 32) & 1U) != 0, std::bit_cast<float>(volume)};
        return true;
    }

  private:
    std::atomic<std::uint64_t> sequence_{0};
    std::atomic<std::uint64_t> gainMute_{0};
    std::atomic<std::uint32_t> volume_{0};
    std::atomic<std::uint64_t> revision_{0};
    std::uint64_t producerRevision_ = 0; // Never touched by a callback.
};
} // namespace finetune::runtime
