// SPDX-License-Identifier: MIT
// First public-boundary Red: absence of explicit capture intent never reaches HAL.
#include "NativeAudioRuntime.h"
#include "NativeTestReport.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>

int main(int argc, char **argv) {
    const char *reportPath = nullptr;
    if (argc != 1) {
        if (argc != 3 || std::strcmp(argv[1], "--report") != 0 || argv[2][0] == '\0') {
            std::fputs("Usage: NativeRuntimeTests [--report path.json]\n", stderr);
            return EXIT_FAILURE;
        }
        reportPath = argv[2];
    }
    finetune::test::NativeTestReport report;
    if (reportPath && !report.begin(reportPath)) {
        return EXIT_FAILURE;
    }
    FTNativeRouteRequest request{};
    const uint32_t source = 71;
    request.output_uid = "fixture-output";
    request.process_objects = &source;
    request.process_count = 1;
    request.route_generation = 1;
    request.process_revision = 1;
    request.capture_session = 0;
    request.initial_state.revision = 1;
    request.initial_state.target_gain = 0.25F;
    FTNativeRoute *route = nullptr;
    FTNativeError error{};
    const auto status = ft_native_route_prepare(&request, &route, &error);
    const bool passed = status == FT_NATIVE_FAILED && route == nullptr &&
                        error.kind == FT_NATIVE_CAPTURE_NOT_REQUESTED;
    if (passed) {
        std::puts("PASS NativeRuntime.noExplicitCaptureHasNoAcquisition");
    } else {
        std::fputs("FAIL NativeRuntime.noExplicitCaptureHasNoAcquisition\n", stderr);
    }
    const finetune::test::NativeTestResult results[]{
        {"Tests/NativeRuntimeTests/"
         "NativeRuntimeBoundaryTests.cpp::noExplicitCaptureHasNoAcquisition",
         1, 1, 1, passed ? 0U : 1U, passed ? nullptr : "explicit capture intent was not required"}};
    const bool reported = report.finish(results);
    return passed && reported ? EXIT_SUCCESS : EXIT_FAILURE;
}
