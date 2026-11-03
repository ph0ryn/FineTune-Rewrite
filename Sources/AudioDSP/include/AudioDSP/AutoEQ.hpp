// SPDX-License-Identifier: MIT
#pragma once

#include "AudioDSP/AudioDSP.hpp"

namespace finetune::dsp {

// Non-RT value preparation shared by control adapters and native route preparation.
// Actual callback rate and profile rate are distinct inputs; no device-rate fallback.
// Empty active profiles have one scaled-unity section only when preamp is enabled.
// Disabled preamp is not evaluated. Failure leaves output unchanged.
Status prepareAutoEQ(std::span<const FilterSpec> filters, double actualSampleRate,
                     double profileOptimizedRate, float preampDB, bool preampEnabled,
                     std::size_t channelCount, PreparedBiquad &output) noexcept;

} // namespace finetune::dsp
