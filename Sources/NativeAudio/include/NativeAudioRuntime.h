// SPDX-License-Identifier: MIT
#pragma once

#include "NativeAudioBiquad.h"
#include "NativeAudioDynamics.h"
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FTNativeRoute FTNativeRoute;

typedef enum FTNativeResult {
    FT_NATIVE_OK = 0,
    FT_NATIVE_PENDING = 1,
    FT_NATIVE_FAILED = 2
} FTNativeResult;

typedef enum FTNativeFailureKind {
    FT_NATIVE_NO_FAILURE = 0,
    FT_NATIVE_UNAVAILABLE = 1,
    FT_NATIVE_CAPTURE_NOT_REQUESTED = 2,
    FT_NATIVE_PERMISSION_DENIED = 3,
    FT_NATIVE_UNSUPPORTED = 4,
    FT_NATIVE_BINDING_CHANGED = 5,
    FT_NATIVE_CANCELLED = 6,
    FT_NATIVE_FAILURE = 7
} FTNativeFailureKind;

typedef enum FTNativeOperation {
    FT_NATIVE_INPUT = 0,
    FT_NATIVE_USAGE_DESCRIPTION,
    FT_NATIVE_RESOLVE_PROCESS,
    FT_NATIVE_RESOLVE_OUTPUT,
    FT_NATIVE_CREATE_TAP,
    FT_NATIVE_READ_TAP,
    FT_NATIVE_CREATE_AGGREGATE,
    FT_NATIVE_CREATE_IOPROC,
    FT_NATIVE_CERTIFY_FORMAT,
    FT_NATIVE_INSTALL_LISTENERS,
    FT_NATIVE_PREPARE_DSP,
    FT_NATIVE_START,
    FT_NATIVE_PROCESS,
    FT_NATIVE_STOP,
    FT_NATIVE_DESTROY_IOPROC,
    FT_NATIVE_REMOVE_LISTENER,
    FT_NATIVE_DESTROY_AGGREGATE,
    FT_NATIVE_AWAIT_AGGREGATE_REMOVAL,
    FT_NATIVE_DESTROY_TAP
} FTNativeOperation;

typedef struct FTNativeError {
    FTNativeFailureKind kind;
    FTNativeOperation operation;
    int32_t code; // Exact OSStatus or operation-local native code; never an authorization guess.
} FTNativeError;

typedef struct FTNativeProcessingState {
    const float *eq_gains_db; // Non-null for exactly ten gains, or null/count zero for no EQ.
    uint32_t eq_gain_count;
    bool has_profile; // Absent is stage-off; active empty plus preamp-on is scaled unity.
    const FTBiquadFilter *profile_filters;
    uint32_t profile_filter_count;
    double profile_optimized_rate;
    float profile_preamp_db;
    bool profile_preamp_enabled;
    FTLoudnessSettings loudness_equalizer;
    bool loudness_compensation_enabled;
    float loudness_volume;
} FTNativeProcessingState;

typedef struct FTNativeOutputState {
    uint64_t revision;
    float target_gain;
    bool muted;
    FTNativeProcessingState processing;
} FTNativeOutputState;

typedef struct FTNativeLevels {
    uint64_t revision;
    float target_gain;
    bool muted;
    float loudness_volume; // Unboosted app/device value, not inferred from PCM gain.
} FTNativeLevels;

typedef struct FTNativeRouteRequest {
    const char *output_uid;
    const uint32_t *process_objects;
    uint32_t process_count;
    uint64_t process_revision;
    uint64_t route_generation;
    uint64_t capture_session; // Zero is no explicit live intent; rejected before any acquisition.
    FTNativeOutputState initial_state;
} FTNativeRouteRequest;

typedef enum FTNativePhase {
    FT_NATIVE_PREPARED = 0,
    FT_NATIVE_ACCEPTED,
    FT_NATIVE_STARTED,
    FT_NATIVE_ARMED,
    FT_NATIVE_COMMITTED,
    FT_NATIVE_FIRST_APPLIED,
    FT_NATIVE_RETIRING,
    FT_NATIVE_RETIRED,
    FT_NATIVE_ROUTE_FAILED
} FTNativePhase;

typedef struct FTNativeRouteSnapshot {
    FTNativePhase phase;
    uint64_t accepted_revision; // Full processing state only; zero means not accepted.
    uint64_t applied_revision;  // Conservative full-state coverage, not fast levels alone.
    uint64_t levels_revision;
    uint64_t processing_revision;
    uint64_t callback_count;
    uint64_t callback_error_count;
    float peak;
    FTNativeError failure;
    FTNativeError cleanup_failure;
} FTNativeRouteSnapshot;

// Optional NRT diagnostic snapshot. Independent atomics may span adjacent callbacks; this is
// not a transactional audio/permission certificate. Counters accumulate for the route lifetime.
// Sample jumps mean abs(delta - previous frame count) > 1, not a rendering failure/underflow.
// Missing/invalid timestamps break their baseline; latest sample/offset values then remain stale.
typedef struct FTNativeTimingSnapshot {
    bool enabled;
    double sample_rate;
    uint32_t last_valid_mask; // Latest flags: 1=now host, 2=input sample, 4=output sample valid.
    uint64_t observed_callbacks;
    uint64_t idle_callbacks;
    uint64_t missing_now_host;
    uint64_t missing_input_sample;
    uint64_t missing_output_sample;
    uint64_t nonincreasing_now_host;
    uint64_t host_gaps_over_two_periods;
    uint64_t input_sample_jumps;
    uint64_t output_sample_jumps;
    uint64_t callbacks_over_nominal_period;
    double max_callback_gap_ns;
    double max_callback_duration_ns;
    double max_now_host_gap_ns;
    double max_input_step_error_frames;
    double max_output_step_error_frames;
    double last_input_sample_time;
    double last_output_sample_time;
    double last_io_offset_frames;
    double max_io_offset_change_frames;
} FTNativeTimingSnapshot;

typedef struct FTNativeOutputDescription {
    uint32_t object_id;
    uint32_t input_channels;
    uint32_t output_channels;
    double
        virtual_sample_rate; // Zero means not certified/available; never a nominal-rate fallback.
    bool stereo_float32_supported; // Output format only, not capture/permission certification.
} FTNativeOutputDescription;

// NRT. UID/process/configuration input storage is borrowed only for the call.
// Failed preparation may return a cleanup-pending owner: retain/retire it, never drop it.
// No capture intent or missing main-bundle usage description fails before tap/aggregate/IOProc.
FTNativeResult ft_native_route_prepare(const FTNativeRouteRequest *request, FTNativeRoute **route,
                                       FTNativeError *failure);
// One serialized NRT owner lane per route, including snapshot/retire/release. Independent
// routes may use independent lanes; the implementation serializes shared registry writes.
// Never perform blocking lifecycle/DSP preparation from an IOProc or MainActor.
// Full calls include their own level tuple; a newer fast tuple wins and is never rolled back.
// Observing a changed/missing/self process binding closes admission even if the caller ignores
// the error. Invalid new processing input alone does not invalidate the old valid graph.
FTNativeResult ft_native_route_start_muted(FTNativeRoute *route, const FTNativeOutputState *state,
                                           FTNativeError *failure);
FTNativeResult ft_native_route_commit(FTNativeRoute *route, const FTNativeOutputState *state,
                                      FTNativeError *failure);
FTNativeResult ft_native_route_update(FTNativeRoute *route, const FTNativeOutputState *state,
                                      FTNativeError *failure);
// One serialized non-RT levels producer per route (MainActor is allowed here), independent
// from its NRT owner lane. Bounded POD publication only: no HAL/fitting/history reset.
FTNativeResult ft_native_route_request_levels(FTNativeRoute *route, FTNativeLevels levels);
// Lifetime-protected cancellation only; no wait/HAL/destruction. Idempotent while handle lives.
void ft_native_route_cancel(FTNativeRoute *route);
// Mandatory NRT maintenance while active: poll to collect consumed/retired stage packets.
// RT deliberately stops consuming a second command while the retired slot remains occupied.
// Snapshot is not a pure getter and must run on the route's serialized NRT owner lane.
FTNativeResult ft_native_route_snapshot(const FTNativeRoute *route,
                                        FTNativeRouteSnapshot *snapshot);
// Opt-in NRT diagnostics, same serialized owner lane. Enable only after successful prepare and
// before any start/commit; never toggled/reset while callbacks run. Adds numeric timing reads
// only, with no logs/samples/controls in the callback. Existing snapshot ABI is unchanged.
FTNativeResult ft_native_route_enable_timing(FTNativeRoute *route, FTNativeError *failure);
// Passive diagnostic read, including archived counters after reader-zero retirement.
FTNativeResult ft_native_route_timing_snapshot(const FTNativeRoute *route,
                                               FTNativeTimingSnapshot *snapshot);
// NRT incremental teardown. Pending is predicate-based; no fixed-delay reclamation.
FTNativeResult ft_native_route_retire(FTNativeRoute *route, FTNativeError *cleanup_failure);
// Caller precondition: final caller/queued operation has stopped borrowing the handle;
// native does not count Swift borrowers. The check only succeeds after fully retired,
// otherwise retaining the owner and reporting pending. Swift releases only at final deinit.
FTNativeResult ft_native_route_release(FTNativeRoute *route);
// Read-only NRT metadata; never creates a tap/aggregate or requests recording permission.
FTNativeResult ft_native_describe_output(const char *uid, FTNativeOutputDescription *description,
                                         FTNativeError *failure);

#ifdef __cplusplus
}
#endif
