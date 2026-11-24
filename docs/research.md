# Research Notes

This document records findings from investigating the comparison baseline and the rationale behind intentional divergences. Observable contracts live in the [specification](spec.md), structural decisions in the [architecture](architecture.md), and verification scope in the [verification policy](verification.md).

## macOS 26 AirPods Ear Detection and Transient Reapplication

During its post-connect grace window, upstream FineTune rewrites the default back to the confirmed device whenever macOS switches to a newly connected device, accepting a switch as a user action only after more than 1 second elapses without an override. On macOS 26, AirPods Automatic Ear Detection reapplies transients on a 0.5-second cadence. At that cadence, the 1-second idle condition is never satisfied, causing an endless loop of rewrites and OS reapplications. This weakness exists in upstream code itself and is not resolved by a faithful port of the switching logic.

Upstream's troubleshooting guide explicitly states that it should not interfere with Automatic Ear Detection. To satisfy in code a requirement upstream failed to meet under this condition, we limit observed-default rewrites to at most once per trigger: connection batch start, disconnect fallback, explicit selection, or settings change. Transients reapplied by the OS within the same connection episode are accepted without writing back. Input lock applies on the same triggers only, respecting input changes made in Settings. Priority behavior is preserved, while upstream's echo-timeout rewrite is omitted because it would act as an extra retry under this policy. See [specification](spec.md) for the contract.

## Duplicate Taps and Resource Lifetimes

Do not increase default-correction retry counts or capture retry counts. Separate duplicate taps from code-level lifetime bugs mechanically. Eliminating Bluetooth revert behavior or audible glitches is not a conclusion of this investigation and remains a separate real-hardware check ([verification policy](verification.md)).

## Input Stream Starting Channel Number

Only when read-back confirms a single owned stereo tap paired with the intended physical output device, accept a stream starting channel number greater than `1` as long as it represents 2 contiguous channels matching the IOProc buffer layout. Do not misinterpret a starting channel of `5` with a single stereo buffer as an unsupported format or a 4-channel offset into the buffer.

[StartingChannel](https://developer.apple.com/documentation/coreaudio/kaudiostreampropertystartingchannel) identifies the device property element number, whereas [StreamConfiguration](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertystreamconfiguration) describes the IOProc buffer layout. Conflating the two leaks the starting channel number into real-time offsets or certificate invariants and falsely rejects valid contiguous stereo streams. Physical and aggregate outputs still require channels 1 and 2, and extra inputs, non-contiguous channel numbers, or mismatched format/buffer layouts are rejected. Playback and audible continuity across switches are verified separately ([verification policy](verification.md)).

## Difference Between Software Mute and System Alerts

Upstream's software-tier mute attenuates only gain inside the tap, leaving system alert sounds outside the tap audible. Hardware and DDC tiers mute at the device level, which silences alerts as well—so on outputs without hardware mute such as HDMI, unhandled-key beeps still play even when the device is "muted". Treating this gap as an acceptance-criteria difference, we adopt an intentional divergence: set OS alert volume to `0` only while the System Sounds output device is muted via the software tier. Keeping the restore value separate from the app's `Alert Volume` setting stems from this same distinction. See [specification](spec.md) for the contract.

## Settings Performance and Visual Simplicity

The native route monitor publishes level snapshots every 20 ms. When those snapshots were stored in the same observed dictionary used for route diagnostics, Settings subscribed to meter changes through its error projection and rebuilt the whole SwiftUI settings body for every active route. Process sampling showed the main thread repeatedly inside `FineTuneSettingsView.body` and `RootPresentation.settingsSnapshot`; a focused Observation test confirmed that a peak-only update invalidated Settings. The rewrite separates meter values from diagnostic revision so Mixer can remain live while Settings redraws only for preference or diagnostic changes.

The previous SwiftUI `TabView` also placed its tab strip at the content edge under the title bar, producing clipped tops and a grouped gray plate. Settings now uses plain text tabs in normal content with a small selection underline, native window background, and spacing instead of grouped form cards. This intentionally differs from the baseline's conventional settings chrome while preserving every preference and lazy shortcut-recorder behavior. See [specification](spec.md) for the contract.

## Test Adaptation and Deferred Items

Pure input/output contracts can be carried over directly. By contrast, legacy private APIs, fixtures holding unused engines, legacy vDSP setup ownership, mock self-defaults, and unasserted posts to the real OS are replaced with tests against the new boundaries. Whenever upstream guarantees can be preserved via split or merged units, do not add a large compatibility facade recreating legacy classes.

- Verify initial aggregate/tap setup via the new planner and an injectable route port without pinning legacy method names or exact scheduling timestamps.
- Verify media-key handlers and watchdogs using the real monitor and Control, isolating only the OS tap, clock, and HUD presentation.
- Verify menu-action event construction and dispatch through a poster seam rather than smoke-testing by posting directly to the test runner's real event pump.
- Adapt signal helpers to native-owned coefficient copies. Scenarios that only asserted legacy detection points or poisoned vDSP state are recorded individually with their rationale and replacement guarantees (finite output, explicit errors, state reset). Formulas, provenance, and offline verification limits live in [Compatibility.md](<../Tools/DSPTests/Compatibility.md>).

Deferred items include changing URL volume values to `s²` and boost extensions. Keep upstream's current behavior, known defects, and future enhancements separate, and never fold future changes into compatibility fixes silently. Upstream issue/PR proposals around idle, first-audio onset, switching, reconnect, and long-running stability are likewise handled with explicit reproduction and acceptance criteria.

## Priority-Edit Device Rows

The pinned upstream revision renders edit mode with a dedicated [`DeviceEditRow`](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/Rows/DeviceEditRow.swift): drag handle, editable position, icon, name, `DEFAULT` pill, visibility toggle, and info action. It does not reuse the volume-bearing normal row. Reusing `DeviceRow` plus edit-only columns in a 510pt popup collapsed the name column, placed the default checkmark over the mute icon, and shifted only the default row's trailing controls by the width of a trailing `DEFAULT` label. The rewrite now uses the upstream edit-row controls, with intentional divergences: the numeric position is neither displayed nor editable, and rows swap **while dragging** as the pointer passes over them instead of moving only at drop time. The order reached during the drag is held locally and committed with `setPriority` once when the drag ends, so a drag across many rows does not write on every step. The drag handle is an AppKit source with a `.move`-only operation mask and a name preview, and the drop delegate proposes `.move`, which removes macOS's green copy `+` cursor. `setPriority`, persisted priority order, and routing behavior are unchanged; only the interaction differs. The tradeoff is losing keyboard or precise positional reordering, accepted because drag already covers the needed action.

## Private Aggregate Tap Drift/Quality and SubTapList

Never modify a private aggregate's tap drift or quality after creation. On every certification, read `Composition` back from the OS and verify a unique match with the owned tap UID, numeric types, and values—never substitute creation-time request dictionaries or defaults for observation. Require sub-tap drift compensation ON (`1`, `kAudioAggregateDriftCompensationHighQuality`) for all transports, including Bluetooth/BLE. On AirPods A2DP, `bluetoothd` dynamically switches Adaptive Latency between 60ms (mode 1) and 100ms (mode 3) during RF retransmission spikes, and `coreaudiod` (`BTAudio`) temporarily warps the Bluetooth HAL delivery clock by ±10% (`multiplier 0.9` / `1.1`) for ~400ms to shift buffer depth. With `kAudioSubTapDriftCompensationKey` disabled, the aggregate pulls ~2,000–3,700 extra frames on downgrade to mode 3 without resampling the sub-tap, leaving the tap input in a corrupted state (`inputDiscontinuities == outputDiscontinuities`, `inputOutputMismatches == 0`) until latency upgrades back to mode 1 or the route is rebuilt.

Use `SubTapList` IDs only for active-member identity comparison, without assuming child object properties can be read or observed. Observe the aggregate's `Composition`, tap/subtap lists, and underlying physical devices/streams, and re-verify before start. Direct mutation of child drift/quality by external code in the same process is unsupported, as there is no guarantee child mutations emit parent `Composition` notifications. Architectural handling lives in the [architecture](architecture.md).
