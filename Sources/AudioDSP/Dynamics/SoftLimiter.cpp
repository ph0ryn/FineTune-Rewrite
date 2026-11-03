#include "AudioDSP/Dynamics.hpp"

#include <cmath>

namespace finetune::dsp {
float softLimit(float sample) noexcept {
    const float magnitude = std::abs(sample);
    if (magnitude <= limiterThreshold) {
        return sample;
    }
    // A C1 rational continuation of y=x at the threshold, asymptotic to the ceiling.
    // The bounded overshoot ratio avoids overflowing for the largest finite Float32.
    const float overshoot = magnitude - limiterThreshold;
    const float compressed =
        limiterThreshold + limiterHeadroom * (overshoot / (overshoot + limiterHeadroom));
    return std::copysign(compressed, sample);
}

void softLimitBuffer(float *samples, std::size_t sampleCount) noexcept {
    for (std::size_t index = 0; index < sampleCount; ++index) {
        samples[index] = softLimit(samples[index]);
    }
}
} // namespace finetune::dsp
