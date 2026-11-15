// SPDX-License-Identifier: MIT
// Shared test-only report writer for the six native/DSP executables.
#pragma once

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <span>

namespace finetune::test {

// One entry per named case, filled only after the case body has returned.
//
// invocations: runner executions of the named case. Every case the runner lists is
//              executed exactly once, so a valid result reports exactly 1. A missing,
//              duplicated or zero-invocation entry is not evidence of execution.
// inputs:      finite parameter/merge/scenario rows the case explicitly declares. Cases
//              without a separate row set report 1. This is a diagnostic input count,
//              never the number of assertions.
// assertions: always-on check evaluations. A passing case must report at least one.
// failures:    failed assertions. Status is derived from this value; a case body cannot
//              declare itself passed.
struct NativeTestResult {
    const char *id = nullptr;
    std::size_t invocations = 0;
    std::size_t inputs = 0;
    std::size_t assertions = 0;
    std::size_t failures = 0;
    const char *failure = nullptr;
    bool measured = false;
    double actual = 0;
    double expected = 0;
};

namespace detail {

inline void jsonString(std::FILE *file, const char *value) {
    std::fputc('"', file);
    for (const auto *p = reinterpret_cast<const unsigned char *>(value); *p; ++p) {
        if (*p == '"' || *p == '\\') {
            std::fputc('\\', file);
            std::fputc(*p, file);
        } else if (*p < 0x20) {
            std::fprintf(file, "\\u%04x", static_cast<unsigned>(*p));
        } else {
            std::fputc(*p, file);
        }
    }
    std::fputc('"', file);
}

inline void jsonMeasurement(std::FILE *file, bool known, double value) {
    if (!known) {
        std::fputs("null", file);
    } else if (std::isfinite(value)) {
        std::fprintf(file, "%.17g", value);
    } else {
        jsonString(file, std::isnan(value) ? "NaN" : value < 0 ? "-Infinity" : "Infinity");
    }
}

inline bool writeReport(const char *path, std::span<const NativeTestResult> results,
                        const char *extraFields) {
    auto *file = std::fopen(path, "w");
    if (!file) {
        std::perror("Unable to open native test report");
        return false;
    }
    bool ok = std::fprintf(file, "{\"schema_version\":2,\"complete\":true,\"cases\":[") >= 0;
    for (std::size_t i = 0; i < results.size(); ++i) {
        const auto &result = results[i];
        ok &= std::fprintf(file, "%s{\"id\":", i ? "," : "") >= 0;
        jsonString(file, result.id);
        ok &= std::fprintf(file,
                           ",\"status\":\"%s\",\"invocations\":%zu,\"inputs\":%zu,"
                           "\"assertions\":%zu,\"failures\":%zu",
                           result.failures ? "failed" : "passed", result.invocations, result.inputs,
                           result.assertions, result.failures) >= 0;
        if (result.failures) {
            ok &= std::fputs(",\"failure\":{\"message\":", file) != EOF;
            jsonString(file, result.failure ? result.failure : "assertion failed");
            ok &= std::fputs(",\"actual\":", file) != EOF;
            jsonMeasurement(file, result.measured, result.actual);
            ok &= std::fputs(",\"expected\":", file) != EOF;
            jsonMeasurement(file, result.measured, result.expected);
            ok &= std::fputc('}', file) != EOF;
        }
        ok &= std::fputc('}', file) != EOF;
    }
    ok &= std::fputc(']', file) != EOF;
    if (extraFields && extraFields[0] != '\0') {
        ok &= std::fputc(',', file) != EOF;
        ok &= std::fputs(extraFields, file) != EOF;
    }
    ok &= std::fputs("}\n", file) != EOF;
    const bool wrote = std::ferror(file) == 0;
    const bool closed = std::fclose(file) == 0;
    if (!ok || !wrote || !closed) {
        std::perror("Unable to write native test report");
        return false;
    }
    return true;
}

} // namespace detail

// Test-private artifact IO, called only by main outside callback/worker/probe intervals.
// Source paths and case IDs are fixed literals, never arbitrary user-provided JSON strings.
class NativeTestReport {
  public:
    NativeTestReport() = default;

    // Writes a schema-2 complete:false skeleton before any case body runs. A build failure
    // or early exit therefore cannot leave stale complete:true evidence in this file.
    bool begin(const char *path) {
        requested_ = true;
        path_ = path;
        if (!path || path[0] == '\0') {
            std::fputs("Native test report path is empty\n", stderr);
            ready_ = false;
            return false;
        }
        auto *file = std::fopen(path, "w");
        if (!file) {
            std::perror("Unable to open native test report");
            ready_ = false;
            return false;
        }
        const bool ok =
            std::fprintf(file, "{\"schema_version\":2,\"complete\":false,\"cases\":[]}\n") >= 0;
        const bool wrote = std::ferror(file) == 0;
        const bool closed = std::fclose(file) == 0;
        if (!ok || !wrote || !closed) {
            std::perror("Unable to write native test report skeleton");
            ready_ = false;
            return false;
        }
        ready_ = true;
        return true;
    }

    // Writes complete:true only for a non-empty, uniquely identified, self-consistent case
    // set. Failed cases are still written with status "failed", but the return value is
    // false so a caller that ignores the failure count cannot exit successfully. Empty,
    // missing or invalid case sets leave the complete:false skeleton untouched.
    bool finish(std::span<const NativeTestResult> results, const char *extraFields = nullptr) {
        if (requested_ && !ready_) {
            return false;
        }
        if (results.empty()) {
            std::fputs("Native test report has no named cases\n", stderr);
            return false;
        }
        bool allPassed = true;
        for (std::size_t i = 0; i < results.size(); ++i) {
            const auto &result = results[i];
            if (!result.id || result.id[0] == '\0') {
                std::fputs("Native test report has a missing case id\n", stderr);
                return false;
            }
            if (result.invocations != 1) {
                std::fprintf(stderr, "Native test case %s was not executed exactly once\n",
                             result.id);
                return false;
            }
            if (result.inputs == 0) {
                std::fprintf(stderr, "Native test case %s executed no declared input rows\n",
                             result.id);
                return false;
            }
            if (result.assertions == 0) {
                std::fprintf(stderr, "Native test case %s made no assertions\n", result.id);
                return false;
            }
            if (result.failures > result.assertions) {
                std::fprintf(stderr, "Native test case %s has more failures than assertions\n",
                             result.id);
                return false;
            }
            for (std::size_t j = 0; j < i; ++j) {
                if (std::strcmp(results[j].id, result.id) == 0) {
                    std::fprintf(stderr, "Native test case %s is duplicated\n", result.id);
                    return false;
                }
            }
            allPassed &= result.failures == 0;
        }
        if (requested_ && !detail::writeReport(path_, results, extraFields)) {
            return false;
        }
        return allPassed;
    }

  private:
    const char *path_ = nullptr;
    bool requested_ = false;
    bool ready_ = false;
};

} // namespace finetune::test
