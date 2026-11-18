// SPDX-License-Identifier: MIT
#pragma once
#include <atomic>
#include <cstdlib>
#include <new>

namespace callback_observation {
inline std::atomic<bool> active{false};
inline std::atomic<std::size_t> allocations{0}, deletions{0};
static_assert(std::atomic<std::size_t>::is_always_lock_free);
inline void allocation() noexcept {
    if (active.load(std::memory_order_relaxed))
        ++allocations;
}
inline void deletion(void *p) noexcept {
    if (p && active.load(std::memory_order_relaxed))
        ++deletions;
}
} // namespace callback_observation
