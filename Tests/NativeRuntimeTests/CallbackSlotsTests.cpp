// SPDX-License-Identifier: MIT
// Synthetic callback admission/lifetime contracts. No HAL/TCC/device call is made.
#include "../../Sources/NativeAudio/Runtime/CallbackSlots.hpp"
#include "NativeTestReport.hpp"

#include <array>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <latch>
#include <new>
#include <thread>
#include <type_traits>
#include <utility>

using finetune::runtime::CallbackCookie;
using finetune::runtime::CallbackSlots;
using finetune::runtime::ReclaimState;

// The same scalar/pointer argument shape as the HAL IOProc, without invoking HAL.
extern "C" __attribute__((noinline)) void *cookieABIEcho(std::uint32_t, const void *, const void *,
                                                         const void *, void *, const void *,
                                                         void *data) noexcept {
    return data;
}

namespace {
int failures = 0;
std::size_t assertions = 0;
const char *activeCase = nullptr;
const char *firstFailure = nullptr;
std::atomic<bool> countAllocations{false};
std::atomic<unsigned> allocations{0};
void check(bool condition, const char *message) {
    ++assertions;
    if (!condition) {
        if (!firstFailure)
            firstFailure = message;
        ++failures;
        std::fprintf(stderr, "FAIL %s: %s\n", activeCase, message);
    }
}
struct Body {
    unsigned id = 0;
    std::atomic<unsigned> touches{0};
    Body() noexcept = default;
    explicit Body(unsigned value) noexcept : id(value) {}
    void touch() noexcept { touches.fetch_add(1, std::memory_order_relaxed); }
};
void callback(CallbackSlots &slots, CallbackCookie cookie) {
    auto lease = slots.enter(cookie);
    if (lease) {
        static_cast<Body *>(lease.context())->touch();
    }
}
void cookiePointerRoundTrip() {
    static_assert(sizeof(void *) == 8 && sizeof(std::uintptr_t) == 8);
    static_assert(std::is_trivially_destructible_v<CallbackSlots>);
    // A volatile indirect target prevents same-TU return-value inference from erasing
    // the actual ABI call even though the noinline callee simply returns argument seven.
    decltype(&cookieABIEcho) volatile echo = &cookieABIEcho;
    for (std::size_t slot : {std::size_t{0}, CallbackSlots::capacity - 1}) {
        for (std::uint64_t generation : {std::uint64_t{1}, CallbackCookie::maxGeneration}) {
            const auto cookie = CallbackCookie::make(slot, generation);
            check(cookie.valid() && cookie.slot() == slot, "valid edge cookie preserves slot");
            const auto returned =
                echo(0, nullptr, nullptr, nullptr, nullptr, nullptr, cookie.opaque());
            check(CallbackCookie::fromOpaque(returned).value == cookie.value,
                  "64-bit integer -> opaque C userdata ABI -> integer preserves all chosen bits");
        }
    }
    check(!CallbackCookie::make(CallbackSlots::capacity, 1).valid(), "invalid slot is rejected");
    check(!CallbackCookie::make(0, 0).valid(), "zero generation is never published");
    check(!CallbackCookie::make(0, CallbackCookie::maxGeneration + 1).valid(),
          "exhausted generation cannot wrap to an old cookie");
    check(!CallbackCookie::fromOpaque(nullptr).valid(), "null cookie is closed/invalid");
}
void firstCallbackAndClosedEntry() {
    CallbackSlots slots;
    Body body(11);
    const auto cookie = slots.publish(&body);
    check(cookie.valid(), "a route receives a cookie");
    callback(slots, cookie);
    check(body.touches == 1, "first admitted callback reads the prepared context");
    check(slots.reclaim(cookie).state == ReclaimState::active, "live context cannot be reclaimed");
    check(slots.close(cookie), "close admits no further callbacks");
    callback(slots, cookie);
    check(body.touches == 1, "entry after close never touches old context");
    const auto result = slots.reclaim(cookie);
    check(result.state == ReclaimState::reclaimed && result.context == &body,
          "closed quiescent context transfers to NRT exactly once");
    check(slots.reclaim(cookie).state == ReclaimState::stale,
          "duplicate reclaim is explicit stale");
}
void lateOldCookieAfterReuse() {
    CallbackSlots slots;
    Body oldBody(11), newBody(22);
    const auto old = slots.publish(&oldBody);
    check(slots.close(old), "close old generation");
    check(slots.reclaim(old).context == &oldBody, "reclaim old generation");
    const auto current = slots.publish(&newBody);
    check(current.slot() == old.slot() && current.value != old.value,
          "bounded slot reuse has a new generation, not a new retained anchor");
    callback(slots, old);
    check(newBody.touches == 0 && oldBody.touches == 0,
          "late old callback cannot borrow new route or freed old route");
    check(!slots.close(old), "stale cancel cannot close the newly reused slot");
    callback(slots, current);
    check(newBody.touches == 1, "current cookie remains usable after stale callback/cancel");
    check(slots.close(current), "close current");
    check(slots.reclaim(current).context == &newBody, "reclaim current");
}
void pausedReaderPreventsReclamation() {
    CallbackSlots slots;
    auto *body = new Body(33);
    const auto cookie = slots.publish(body);
    // Test-only scheduler pause after actual production enter()/context load.
    // Latches are not inside production callback/lease code.
    std::latch loaded(1), resume(1);
    std::thread reader([&] {
        auto lease = slots.enter(cookie);
        auto *borrowed = static_cast<Body *>(lease.context());
        loaded.count_down();
        resume.wait();
        if (borrowed) {
            borrowed->touch();
        }
    });
    loaded.wait();
    check(slots.close(cookie), "close while a callback holds a real lease");
    auto retirement = slots.reclaim(cookie);
    check(retirement.state == ReclaimState::pendingReaders,
          "no elapsed-time/Stop/Destroy assumption replaces the reader predicate");
    // A broken reclaimer really frees now, so ASan observes the paused-reader UAF mutant.
    if (retirement.state == ReclaimState::reclaimed) {
        delete static_cast<Body *>(retirement.context);
    }
    resume.count_down();
    reader.join();
    if (retirement.state != ReclaimState::reclaimed) {
        retirement = slots.reclaim(cookie);
        check(retirement.state == ReclaimState::reclaimed && retirement.context == body,
              "only after actual reader return can NRT reclaim");
        check(body->touches == 1, "reader finished its context access before destruction");
        delete static_cast<Body *>(retirement.context);
    }
}
void leaseMovesHaveOneReaderOwnership() {
    CallbackSlots slots;
    Body one(1), two(2);
    const auto a = slots.publish(&one), b = slots.publish(&two);
    auto leaseA = slots.enter(a), leaseB = slots.enter(b);
    auto moved = std::move(leaseA);
    check(!leaseA && moved, "move transfers a lease, not a second reader");
    leaseB = std::move(moved);
    check(!moved && leaseB.context() == &one,
          "move assignment releases previous destination lease");
    check(slots.close(b), "close B");
    check(slots.reclaim(b).context == &two, "B has no phantom reader after move assignment");
    check(slots.close(a), "close A");
    check(slots.reclaim(a).state == ReclaimState::pendingReaders, "moved A still owns one reader");
    leaseB = {};
    check(slots.reclaim(a).context == &one, "last moved lease leaves exactly once");
}
void boundedCapacityAndFreshReuse() {
    CallbackSlots slots;
    std::array<Body, CallbackSlots::capacity> bodies{};
    std::array<CallbackCookie, CallbackSlots::capacity> cookies{};
    Body extra(999);
    for (std::size_t i = 0; i < bodies.size(); ++i) {
        bodies[i].id = static_cast<unsigned>(i + 1);
        cookies[i] = slots.publish(&bodies[i]);
        check(cookies[i].valid(), "each bounded slot can be allocated once");
    }
    check(!slots.publish(&extra).valid(),
          "capacity exhaustion is explicit, not an unbounded anchor leak");
    check(slots.close(cookies[7]), "close a non-edge slot");
    check(slots.reclaim(cookies[7]).context == &bodies[7], "free one bounded slot");
    const auto reused = slots.publish(&extra);
    check(reused.slot() == cookies[7].slot() && reused.value != cookies[7].value,
          "only the freed slot is reused with a fresh cookie");
    callback(slots, cookies[7]);
    check(extra.touches == 0, "old cookie cannot touch replacement in middle slot");
    for (std::size_t i = 0; i < cookies.size(); ++i) {
        if (i != 7) {
            check(slots.close(cookies[i]), "close allocated slot");
            check(slots.reclaim(cookies[i]).context == &bodies[i], "reclaim allocated slot");
        }
    }
    check(slots.close(reused), "close reused slot");
    check(slots.reclaim(reused).context == &extra, "reclaim reused slot");
}
void callbackPathDoesNotAllocate() {
    CallbackSlots slots;
    Body body(42);
    const auto cookie = slots.publish(&body);
    allocations = 0;
    countAllocations = true;
    for (int i = 0; i < 10000; ++i) {
        callback(slots, cookie);
    }
    countAllocations = false;
    check(allocations == 0 && body.touches == 10000,
          "admission/lease leave never calls ordinary new");
    check(slots.close(cookie), "close allocation probe");
    check(slots.reclaim(cookie).context == &body, "reclaim allocation probe");
}
} // namespace

void *operator new(std::size_t bytes) {
    if (countAllocations) {
        allocations.fetch_add(1, std::memory_order_relaxed);
    }
    if (void *p = std::malloc(bytes == 0 ? 1 : bytes)) {
        return p;
    }
    std::abort();
}
void *operator new[](std::size_t bytes) { return ::operator new(bytes); }
void operator delete(void *pointer) noexcept { std::free(pointer); }
void operator delete[](void *pointer) noexcept { std::free(pointer); }

int main(int argc, char **argv) {
    const char *reportPath = nullptr;
    if (argc != 1) {
        if (argc != 3 || std::strcmp(argv[1], "--report") != 0 || argv[2][0] == '\0') {
            std::fputs("Usage: NativeSlotTests [--report path.json]\n", stderr);
            return EXIT_FAILURE;
        }
        reportPath = argv[2];
    }
    finetune::test::NativeTestReport report;
    if (reportPath && !report.begin(reportPath)) {
        return EXIT_FAILURE;
    }
    struct Unit {
        const char *id;
        void (*run)();
    };
    const Unit units[]{
        {"Tests/NativeRuntimeTests/CallbackSlotsTests.cpp::cookiePointerRoundTrip",
         cookiePointerRoundTrip},
        {"Tests/NativeRuntimeTests/CallbackSlotsTests.cpp::firstCallbackAndClosedEntry",
         firstCallbackAndClosedEntry},
        {"Tests/NativeRuntimeTests/CallbackSlotsTests.cpp::lateOldCookieAfterReuse",
         lateOldCookieAfterReuse},
        {"Tests/NativeRuntimeTests/CallbackSlotsTests.cpp::pausedReaderPreventsReclamation",
         pausedReaderPreventsReclamation},
        {"Tests/NativeRuntimeTests/CallbackSlotsTests.cpp::leaseMovesHaveOneReaderOwnership",
         leaseMovesHaveOneReaderOwnership},
        {"Tests/NativeRuntimeTests/CallbackSlotsTests.cpp::boundedCapacityAndFreshReuse",
         boundedCapacityAndFreshReuse},
        {"Tests/NativeRuntimeTests/CallbackSlotsTests.cpp::callbackPathDoesNotAllocate",
         callbackPathDoesNotAllocate},
    };
    finetune::test::NativeTestResult results[std::size(units)];
    for (std::size_t i = 0; i < std::size(units); ++i) {
        const auto &unit = units[i];
        activeCase = unit.id;
        firstFailure = nullptr;
        const int beforeFailures = failures;
        const auto beforeAssertions = assertions;
        unit.run();
        if (assertions == beforeAssertions) {
            ++assertions;
            ++failures;
            firstFailure = "case made no assertions";
        }
        results[i] = {unit.id,
                      1,
                      1,
                      assertions - beforeAssertions,
                      static_cast<std::size_t>(failures - beforeFailures),
                      firstFailure};
        std::printf("%s %s\n", failures == beforeFailures ? "PASS" : "FAIL", unit.id);
    }
    std::printf("Native callback slot contracts: %d failures, %zu named cases\n", failures,
                std::size(units));
    const bool reported = report.finish(results);
    return failures == 0 && reported ? EXIT_SUCCESS : EXIT_FAILURE;
}
