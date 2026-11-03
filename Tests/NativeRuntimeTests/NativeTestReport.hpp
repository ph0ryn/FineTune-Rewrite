// SPDX-License-Identifier: MIT
#pragma once

#include <cstdio>
#include <cstring>
#include <span>

namespace finetune::test {

struct NativeTestResult {
    const char *id = nullptr;
    bool passed = false;
};

// Test-private artifact IO, called only by main outside callback/worker/probe intervals.
// Source paths and case IDs are fixed literals, never arbitrary user-provided JSON strings.
class NativeTestReport {
  public:
    NativeTestReport(int argc, char **argv, const char *source) : source_(source) {
        if (argc == 1) {
            return;
        }
        if (argc != 3 || std::strcmp(argv[1], "--report") != 0 || argv[2][0] == '\0') {
            std::fprintf(stderr, "Usage: %s [--report path.json]\n", argv[0]);
            ready_ = false;
            return;
        }
        path_ = argv[2];
        ready_ = write({}, false);
    }

    bool ready() const noexcept { return ready_; }

    bool finish(std::span<const NativeTestResult> results) const {
        if (!ready_) {
            return false;
        }
        for (const auto &result : results) {
            if (!result.id || result.id[0] == '\0') {
                std::fputs("Native test report has an unfinished case\n", stderr);
                return false;
            }
        }
        return write(results, true);
    }

  private:
    const char *source_;
    const char *path_ = nullptr;
    bool ready_ = true;

    bool write(std::span<const NativeTestResult> results, bool complete) const {
        if (!path_) {
            return true;
        }
        auto *file = std::fopen(path_, "w");
        if (!file) {
            std::perror("Unable to open native test report");
            return false;
        }
        bool ok = std::fprintf(file, "{\"schema_version\":1,\"complete\":%s,\"cases\":[",
                               complete ? "true" : "false") >= 0;
        for (std::size_t i = 0; i < results.size(); ++i) {
            const auto &result = results[i];
            ok &= std::fprintf(file, "%s{\"id\":\"%s::%s\",\"status\":\"%s\",\"invocations\":1}",
                               i ? "," : "", source_, result.id,
                               result.passed ? "passed" : "failed") >= 0;
        }
        ok &= std::fputs("]}\n", file) != EOF;
        const bool wrote = std::ferror(file) == 0;
        const bool closed = std::fclose(file) == 0;
        if (!ok || !wrote || !closed) {
            std::perror("Unable to write native test report");
            return false;
        }
        return true;
    }
};

} // namespace finetune::test
