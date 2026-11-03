// SPDX-License-Identifier: MIT
// Actual native ownership units; no replacement DSP or test-only production ABI.
#include "../../Sources/NativeAudio/PreparedPipelineStages.hpp"
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>

namespace observation {
std::atomic<bool> callback{false};
std::atomic<std::size_t> allocations{0}, deletions{0}, allDeletions{0};
static_assert(std::atomic<std::size_t>::is_always_lock_free);
void allocation() noexcept {
    if (callback.load(std::memory_order_relaxed))
        ++allocations;
}
void deletion(void *p) noexcept {
    if (p) {
        ++allDeletions;
        if (callback.load(std::memory_order_relaxed))
            ++deletions;
    }
}
} // namespace observation
void *operator new(std::size_t size) {
    observation::allocation();
    if (void *p = std::malloc(size ? size : 1))
        return p;
    std::abort();
}
void *operator new[](std::size_t size) { return ::operator new(size); }
void operator delete(void *p) noexcept {
    observation::deletion(p);
    std::free(p);
}
void operator delete[](void *p) noexcept { ::operator delete(p); }
void operator delete(void *p, std::size_t) noexcept { ::operator delete(p); }
void operator delete[](void *p, std::size_t) noexcept { ::operator delete(p); }
void *operator new(std::size_t size, std::align_val_t alignment) {
    observation::allocation();
    void *p = nullptr;
    if (posix_memalign(&p, static_cast<std::size_t>(alignment), size ? size : 1) != 0)
        std::abort();
    return p;
}
void *operator new[](std::size_t size, std::align_val_t a) { return ::operator new(size, a); }
void operator delete(void *p, std::align_val_t) noexcept { ::operator delete(p); }
void operator delete[](void *p, std::align_val_t) noexcept { ::operator delete(p); }
void operator delete(void *p, std::size_t, std::align_val_t) noexcept { ::operator delete(p); }
void operator delete[](void *p, std::size_t, std::align_val_t) noexcept { ::operator delete(p); }

namespace {
using finetune::native::mergeUnconsumedOlderStages;
using finetune::native::PreparedPipelineStages;
using finetune::native::swapPreparedPipelineStages;
using Stages = PreparedPipelineStages;
using Buffer = std::array<float, 4096>;
constexpr std::array<std::uint32_t, 4> bits{Stages::eqChanged, Stages::autoEQChanged,
                                            Stages::equalizerChanged, Stages::compensatorChanged};
std::size_t failures = 0, checks = 0, invocations = 1;
const char *currentID = "startup";
void check(bool value, const char *property) {
    ++checks;
    if (!value) {
        if (failures < 12)
            std::fprintf(stderr, "%s: %s\n", currentID, property);
        ++failures;
    }
}
#define CHECK(expr) check(bool(expr), #expr)
using PipelineOwner = std::unique_ptr<FTPipeline, decltype(&ft_pipeline_destroy)>;
PipelineOwner pipeline(float gain = 1) {
    PipelineOwner p(ft_pipeline_create(gain), ft_pipeline_destroy);
    CHECK(p != nullptr);
    if (!p)
        std::abort();
    return p;
}
Stages packet(std::uint32_t mask, std::uint32_t present, bool newer = false) {
    Stages result;
    result.changedMask = mask;
    auto biquad = [newer]() {
        auto *p = ft_biquad_create(2);
        CHECK(p != nullptr);
        if (!p)
            std::abort();
        const double coefficients[5]{newer ? 0.5 : 0.25, 0, 0, newer ? -0.25 : -0.75, 0};
        CHECK(ft_biquad_replace_coefficients(p, coefficients, 1) == FT_BIQUAD_OK);
        return p;
    };
    if (mask & present & Stages::eqChanged)
        result.eq.reset(biquad());
    if (mask & present & Stages::autoEQChanged)
        result.autoEQ.reset(biquad());
    if (mask & present & Stages::equalizerChanged) {
        const FTLoudnessSettings s{-12, 4, 6, 4, 1.5F, 6, 30, 15, 10, 100, 3, 70, -80, 4, true};
        result.equalizer.reset(ft_loudness_equalizer_create(&s, 48000));
        CHECK(result.equalizer != nullptr);
        if (!result.equalizer)
            std::abort();
    }
    if (mask & present & Stages::compensatorChanged) {
        result.compensator.reset(ft_loudness_compensator_create(48000));
        CHECK(result.compensator != nullptr);
        if (!result.compensator)
            std::abort();
        CHECK(ft_loudness_compensator_update_volume(result.compensator.get(),
                                                    newer ? 0.65F : 0.4F) == 0);
    }
    return result;
}
std::array<void *, 4> identities(const Stages &s) {
    return {s.eq.get(), s.autoEQ.get(), s.equalizer.get(), s.compensator.get()};
}
Buffer input(bool second = false) {
    Buffer b{};
    for (std::size_t i = 0; i < b.size(); i += 2) {
        b[i] = second ? 0.003F : 0.01F;
        b[i + 1] = second ? -0.002F : -0.005F;
    }
    return b;
}
Buffer process(FTPipeline *p, const Buffer &in, FTPipelineParameters parameters) {
    Buffer out{};
    CHECK(ft_pipeline_process(p, {in.data(), 2048, 2}, {out.data(), 2048, 2}, parameters) ==
          FT_PIPELINE_OK);
    return out;
}
void swapObserved(FTPipeline *p, Stages &stages) {
    const auto a = observation::allocations.load(), d = observation::deletions.load();
    observation::callback = true;
    swapPreparedPipelineStages(p, stages);
    observation::callback = false;
    CHECK(observation::allocations == a);
    CHECK(observation::deletions == d);
}
Buffer callback(FTPipeline *p, const Buffer &in, FTPipelineParameters parameters,
                Stages *update = nullptr) {
    const auto a = observation::allocations.load(), d = observation::deletions.load();
    observation::callback = true;
    if (update)
        swapPreparedPipelineStages(p, *update);
    auto out = process(p, in, parameters);
    observation::callback = false;
    CHECK(observation::allocations == a);
    CHECK(observation::deletions == d);
    return out;
}
void install(FTPipeline *p) {
    auto stages = packet(Stages::allChanged, Stages::allChanged);
    swapObserved(p, stages);
    CHECK(identities(stages) == (std::array<void *, 4>{}));
}
void fourStageSwapClearAndRetire() {
    auto p = pipeline(), reference = pipeline();
    auto prepared = packet(Stages::allChanged, Stages::allChanged);
    const auto installed = identities(prepared);
    swapObserved(p.get(), prepared);
    CHECK(identities(prepared) == (std::array<void *, 4>{}));
    CHECK(prepared.changedMask == Stages::allChanged);
    install(reference.get());
    auto parameters = ft_pipeline_default_parameters();
    const auto first = input();
    CHECK(callback(p.get(), first, parameters) == process(reference.get(), first, parameters));
    Stages retired;
    retired.changedMask = Stages::allChanged;
    const auto gain = ft_pipeline_current_gain(p.get());
    swapObserved(p.get(), retired);
    CHECK(identities(retired) == installed);
    CHECK(retired.changedMask == Stages::allChanged);
    CHECK(ft_pipeline_current_gain(p.get()) == gain);
    const auto next = input(true);
    auto expected = process(reference.get(), next, parameters);
    // Quiescent unit-only borrow of returned handles observes all four histories.
    // No retired packet is merged or republished into a runtime/pipeline.
    Buffer observed = next;
    CHECK(ft_biquad_process(retired.eq.get(), observed.data(), observed.data(), 2048) ==
          FT_BIQUAD_OK);
    CHECK(ft_biquad_process(retired.autoEQ.get(), observed.data(), observed.data(), 2048) ==
          FT_BIQUAD_OK);
    CHECK(ft_loudness_equalizer_process(retired.equalizer.get(), observed.data(), observed.data(),
                                        2048, 2) == 0);
    CHECK(ft_loudness_compensator_process(retired.compensator.get(), observed.data(),
                                          observed.data(), 2048) == 0);
    ft_soft_limiter_process(observed.data(), static_cast<uint32_t>(observed.size()));
    CHECK(observed == expected);
    CHECK(callback(p.get(), next, parameters) == next);
    const auto deleted = observation::allDeletions.load();
    retired.eq.reset();
    retired.autoEQ.reset();
    retired.equalizer.reset();
    retired.compensator.reset();
    CHECK(observation::allDeletions >= deleted + 4);
}
void unmaskedGainAndHistory() {
    auto p = pipeline(0.25F), reference = pipeline(0.25F);
    install(p.get());
    install(reference.get());
    auto parameters = ft_pipeline_default_parameters();
    parameters.target_gain = 0.8F;
    parameters.ramp_coefficient = 0.02F;
    const auto warm = input();
    CHECK(callback(p.get(), warm, parameters) == process(reference.get(), warm, parameters));
    const auto gain = ft_pipeline_current_gain(p.get());
    Stages unchanged;
    const auto next = input(true);
    CHECK(callback(p.get(), next, parameters, &unchanged) ==
          process(reference.get(), next, parameters));
    CHECK(ft_pipeline_current_gain(p.get()) == ft_pipeline_current_gain(reference.get()));
    CHECK(gain != 0.25F);
    CHECK(identities(unchanged) == (std::array<void *, 4>{}));
}
void singleStagePreservesOthers() {
    invocations = 8;
    for (auto bit : bits)
        for (bool present : {false, true}) {
            auto p = pipeline(0.4F), reference = pipeline(0.4F);
            install(p.get());
            install(reference.get());
            auto parameters = ft_pipeline_default_parameters();
            parameters.target_gain = 0.9F;
            parameters.ramp_coefficient = 0.01F;
            const auto warm = input();
            CHECK(callback(p.get(), warm, parameters) ==
                  process(reference.get(), warm, parameters));
            auto change = packet(bit, present ? bit : 0, true);
            if (bit == Stages::eqChanged || bit == Stages::autoEQChanged)
                CHECK(ft_pipeline_configure_biquad(
                          reference.get(), bit == Stages::eqChanged ? 0 : 1,
                          bit == Stages::eqChanged ? change.eq.get() : change.autoEQ.get()) ==
                      FT_PIPELINE_OK);
            if (bit == Stages::equalizerChanged)
                CHECK(ft_pipeline_configure_equalizer(reference.get(), change.equalizer.get()) ==
                      FT_PIPELINE_OK);
            if (bit == Stages::compensatorChanged)
                CHECK(ft_pipeline_configure_compensator(
                          reference.get(), change.compensator.get()) == FT_PIPELINE_OK);
            const auto gain = ft_pipeline_current_gain(p.get());
            swapObserved(p.get(), change);
            CHECK(ft_pipeline_current_gain(p.get()) == gain);
            CHECK(callback(p.get(), input(true), parameters) ==
                  process(reference.get(), input(true), parameters));
        }
}
void mergePendingTwoAndNewThree() {
    auto older = packet(Stages::eqChanged | Stages::equalizerChanged, Stages::allChanged);
    auto newer =
        packet(Stages::autoEQChanged | Stages::equalizerChanged | Stages::compensatorChanged,
               Stages::autoEQChanged | Stages::compensatorChanged, true);
    const auto oldIDs = identities(older), newIDs = identities(newer);
    mergeUnconsumedOlderStages(newer, older);
    CHECK(newer.changedMask == Stages::allChanged);
    CHECK(older.changedMask == 0);
    CHECK(newer.eq.get() == oldIDs[0]);
    CHECK(newer.autoEQ.get() == newIDs[1]);
    CHECK(newer.equalizer == nullptr);
    CHECK(newer.compensator.get() == newIDs[3]);
    CHECK(older.eq == nullptr && older.equalizer.get() == oldIDs[2]);
    auto p = pipeline(), reference = pipeline();
    CHECK(ft_pipeline_configure_biquad(reference.get(), 0, newer.eq.get()) == FT_PIPELINE_OK);
    CHECK(ft_pipeline_configure_biquad(reference.get(), 1, newer.autoEQ.get()) == FT_PIPELINE_OK);
    CHECK(ft_pipeline_configure_compensator(reference.get(), newer.compensator.get()) ==
          FT_PIPELINE_OK);
    swapObserved(p.get(), newer);
    CHECK(callback(p.get(), input(), ft_pipeline_default_parameters()) ==
          process(reference.get(), input(), ft_pipeline_default_parameters()));
}
std::array<std::uint32_t, 2> ternaryState(unsigned value) {
    std::uint32_t mask = 0, present = 0;
    for (auto bit : bits) {
        const auto digit = value % 3;
        if (digit)
            mask |= bit;
        if (digit == 2)
            present |= bit;
        value /= 3;
    }
    return {mask, present};
}
void exhaustiveUnconsumedMerge() {
    invocations = 81 * 81;
    std::size_t pairs = 0;
    for (unsigned n = 0; n < 81; ++n)
        for (unsigned o = 0; o < 81; ++o) {
            const auto ns = ternaryState(n), os = ternaryState(o);
            auto newer = packet(ns[0], ns[1], true), older = packet(os[0], os[1]);
            const auto newIDs = identities(newer), oldIDs = identities(older);
            mergeUnconsumedOlderStages(newer, older);
            CHECK(newer.changedMask == (ns[0] | os[0]));
            CHECK(older.changedMask == 0);
            const auto got = identities(newer), left = identities(older);
            for (std::size_t i = 0; i < bits.size(); ++i) {
                CHECK(got[i] == ((ns[0] & bits[i]) ? newIDs[i] : oldIDs[i]));
                CHECK(left[i] == ((ns[0] & bits[i]) ? oldIDs[i] : nullptr));
            }
            ++pairs;
        }
    CHECK(pairs == 6561);
}
struct Result {
    const char *id;
    void (*run)();
    std::size_t count = 0, checks = 0, failed = 0;
};
std::array<Result, 5> results{{
    {"Tests/NativeStageTests/main.cpp::fourStageSwapClearAndRetire", fourStageSwapClearAndRetire},
    {"Tests/NativeStageTests/main.cpp::unmaskedGainAndHistory", unmaskedGainAndHistory},
    {"Tests/NativeStageTests/main.cpp::singleStagePreservesOthers", singleStagePreservesOthers},
    {"Tests/NativeStageTests/main.cpp::mergePendingTwoAndNewThree", mergePendingTwoAndNewThree},
    {"Tests/NativeStageTests/main.cpp::exhaustiveUnconsumedMerge", exhaustiveUnconsumedMerge},
}};
bool report(const char *path, bool complete) {
    auto *f = std::fopen(path, "w");
    if (!f)
        return false;
    bool ok = std::fprintf(f, "{\"schema_version\":1,\"complete\":%s,\"cases\":[",
                           complete ? "true" : "false") >= 0;
    if (complete)
        for (std::size_t i = 0; i < results.size(); ++i) {
            const auto &r = results[i];
            ok &= std::fprintf(f,
                               "%s{\"id\":\"%s\",\"status\":\"%s\",\"invocations\":%zu,\"checks\":%"
                               "zu,\"failures\":%zu}",
                               i ? "," : "", r.id, r.failed ? "failed" : "passed", r.count,
                               r.checks, r.failed) >= 0;
        }
    ok &=
        std::fprintf(
            f,
            "],\"callback_allocations\":%zu,\"callback_deletions\":%zu,\"total_deletions\":%zu}\n",
            observation::allocations.load(), observation::deletions.load(),
            observation::allDeletions.load()) >= 0;
    const bool wrote = std::ferror(f) == 0;
    const bool closed = std::fclose(f) == 0;
    return ok && wrote && closed;
}
} // namespace
int main(int argc, char **argv) {
    const bool inject = argc == 4 && std::strcmp(argv[3], "--inject-check-failure") == 0;
    if ((argc != 3 && !inject) || std::strcmp(argv[1], "--report") != 0)
        return 2;
    if (!report(argv[2], false))
        return 2;
    for (auto &r : results) {
        currentID = r.id;
        const auto before = failures, beforeChecks = checks;
        invocations = 1;
        if (inject && &r == &results.front())
            CHECK(false);
        r.run();
        CHECK(checks > beforeChecks);
        r.count = invocations;
        r.checks = checks - beforeChecks;
        r.failed = failures - before;
        std::printf("%s: %s (%zu invocations, %zu always-on checks)\n", r.id,
                    r.failed ? "FAIL" : "PASS", r.count, r.checks);
    }
    if (!report(argv[2], true))
        return 2;
    return failures ? 1 : 0;
}
