// SPDX-License-Identifier: MIT
#pragma once

#include "../PreparedPipelineStages.hpp"
#include "HalAPI.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <cmath>
#include <memory>
#include <new>

namespace finetune::runtime {
using finetune::native::PreparedPipelineStages;

struct OwnedProcessing {
    std::array<float, 10> eq{};
    bool hasEQ = false;
    std::array<FTBiquadFilter, 10> filters{};
    std::uint32_t filterCount = 0;
    bool hasProfile = false;
    double profileRate = 0;
    float preamp = 0;
    bool preampEnabled = false;
    FTLoudnessSettings equalizer{};
    bool compensationEnabled = false;
    float volume = 1;

    static bool copy(const FTNativeProcessingState &source, OwnedProcessing &result) noexcept {
        if (!((source.eq_gain_count == 0 && !source.eq_gains_db) ||
              (source.eq_gain_count == 10 && source.eq_gains_db)) ||
            !std::isfinite(source.loudness_volume) || source.loudness_volume < 0 ||
            source.loudness_volume > 1) return false;
        result.hasEQ = source.eq_gain_count != 0;
        if (result.hasEQ) std::copy_n(source.eq_gains_db, 10, result.eq.begin());
        result.hasProfile = source.has_profile;
        if (result.hasProfile) {
            if (source.profile_filter_count > 10 ||
                (source.profile_filter_count != 0 && !source.profile_filters)) return false;
            result.filterCount = source.profile_filter_count;
            if (result.filterCount) std::copy_n(source.profile_filters, result.filterCount, result.filters.begin());
            result.profileRate = source.profile_optimized_rate;
            result.preamp = source.profile_preamp_db;
            result.preampEnabled = source.profile_preamp_enabled;
        }
        result.equalizer = source.loudness_equalizer;
        result.compensationEnabled = source.loudness_compensation_enabled;
        result.volume = source.loudness_volume;
        return true;
    }
    bool sameEQ(const OwnedProcessing &other) const noexcept {
        return hasEQ == other.hasEQ && (!hasEQ || eq == other.eq);
    }
    bool sameAutoEQ(const OwnedProcessing &other) const noexcept {
        if (hasProfile != other.hasProfile) return false;
        if (!hasProfile) return true;
        if (filterCount != other.filterCount || preampEnabled != other.preampEnabled ||
            std::bit_cast<std::uint64_t>(profileRate) != std::bit_cast<std::uint64_t>(other.profileRate) ||
            (preampEnabled && preamp != other.preamp)) return false;
        for (std::size_t i = 0; i < filterCount; ++i) {
            const auto &a = filters[i], &b = other.filters[i];
            if (a.type != b.type || a.frequency != b.frequency || a.gain_db != b.gain_db || a.q != b.q) return false;
        }
        return true;
    }
    static auto equalizerValues(const FTLoudnessSettings &s) noexcept {
        return std::array{s.target_loudness_db, s.max_boost_db, s.max_cut_db,
            s.compression_threshold_offset_db, s.compression_ratio, s.compression_knee_db,
            s.analysis_window_ms, s.analysis_hop_ms, s.detector_attack_ms, s.detector_release_ms,
            s.gain_attack_ms, s.gain_release_ms, s.noise_floor_threshold_db, s.low_level_max_boost_db};
    }
    bool sameEqualizer(const OwnedProcessing &other) const noexcept {
        return equalizer.enabled == other.equalizer.enabled &&
               (!equalizer.enabled || equalizerValues(equalizer) == equalizerValues(other.equalizer));
    }
    bool sameCompensator(const OwnedProcessing &other) const noexcept {
        return compensationEnabled == other.compensationEnabled &&
               (!compensationEnabled || volume == other.volume);
    }
};

inline FTNativeError prepareStages(const OwnedProcessing *old, const OwnedProcessing &state,
                                    double rate, PreparedPipelineStages &output) {
    if (!old || !state.sameEQ(*old)) {
        output.changedMask |= PreparedPipelineStages::eqChanged;
        if (state.hasEQ) {
            output.eq.reset(ft_biquad_create(2));
            std::array<double, 50> coefficients{};
            if (!output.eq || ft_biquad_graphic_coefficients(state.eq.data(), 10, rate, coefficients.data()) != FT_BIQUAD_OK ||
                ft_biquad_replace_coefficients(output.eq.get(), coefficients.data(), 10) != FT_BIQUAD_OK)
                return failure(FT_NATIVE_UNSUPPORTED, FT_NATIVE_PREPARE_DSP, FT_BIQUAD_INVALID_CONFIGURATION);
        }
    }
    if (!old || !state.sameAutoEQ(*old)) {
        output.changedMask |= PreparedPipelineStages::autoEQChanged;
        if (state.hasProfile) {
            output.autoEQ.reset(ft_biquad_create(2));
            // The shared task33 C operation is the only AutoEQ arithmetic path.
            if (!output.autoEQ || ft_biquad_prepare_autoeq(output.autoEQ.get(), state.filters.data(),
                state.filterCount, rate, state.profileRate, state.preamp, state.preampEnabled) != FT_BIQUAD_OK)
                return failure(FT_NATIVE_UNSUPPORTED, FT_NATIVE_PREPARE_DSP, FT_BIQUAD_INVALID_CONFIGURATION);
        }
    }
    if (!old || !state.sameEqualizer(*old)) {
        output.changedMask |= PreparedPipelineStages::equalizerChanged;
        if (state.equalizer.enabled) {
            output.equalizer.reset(ft_loudness_equalizer_create(&state.equalizer, static_cast<float>(rate)));
            if (!output.equalizer) return failure(FT_NATIVE_UNSUPPORTED, FT_NATIVE_PREPARE_DSP, 2);
        }
    }
    if (!old || !state.sameCompensator(*old)) {
        output.changedMask |= PreparedPipelineStages::compensatorChanged;
        if (state.compensationEnabled) {
            output.compensator.reset(ft_loudness_compensator_create(rate));
            if (!output.compensator || ft_loudness_compensator_update_volume(output.compensator.get(), state.volume) != 0)
                return failure(FT_NATIVE_UNSUPPORTED, FT_NATIVE_PREPARE_DSP, 2);
        }
    }
    return {};
}

struct StageCommand {
    PreparedPipelineStages stages;
    std::uint64_t revision = 0;
    FTNativeLevels fullLevels{}; // Immutable full-state fallback, never republished to the hot lane.
};

// SPSC pointer ownership. At most one pending and one consumed-retired package;
// producer fitting remains NRT, consumer does only swaps and atomic handoffs.
class StateMailbox {
  public:
    ~StateMailbox() { collect(); delete pending_.exchange(nullptr); }
    StateMailbox() = default;
    StateMailbox(const StateMailbox &) = delete;
    StateMailbox &operator=(const StateMailbox &) = delete;
    static_assert(std::atomic<StageCommand *>::is_always_lock_free);

    void collect() noexcept { delete retired_.exchange(nullptr, std::memory_order_acq_rel); }
    void publish(std::unique_ptr<StageCommand> candidate) noexcept {
        collect();
        std::unique_ptr<StageCommand> older(pending_.exchange(nullptr, std::memory_order_acq_rel));
        if (older) finetune::native::mergeUnconsumedOlderStages(candidate->stages, older->stages);
        pending_.store(candidate.release(), std::memory_order_release);
    }
    bool apply(FTPipeline *pipeline, std::uint64_t &installed, FTNativeLevels &fullLevels) noexcept {
        if (retired_.load(std::memory_order_acquire)) return false;
        auto *candidate = pending_.exchange(nullptr, std::memory_order_acq_rel);
        if (!candidate) return false;
        finetune::native::swapPreparedPipelineStages(pipeline, candidate->stages);
        installed = candidate->revision;
        fullLevels = candidate->fullLevels;
        retired_.store(candidate, std::memory_order_release);
        return true;
    }

  private:
    std::atomic<StageCommand *> pending_{nullptr};
    std::atomic<StageCommand *> retired_{nullptr};
};
} // namespace finetune::runtime
