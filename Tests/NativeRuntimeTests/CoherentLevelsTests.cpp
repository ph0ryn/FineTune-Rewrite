// SPDX-License-Identifier: MIT
#include "../../Sources/NativeAudio/Runtime/CoherentLevels.hpp"
#include "NativeTestReport.hpp"
#include <atomic>
#include <cstdio>
#include <thread>

using finetune::runtime::CoherentLevels;

int main(int argc, char **argv) {
    finetune::test::NativeTestReport report(
        argc, argv, "Tests/NativeRuntimeTests/CoherentLevelsTests.cpp");
    if (!report.ready()) {
        return 1;
    }
    int failures = 0;
    finetune::test::NativeTestResult results[3];
    std::size_t recorded = 0;
    auto expect = [&](bool condition, const char *id) {
        results[recorded++] = {id, condition};
        std::printf("%s NativeRuntime.Levels.%s\n", condition ? "PASS" : "FAIL", id);
        if (!condition) ++failures;
    };
    CoherentLevels levels({1, 0.25F, false, 0.5F});
    FTNativeLevels observed{};
    expect(levels.tryRead(observed) && observed.revision == 1 && observed.target_gain == 0.25F &&
               observed.loudness_volume == 0.5F && !observed.muted, "initialSavedTuple");
    expect(levels.publish({3, 0.75F, true, 0.125F}) && !levels.publish({2, 1, false, 1}) &&
               levels.tryRead(observed) && observed.revision == 3 && observed.target_gain == 0.75F &&
               observed.muted && observed.loudness_volume == 0.125F, "staleTupleCannotRollbackGainMute");

    CoherentLevels stressed({1, 0.125F, true, 0.25F});
    std::atomic<bool> done{false};
    std::thread producer([&] {
        for (uint64_t revision = 2; revision < 100000; ++revision) {
            stressed.publish({revision, float(revision % 4) * 0.125F,
                              (revision % 2) != 0, float(revision % 5) * 0.25F});
        }
        done.store(true, std::memory_order_release);
    });
    bool coherent = true;
    unsigned accepted = 0;
    do {
        FTNativeLevels next{};
        if (stressed.tryRead(next)) {
            coherent &= next.target_gain == float(next.revision % 4) * 0.125F &&
                        next.muted == ((next.revision % 2) != 0) &&
                        next.loudness_volume == float(next.revision % 5) * 0.25F;
            ++accepted;
        }
    } while (!done.load(std::memory_order_acquire));
    producer.join();
    expect(coherent && accepted > 0, "singleAttemptAtomicTupleUnderConcurrentPublication");
    const bool reported = report.finish(results);
    return failures == 0 && reported ? 0 : 1;
}
