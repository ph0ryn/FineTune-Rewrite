#pragma once

#include "AudioDSP.hpp"
#include <cstdint>

namespace finetune::dsp {

struct InputBuffer {
    const float *data;
    std::uint32_t frames;
    std::uint32_t channels;
};
struct OutputBuffer {
    float *data;
    std::uint32_t frames;
    std::uint32_t channels;
};
struct RouteParameters {
    float targetGain = 1;
    float crossfade = 1;
    float outputGate = 1;
    float rampCoefficient = 1;
    std::uint32_t preferredLeft = 0;
    std::uint32_t preferredRight = 1;
};

// A route is one execution path. No shared gain or filter history and no synchronization
// inside this class. Construction/configuration/destruction require a quiescent owner.
class RoutePipeline {
  public:
    explicit RoutePipeline(float initialGain) noexcept : currentGain_(initialGain) {}
    RoutePipeline(const RoutePipeline &) = delete;
    RoutePipeline &operator=(const RoutePipeline &) = delete;
    float currentGain() const noexcept { return currentGain_; }
    Status mapAndGain(InputBuffer input, OutputBuffer output, RouteParameters parameters) noexcept;

  private:
    float currentGain_;
};

// Compatibility layout policy, evaluated while preparing a route rather than in a HAL callback.
// -1 denotes an output with no source and must be represented by an empty input buffer.
std::int64_t mappedInputIndex(std::uint32_t inputs, std::uint32_t outputs,
                              std::uint32_t outputIndex) noexcept;

enum class CrossfadePhase : std::uint32_t { idle = 0, warmingUp = 1, crossfading = 2 };
struct CrossfadeState {
    float progress = 0;
    CrossfadePhase phase = CrossfadePhase::idle;
    std::int64_t secondarySamples = 0;
    std::int64_t totalSamples = 0;
    std::int64_t processedSamples = 0;
    static constexpr std::int64_t minimumWarmupSamples = 2048;

    void beginWarmup() noexcept;
    void beginCrossfading() noexcept;
    void complete() noexcept;
    Status advance(std::int64_t samples) noexcept;
    float primaryMultiplier() const noexcept;
    float secondaryMultiplier() const noexcept;
};

struct OutputGateState {
    std::uint32_t phase = 0;
    float progress = 0;
    std::int64_t silentFrames = 0;
};
Status advanceOutputGate(OutputGateState &state, float peak, std::uint32_t frames, float rampFrames,
                         std::uint32_t silenceHoldFrames, float &multiplier) noexcept;

} // namespace finetune::dsp
