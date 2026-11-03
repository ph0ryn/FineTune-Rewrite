#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>

namespace finetune::dsp {

// Fixed storage bounds, not a statement of supported hardware formats. Ten sections cover
// the graphic EQ and the Domain AutoEQProfile.maxFilters contract; eight channels include 7.1.
inline constexpr std::size_t maxBiquadSections = 10;
inline constexpr std::size_t maxChannels = 8;
inline constexpr double graphicEQQ = 1.4;
inline constexpr std::array<double, 10> graphicEQFrequencies = {31.25, 62.5, 125,  250,  500,
                                                                1000,  2000, 4000, 8000, 16000};

// Normalized transfer-function order: b0, b1, b2, a1, a2; a0 is one.
using BiquadCoefficients = std::array<double, 5>;
using GraphicEQCoefficients = std::array<double, 50>;

enum class FilterType : std::uint32_t { peaking = 0, lowShelf = 1, highShelf = 2 };
enum class Status : std::uint32_t {
    ok = 0,
    invalidArgument = 1,
    invalidConfiguration = 2,
    nonFiniteSignal = 3
};

struct FilterSpec {
    FilterType type = FilterType::peaking;
    double frequency = 1000;
    float gainDB = 0;
    double q = graphicEQQ;
};

// Control-thread math. Raw coefficient utilities retain mathematical boundary values,
// including frequency=0; prepareBiquad is the stricter executable-configuration boundary.
BiquadCoefficients coefficients(FilterSpec filter, double sampleRate) noexcept;
double preWarpFrequency(double frequency, double sourceRate, double targetRate) noexcept;
GraphicEQCoefficients graphicEQCoefficients(std::span<const float> gains,
                                            double sampleRate) noexcept;
Status autoEQCoefficients(std::span<const FilterSpec> filters, double sampleRate,
                          double profileOptimizedRate, std::span<double> output) noexcept;

class PreparedBiquad {
  public:
    std::size_t sectionCount() const noexcept { return sectionCount_; }
    std::size_t channelCount() const noexcept { return channelCount_; }

  private:
    friend Status prepareBiquad(std::span<const double>, std::size_t, PreparedBiquad &) noexcept;
    friend class BiquadProcessor;
    std::array<BiquadCoefficients, maxBiquadSections> sections_{};
    std::size_t sectionCount_ = 0;
    std::size_t channelCount_ = 0;
    bool valid_ = false;
};

// No partial mutation of output on failure. Empty coefficients explicitly prepare bypass.
Status prepareBiquad(std::span<const double> coefficients, std::size_t channelCount,
                     PreparedBiquad &output) noexcept;

struct ConstChannelView {
    const float *data = nullptr;
    std::size_t stride = 1;
};
struct ChannelView {
    float *data = nullptr;
    std::size_t stride = 1;
};

// Exactly one callback/execution path owns each instance. No shared mutable histories.
// All methods must be serialized by the owner; configure/destroy require a quiescent path.
// Neither publication/reclamation nor hardware format conversion is a DSP responsibility.
class BiquadProcessor {
  public:
    BiquadProcessor() noexcept = default;
    BiquadProcessor(const BiquadProcessor &) = delete;
    BiquadProcessor &operator=(const BiquadProcessor &) = delete;

    Status configure(const PreparedBiquad &prepared) noexcept;
    PreparedBiquad configuration() const noexcept { return prepared_; }
    void setEnabled(bool enabled) noexcept { enabled_ = enabled; }
    bool isEnabled() const noexcept { return enabled_; }
    void reset() noexcept;

    // Supports distinct buffers or exact in-place layouts, not partial overlap. Zero frames
    // is a no-op. Invalid views are rejected before writes. A non-finite input/output mutes
    // the block, resets history and reports nonFiniteSignal; the next clean block can resume.
    Status process(std::span<const ConstChannelView> input, std::span<const ChannelView> output,
                   std::size_t frameCount) noexcept;
    Status processInterleaved(const float *input, float *output, std::size_t frameCount,
                              std::size_t channelCount) noexcept;

  private:
    struct Delay {
        double z1 = 0;
        double z2 = 0;
    };
    PreparedBiquad prepared_{};
    std::array<std::array<Delay, maxBiquadSections>, maxChannels> delays_{};
    bool enabled_ = true;
};

} // namespace finetune::dsp
