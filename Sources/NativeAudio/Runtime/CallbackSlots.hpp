// SPDX-License-Identifier: MIT
#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <utility>

namespace finetune::runtime {

// Opaque C client-data bits, never an address to dereference. The 47-bit payload is
// tested on the supported 64-bit compiler/ABI; it is not a portable C++ guarantee.
struct CallbackCookie {
    static constexpr unsigned slotBits = 8;
    static constexpr std::size_t slotCount = std::size_t{1} << slotBits;
    static constexpr std::uint64_t maxGeneration = (std::uint64_t{1} << (47 - slotBits)) - 1;
    static constexpr std::uint64_t maxValue = (maxGeneration << slotBits) | (slotCount - 1);
    std::uint64_t value = 0;

    static constexpr CallbackCookie make(std::size_t slot, std::uint64_t generation) noexcept {
        return slot < slotCount && generation > 0 && generation <= maxGeneration
                   ? CallbackCookie{(generation << slotBits) | slot}
                   : CallbackCookie{};
    }
    constexpr bool valid() const noexcept { return value <= maxValue && (value >> slotBits) != 0; }
    constexpr std::size_t slot() const noexcept { return value & (slotCount - 1); }
    void *opaque() const noexcept {
        return reinterpret_cast<void *>(static_cast<std::uintptr_t>(value));
    }
    static CallbackCookie fromOpaque(void *data) noexcept {
        return {static_cast<std::uint64_t>(reinterpret_cast<std::uintptr_t>(data))};
    }
};

enum class ReclaimState { active, pendingReaders, stale, reclaimed };
struct ReclaimResult {
    ReclaimState state;
    void *context = nullptr;
};

// The production registry has process lifetime in trivial static storage. Only
// publish/reclaim require one serialized NRT writer; close/enter may be concurrent.
// Reuse changes the numeric generation, never retains one heap anchor per route.
class CallbackSlots {
    struct Slot {
        std::atomic<std::uint64_t> active{0};
        std::atomic<void *> context{nullptr};
        std::atomic<std::uint32_t> readers{0};
        std::uint64_t owner = 0; // Serialized NRT only.
        std::uint64_t nextGeneration = 1;
    };

  public:
    static constexpr std::size_t capacity = CallbackCookie::slotCount;
    static_assert(sizeof(void *) == sizeof(std::uint64_t));
    static_assert(std::atomic<std::uint64_t>::is_always_lock_free);
    static_assert(std::atomic<std::uint32_t>::is_always_lock_free);
    static_assert(std::atomic<void *>::is_always_lock_free);

    class Lease {
      public:
        Lease() noexcept = default;
        Lease(const Lease &) = delete;
        Lease &operator=(const Lease &) = delete;
        Lease(Lease &&other) noexcept
            : slot_(std::exchange(other.slot_, nullptr)),
              context_(std::exchange(other.context_, nullptr)) {}
        Lease &operator=(Lease &&other) noexcept {
            if (this != &other) {
                leave();
                slot_ = std::exchange(other.slot_, nullptr);
                context_ = std::exchange(other.context_, nullptr);
            }
            return *this;
        }
        ~Lease() { leave(); }
        explicit operator bool() const noexcept { return slot_ != nullptr; }
        void *context() const noexcept { return context_; }

      private:
        friend class CallbackSlots;
        Slot *slot_ = nullptr;
        void *context_ = nullptr;
        Lease(Slot *slot, void *context) noexcept : slot_(slot), context_(context) {}
        void leave() noexcept {
            if (slot_) {
                slot_->readers.fetch_sub(1, std::memory_order_seq_cst);
                slot_ = nullptr;
                context_ = nullptr;
            }
        }
    };

    // NRT. Null/exhausted capacity or generation returns an invalid cookie; the
    // runtime maps that explicit preparation failure to its typed error boundary.
    CallbackCookie publish(void *context) noexcept {
        if (!context) {
            return {};
        }
        for (std::size_t index = 0; index < capacity; ++index) {
            auto &slot = slots_[index];
            if (slot.owner != 0 || slot.nextGeneration > CallbackCookie::maxGeneration) {
                continue;
            }
            const auto cookie = CallbackCookie::make(index, slot.nextGeneration++);
            slot.owner = cookie.value;
            slot.context.store(context, std::memory_order_seq_cst);
            slot.active.store(cookie.value, std::memory_order_seq_cst);
            return cookie;
        }
        return {};
    }

    // RT. Increment before checking the current cookie, then load context only
    // on exact equality. A late old cookie cannot even read a new context pointer.
    Lease enter(CallbackCookie cookie) noexcept {
        if (!cookie.valid()) {
            return {};
        }
        auto &slot = slots_[cookie.slot()];
        slot.readers.fetch_add(1, std::memory_order_seq_cst);
        if (slot.active.load(std::memory_order_seq_cst) != cookie.value) {
            slot.readers.fetch_sub(1, std::memory_order_seq_cst);
            return {};
        }
        return Lease(&slot, slot.context.load(std::memory_order_seq_cst));
    }

    // RT-safe cancellation; stale owners must not close a reused slot. Does not
    // wait, destroy a context, call HAL, or claim an OS callback drain barrier.
    bool close(CallbackCookie cookie) noexcept {
        if (!cookie.valid()) {
            return false;
        }
        auto expected = cookie.value;
        return slots_[cookie.slot()].active.compare_exchange_strong(
            expected, 0, std::memory_order_seq_cst, std::memory_order_seq_cst);
    }

    // NRT. Closing admission and observing reader-zero precede context transfer.
    // A later rejected old entry can increment the stable counter but never load
    // the reclaimed pointer. Slot reuse need not wait for those rejected entries.
    ReclaimResult reclaim(CallbackCookie cookie) noexcept {
        if (!cookie.valid()) {
            return {ReclaimState::stale};
        }
        auto &slot = slots_[cookie.slot()];
        if (slot.owner != cookie.value) {
            return {ReclaimState::stale};
        }
        if (slot.active.load(std::memory_order_seq_cst) != 0) {
            return {ReclaimState::active};
        }
        if (slot.readers.load(std::memory_order_seq_cst) != 0) {
            return {ReclaimState::pendingReaders};
        }
        void *context = slot.context.exchange(nullptr, std::memory_order_seq_cst);
        slot.owner = 0;
        return {ReclaimState::reclaimed, context};
    }

  private:
    std::array<Slot, capacity> slots_{};
};
} // namespace finetune::runtime
