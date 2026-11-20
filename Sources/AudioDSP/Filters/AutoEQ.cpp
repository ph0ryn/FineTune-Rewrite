#include "AudioDSP/AutoEQ.hpp"

#include <array>
#include <cmath>

namespace finetune::dsp {

Status prepareAutoEQ(std::span<const FilterSpec> filters, double actualSampleRate,
                     double profileOptimizedRate, float preampDB, bool preampEnabled,
                     std::size_t channelCount, PreparedBiquad &output) noexcept {
    if (filters.size() > maxBiquadSections || (preampEnabled && !std::isfinite(preampDB))) {
        return Status::invalidArgument;
    }
    std::array<double, maxBiquadSections * 5> values{};
    std::size_t valueCount = filters.size() * 5;
    const auto result = autoEQCoefficients(filters, actualSampleRate, profileOptimizedRate,
                                           std::span(values).first(valueCount));
    if (result != Status::ok) {
        return result;
    }
    if (preampEnabled) {
        if (valueCount == 0) {
            values[0] = 1;
            valueCount = 5;
        }
        const double gain = std::pow(10.0, static_cast<double>(preampDB) / 20.0);
        for (std::size_t i = 0; i < 3; ++i) {
            values[i] *= gain;
        }
    }
    return prepareBiquad(std::span(values).first(valueCount), channelCount, output);
}

} // namespace finetune::dsp
