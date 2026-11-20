#include "HALContractHarness.hpp"

#include <cstdlib>
#include <vector>

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

// Test executable supplies the external OS provider. SystemHal.mm is never linked.
namespace finetune::runtime {
const HalAPI &systemHalAPI() noexcept {
    static const HalAPI api = native_hal_fixture::hal.api();
    return api;
}
} // namespace finetune::runtime

int main(int argc, char **argv) {
    const char *reportPath = nullptr;
    bool inject = false;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--inject-check-failure") == 0) {
            inject = true;
        } else if (std::strcmp(argv[i], "--report") == 0 && i + 1 < argc &&
                   argv[i + 1][0] != '\0') {
            reportPath = argv[++i];
        } else {
            std::fputs(
                "Usage: NativeHALContractTests [--report path.json] [--inject-check-failure]\n",
                stderr);
            return 2;
        }
    }

    finetune::test::NativeTestReport report;
    if (reportPath && !report.begin(reportPath)) {
        return 2;
    }

    using namespace native_hal_contract;
    std::vector<CaseUnit> allCases;
    for (const auto group : {timingDiagnosticCases(), acquisitionAndFormatCases(),
                             cleanupAndLifecycleCases(), invalidationAndUpdateCases()}) {
        allCases.insert(allCases.end(), group.begin(), group.end());
    }

    std::vector<finetune::test::NativeTestResult> reported;
    reported.reserve(allCases.size());
    for (std::size_t i = 0; i < allCases.size(); ++i) {
        const auto &unit = allCases[i];
        currentID = unit.id;
        firstFailure = nullptr;
        const auto beforeFailures = failures;
        const auto beforeAssertions = assertions;
        inputs = 1;
        if (inject && i == 0) {
            CHECK(false);
        }
        const auto beforeCaseAssertions = assertions;
        unit.run();
        CHECK(assertions > beforeCaseAssertions);
        CHECK(inputs > 0);
        CHECK(hal.resources() == 0);
        CHECK(callback_observation::allocations == 0 && callback_observation::deletions == 0);
        reported.push_back({unit.id, 1, inputs, assertions - beforeAssertions,
                            static_cast<std::size_t>(failures - beforeFailures), firstFailure});
        std::printf("%s: %s (%zu inputs/%zu always-on assertions)\n", unit.id,
                    reported.back().failures ? "FAIL" : "PASS", reported.back().inputs,
                    reported.back().assertions);
    }

    char extra[256];
    std::snprintf(extra, sizeof extra,
                  "\"real_system_hal_linked\":false,\"callback_allocations\":%zu,"
                  "\"callback_deletions\":%zu,\"owned_resources_at_end\":%zu",
                  callback_observation::allocations.load(), callback_observation::deletions.load(),
                  hal.resources());
    const bool reportedAll = report.finish(reported, extra);
    return failures == 0 && reportedAll ? EXIT_SUCCESS : EXIT_FAILURE;
}
