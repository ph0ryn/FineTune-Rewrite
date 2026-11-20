#pragma once

#include "NativeAudioDynamics.h"
#include "NativeAudioPipeline.h"
#include <cstdint>
#include <memory>

namespace finetune::native {

// Private native ownership packet. Construction, merge and destruction are non-RT.
// A changed bit with a null owner explicitly removes that stage. No bit means no change.
struct PreparedPipelineStages {
    static constexpr std::uint32_t eqChanged = 1u << 0;
    static constexpr std::uint32_t autoEQChanged = 1u << 1;
    static constexpr std::uint32_t equalizerChanged = 1u << 2;
    static constexpr std::uint32_t compensatorChanged = 1u << 3;
    static constexpr std::uint32_t allChanged = 0xF;

    std::uint32_t changedMask = 0;
    std::unique_ptr<FTBiquadProcessor, decltype(&ft_biquad_destroy)> eq{nullptr, ft_biquad_destroy};
    std::unique_ptr<FTBiquadProcessor, decltype(&ft_biquad_destroy)> autoEQ{nullptr,
                                                                            ft_biquad_destroy};
    std::unique_ptr<FTLoudnessEqualizer, decltype(&ft_loudness_equalizer_destroy)> equalizer{
        nullptr, ft_loudness_equalizer_destroy};
    std::unique_ptr<FTLoudnessCompensator, decltype(&ft_loudness_compensator_destroy)> compensator{
        nullptr, ft_loudness_compensator_destroy};
};

// Caller exclusively owns a valid live pipeline at a quiescent/callback boundary and
// a prepared packet for the same pipeline generation. Mask must be a subset of allChanged.
// Only masked owners swap; old objects return in stages, mask unchanged, gain untouched.
// No allocation, destruction, configuration or locks. After RT exchange the caller retires
// stages for NRT destruction: never merge or republish that retired packet.
// Generation, publication, revision coverage and callback lifetime are caller responsibilities.
void swapPreparedPipelineStages(FTPipeline *pipeline, PreparedPipelineStages &stages) noexcept;

// Exclusive NRT-only merge of distinct, unconsumed packets for the same pipeline generation.
// Newer masked values (including explicit null) win. Missing values are stolen from older.
// Both masks must be subsets of allChanged. Older is consumed (mask=0), and its superseded
// owners remain for NRT destruction. Never pass RT-retired packets or concurrently used data.
void mergeUnconsumedOlderStages(PreparedPipelineStages &newer,
                                PreparedPipelineStages &older) noexcept;

} // namespace finetune::native
