// SPDX-License-Identifier: MIT
// First public-boundary Red: absence of explicit capture intent never reaches HAL.
#include "NativeAudioRuntime.h"
#include "NativeTestReport.hpp"
#include <cstdio>
#include <cstdlib>

int main(int argc, char **argv) {
    finetune::test::NativeTestReport report(
        argc, argv, "Tests/NativeRuntimeTests/NativeRuntimeBoundaryTests.cpp");
    if (!report.ready()) {
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
    const finetune::test::NativeTestResult results[]{{"noExplicitCaptureHasNoAcquisition", passed}};
    const bool reported = report.finish(results);
    return passed && reported ? EXIT_SUCCESS : EXIT_FAILURE;
}
