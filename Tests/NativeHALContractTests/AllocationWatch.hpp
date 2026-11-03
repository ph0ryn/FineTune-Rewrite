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
void *operator new(std::size_t size) {
    callback_observation::allocation();
    if (void *p = std::malloc(size ? size : 1))
        return p;
    std::abort();
}
void *operator new[](std::size_t size) { return ::operator new(size); }
void operator delete(void *p) noexcept {
    callback_observation::deletion(p);
    std::free(p);
}
void operator delete[](void *p) noexcept { ::operator delete(p); }
void operator delete(void *p, std::size_t) noexcept { ::operator delete(p); }
void operator delete[](void *p, std::size_t) noexcept { ::operator delete(p); }
void *operator new(std::size_t size, std::align_val_t alignment) {
    callback_observation::allocation();
    void *p = nullptr;
    if (posix_memalign(&p, static_cast<std::size_t>(alignment), size ? size : 1) != 0)
        std::abort();
    return p;
}
void *operator new[](std::size_t size, std::align_val_t a) { return ::operator new(size, a); }
void operator delete(void *p, std::align_val_t) noexcept { ::operator delete(p); }
void operator delete[](void *p, std::align_val_t) noexcept { ::operator delete(p); }
void operator delete(void *p, std::size_t, std::align_val_t) noexcept { ::operator delete(p); }
void operator delete[](void *p, std::size_t, std::align_val_t) noexcept { ::operator delete(p); }
