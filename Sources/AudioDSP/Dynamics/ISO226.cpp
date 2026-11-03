#include "AudioDSP/Dynamics.hpp"
#include "ISO226Data.hpp"

#include <algorithm>
#include <cmath>
#include <numbers>

namespace finetune::dsp {
namespace {
constexpr std::array<FilterSpec, 4> bands{{
    {FilterType::lowShelf, 55, 0, 0.707},
    {FilterType::lowShelf, 250, 0, 0.707},
    {FilterType::peaking, 3500, 0, 0.7},
    {FilterType::highShelf, 9000, 0, 0.707},
}};
constexpr std::size_t fitPointCount = 96;
using FitCurve = std::array<double, fitPointCount>;

double responseDB(const LoudnessBandCoefficients &c, double frequency, double sampleRate) noexcept {
    const double angle = 2 * std::numbers::pi * frequency / sampleRate;
    const double c1 = std::cos(angle), c2 = std::cos(2 * angle);
    const double s1 = std::sin(angle), s2 = std::sin(2 * angle);
    double result = 0;
    for (std::size_t i = 0; i < c.size(); i += 5) {
        const double nr = c[i] + c[i + 1] * c1 + c[i + 2] * c2;
        const double ni = c[i + 1] * s1 + c[i + 2] * s2;
        const double dr = 1 + c[i + 3] * c1 + c[i + 4] * c2;
        const double di = c[i + 3] * s1 + c[i + 4] * s2;
        result += 10 * std::log10((nr * nr + ni * ni) / (dr * dr + di * di));
    }
    return result;
}

LoudnessBandGains solveNormalEquations(std::array<std::array<double, 5>, 4> matrix) noexcept {
    for (std::size_t column = 0; column < 4; ++column) {
        std::size_t pivot = column;
        for (std::size_t row = column + 1; row < 4; ++row) {
            if (std::abs(matrix[row][column]) > std::abs(matrix[pivot][column])) {
                pivot = row;
            }
        }
        std::swap(matrix[column], matrix[pivot]);
        const double diagonal = matrix[column][column];
        for (std::size_t j = column; j < 5; ++j) {
            matrix[column][j] /= diagonal;
        }
        for (std::size_t row = 0; row < 4; ++row) {
            if (row == column) {
                continue;
            }
            const double factor = matrix[row][column];
            for (std::size_t j = column; j < 5; ++j) {
                matrix[row][j] -= factor * matrix[column][j];
            }
        }
    }
    return {matrix[0][4], matrix[1][4], matrix[2][4], matrix[3][4]};
}
} // namespace

Status iso226ReferenceData(std::size_t column, std::span<double> output) noexcept {
    if (column > 3 || output.size() < iso226::points.size()) {
        return Status::invalidArgument;
    }
    for (std::size_t i = 0; i < iso226::points.size(); ++i) {
        const auto &point = iso226::points[i];
        const std::array values{point.frequency, point.exponent, point.transferDB,
                                point.thresholdDB};
        output[i] = values[column];
    }
    return Status::ok;
}

LoudnessContour iso226Contour(double phon) noexcept {
    // ISO 226:2023 Formula (1), independently evaluated in a row-oriented model.
    // Numerical table provenance/limitations are recorded alongside the tests.
    phon = std::clamp(phon, 20.0, 90.0);
    const double referenceExcitation = std::pow(10.0, 0.03 * phon) - std::pow(10.0, 0.03 * 2.4);
    LoudnessContour result{};
    for (std::size_t i = 0; i < iso226::points.size(); ++i) {
        const auto &point = iso226::points[i];
        const double referencePressure = std::pow(4e-10, 0.3 - point.exponent);
        const double thresholdExcitation =
            std::pow(10.0, 0.03 * (point.thresholdDB + point.transferDB));
        result[i] = 10 / point.exponent *
                        std::log10(referencePressure * referenceExcitation + thresholdExcitation) -
                    point.transferDB;
    }
    return result;
}

LoudnessContour iso226Compensation(double phon, double referencePhon, double amount) noexcept {
    auto current = iso226Contour(phon);
    const auto reference = iso226Contour(referencePhon);
    const double referenceDifference = current[17] - reference[17];
    amount = std::clamp(amount, 0.0, 1.0);
    for (std::size_t i = 0; i < current.size(); ++i) {
        current[i] = amount * (current[i] - reference[i] - referenceDifference);
    }
    return current;
}

double estimatedPhon(float volume) noexcept {
    return 20 + 60 * std::sqrt(std::clamp(static_cast<double>(volume), 0.0, 1.0));
}

double interpolateCompensation(std::span<const double> gains, double frequency) noexcept {
    if (gains.size() != iso226::points.size()) {
        return 0;
    }
    if (frequency <= iso226::points.front().frequency) {
        return gains.front();
    }
    for (std::size_t upper = 1; upper < iso226::points.size(); ++upper) {
        if (frequency <= iso226::points[upper].frequency) {
            const double low = iso226::points[upper - 1].frequency;
            const double high = iso226::points[upper].frequency;
            const double fraction = std::log(frequency / low) / std::log(high / low);
            return gains[upper - 1] + fraction * (gains[upper] - gains[upper - 1]);
        }
    }
    return gains.back();
}

LoudnessBandCoefficients loudnessBandCoefficients(const LoudnessBandGains &gains,
                                                  double sampleRate) noexcept {
    LoudnessBandCoefficients result{};
    for (std::size_t i = 0; i < bands.size(); ++i) {
        auto band = bands[i];
        band.gainDB = static_cast<float>(gains[i]);
        const auto c = band.frequency >= sampleRate / 2 ? BiquadCoefficients{1, 0, 0, 0, 0}
                                                        : coefficients(band, sampleRate);
        std::copy(c.begin(), c.end(), result.begin() + i * 5);
    }
    return result;
}

LoudnessBandGains fittedLoudnessGains(double phon, double sampleRate) noexcept {
    const auto target = iso226Compensation(phon);
    FitCurve frequencies{}, desired{};
    const double upperFrequency = std::min(20000.0, sampleRate * 0.49);
    for (std::size_t i = 0; i < frequencies.size(); ++i) {
        frequencies[i] =
            20 * std::pow(upperFrequency / 20, static_cast<double>(i) / (fitPointCount - 1));
        desired[i] = interpolateCompensation(target, frequencies[i]);
    }
    LoudnessBandGains gains{};
    // A fresh four-variable damped Gauss-Newton fit, not an upstream algorithm port.
    // All coefficient/response work and fixed-size linear solves happen off the RT path.
    for (int iteration = 0; iteration < 20; ++iteration) {
        const auto c = loudnessBandCoefficients(gains, sampleRate);
        FitCurve current{};
        std::array<FitCurve, 4> jacobian{};
        for (std::size_t i = 0; i < fitPointCount; ++i) {
            current[i] = responseDB(c, frequencies[i], sampleRate);
        }
        for (std::size_t parameter = 0; parameter < gains.size(); ++parameter) {
            auto perturbed = gains;
            perturbed[parameter] += 0.05;
            const auto shifted = loudnessBandCoefficients(perturbed, sampleRate);
            for (std::size_t i = 0; i < fitPointCount; ++i) {
                jacobian[parameter][i] =
                    (responseDB(shifted, frequencies[i], sampleRate) - current[i]) / 0.05;
            }
        }
        std::array<std::array<double, 5>, 4> normal{};
        for (std::size_t row = 0; row < 4; ++row) {
            for (std::size_t column = 0; column < 4; ++column) {
                normal[row][column] = row == column ? 0.01 : 0;
                for (std::size_t i = 0; i < fitPointCount; ++i) {
                    normal[row][column] += jacobian[row][i] * jacobian[column][i];
                }
            }
            for (std::size_t i = 0; i < fitPointCount; ++i) {
                normal[row][4] += jacobian[row][i] * (desired[i] - current[i]);
            }
        }
        const auto step = solveNormalEquations(normal);
        double largestStep = 0;
        for (std::size_t i = 0; i < gains.size(); ++i) {
            gains[i] = std::clamp(gains[i] + step[i], -40.0, 40.0);
            largestStep = std::max(largestStep, std::abs(step[i]));
        }
        if (largestStep < 0.0001) {
            break;
        }
    }
    return gains;
}

LoudnessCompensator::LoudnessCompensator(double sampleRate) noexcept : sampleRate_(sampleRate) {
    PreparedBiquad bypass;
    prepareBiquad({}, 2, bypass);
    processor_.configure(bypass);
    processor_.setEnabled(false);
}

Status LoudnessCompensator::updateVolume(float volume) noexcept {
    if (!std::isfinite(volume)) {
        return Status::invalidArgument;
    }
    const auto c = loudnessBandCoefficients(fittedLoudnessGains(estimatedPhon(volume), sampleRate_),
                                            sampleRate_);
    PreparedBiquad prepared;
    const auto result = prepareBiquad(c, 2, prepared);
    if (result != Status::ok) {
        return result;
    }
    processor_.configure(prepared);
    processor_.setEnabled(volume < 1);
    volume_ = volume;
    return Status::ok;
}

Status LoudnessCompensator::process(const float *input, float *output,
                                    std::size_t frameCount) noexcept {
    return processor_.processInterleaved(input, output, frameCount, 2);
}
} // namespace finetune::dsp
