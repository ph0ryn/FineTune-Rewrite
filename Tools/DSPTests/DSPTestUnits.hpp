// SPDX-License-Identifier: MIT
#pragma once

#include <span>

namespace finetune::test {
struct NamedUnit {
    const char *id;
    void (*run)();
};

// Test-only measurement sink, implemented by the independent runner.
void check(bool condition, const char *property, double actual, double expected);
std::span<const NamedUnit> loudnessCompatibilityUnits() noexcept;
} // namespace finetune::test
