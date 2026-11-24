# Compatibility Specification

This document defines the externally observable contract that FineTune-Rewrite must satisfy. Internal structure, call ordering, and ownership belong in the [architecture](architecture.md); rationale and upstream comparisons belong in [research notes](research.md); verification methods belong in the [verification policy](verification.md).

The comparison baseline is the [pinned FineTune revision](https://github.com/ronitsingh10/FineTune/commit/2285279d36d3f8115c1c2d4aecd904f1bdf96a51). Compatibility covers core usage across features, UI, interaction model, settings, and external integrations, without replicating internal class hierarchies or constraints of the original implementation. Intentional divergences are specified here as part of the contract; their rationale is documented in [research notes](research.md).

## Preserved Semantics

- Preserve per-app and per-device volume, mute, and boost semantics, software slider behavior, route selection, and saved user intent.
- Do not destroy saved user preferences due to transient device disconnects or apply failures.
- Preserve persisted values and selection semantics for display settings, shortcuts, HUD, icons, EQ presets, and related preferences.
- Route all entry points (UI, keyboard, URL scheme, etc.) through shared Control operations; do not split volume semantics or state update paths by entry point.
- Maintain independent mutable DSP state per route and channel so initial audio onset and resume after silence are not lost.

## Rights and Attribution Divergences

- Rights-driven changes relative to upstream are intentional and are not contract gaps: upstream's Donate links are not preserved.
- The Settings About tab presents this project, not upstream: repository links open both [FineTune-Rewrite](https://github.com/ph0ryn/FineTune-Rewrite) and the [original FineTune](https://github.com/ronitsingh10/FineTune), the license links open the bundled `LICENSE` and `THIRD_PARTY_NOTICES.txt` on GitHub, and the copyright line names this project's author.
- The product name is `FineTune-Rewrite` across user-facing surfaces (bundle display name, About tab, and app-referencing copy). The `finetune` URL scheme, bundle identifier, and executable name remain unchanged for compatibility.

## Mixer Presentation

- Volume sliders use a 4pt track and display a native mini thumb on hover or drag.
- Top and bottom chrome include the speaker/mic switcher, pencil/checkmark edit toggle, filled gear icon, and bottom `Quit ⌘Q` control.
- Device rows switch the default device when clicking non-control areas of the row, including the gap after the name and vertical padding. Mute, volume, and percentage input do not trigger row switching, and re-selecting an already-default row does not rewrite the default.
- The selection badge uses the upstream 28pt circular accent-color gradient with a white glyph when selected, and monochrome styling when unselected. Selection follows the OS-observed default, while keeping the existing checkmark. Do not show optimistic pre-click states or in-flight switching indicators.
- Priority-edit rows show only a drag handle, the device icon, the full device name, a compact `DEFAULT` pill for the observed default, a visibility toggle disabled for the default, and an info action. No numeric position is displayed or typed. While dragging, passing over another row swaps the dragged row with that row immediately; the order reached this way is committed once when the drag ends. The drag source advertises move only and the drop target proposes move, so no copy `+` cursor appears; the preview shows the device name. This intentionally differs from upstream's editable position and drop-time move. Volume, mute, percentage, selection badge, and checkmark stay out of edit rows so names remain visible and trailing controls align across rows.
- Preserve volume bindings, unknown/read-only displays, shared commands, existing `⌘Q` behavior, and non-scrolling display of all rows.
- Keep mute dimming separate from native idle opacity so combined opacity never drops below the hit-test threshold and disables volume interaction.
- App rows are 40pt tall (28pt header with 6pt vertical and 8pt horizontal padding), laying out VU meter, 24pt app icon, name, mute button, shared 140pt slider, 40pt percentage field, boost chevrons, output route icon, and EQ icon on a single line.
- Attach no actions to the app name or row padding; only an active app's icon invokes the existing activate action. Dim decorations for inactive apps without lowering ancestor opacity on the slider so volume control remains interactive.
- Row backgrounds are transparent by default and use the shared hover surface on hover, focus, or when the EQ panel is expanded. Internal EQ panel interactions remain unchanged.
- The output route picker uses a 28pt icon trigger and a 210pt menu with Single/Multi mode and check/checkbox indicators. Delegate outside-click dismissal and popover window ownership to native SwiftUI. Hold no optimistic mode or UID state; selection reflects observed values.
- Do not show a subtitle for standard follow-default routing; render a 9pt subtitle only for explicit routes or multi-output summaries. Do not hide `Unavailable` indicators for missing device UIDs, explicit `routeStatus`, or the distinction between missing observed levels and measured zero.
- The app section uses an `APPS` header, 0pt row spacing in normal mode, a 2-column grid with 4pt spacing in edit mode, a separate Ignored grid, and a centered empty state.
- Base ordering is pinned active → pinned inactive → unpinned active, sorted within each group by locale-aware case-insensitive name with persistent ID as tiebreaker. Unpinned inactive metadata (shown only in edit mode) and ignored apps remain in separate trailing groups.
- Visual order and keyboard navigation follow the same projection order. Do not alter saved pin/ignore values or route ownership.
- The transient keyboard-selection highlight exists only while keyboard navigation is engaged: pointer activity inside the popup yields it, and closing the popup clears it so the next open starts without a selection or percentage draft.
- Restoring gain to `1.0` on clicking `0%`, and fallback values for missing device properties are outside this contract. Pixel-for-pixel parity across the entire Mixer is not guaranteed.

## Settings Presentation

- Settings exposes General, Audio, Shortcuts, Updates, and About as plain text tabs in normal window content below the title bar. The selected tab is indicated by text weight, color, and a small underline; no grouped tab plate, tab icons, or title-bar overlap is used.
- Only the selected settings tab is constructed. Switching tabs must not instantiate inactive controls, and shortcut recorders exist only while Shortcuts is selected.
- Settings sections use the native window background, spacing, and native controls without grouped card fills or decorative section chrome.
- Peak-level-only audio updates must not invalidate Settings. Settings observes route lifecycle and failure diagnostics, while Mixer alone observes the high-frequency meter values.

## Device Switching and Failure Recovery

- When an explicit output device selection succeeds, retry failed routes for apps following the default output. Do not expand retries to input selection, failed default writes, or apps with pinned explicit routes.
- Route targets use the policy-approved UID rather than reacquiring the old default while waiting for asynchronous OS observation. Keep observed default UID separate from the policy-approved target, and do not force-rebuild existing healthy app routes during passive corrections. Explicit `Retry Audio` extends the same recovery as a device switch to all apps, including rebuilding locally healthy routes (temporary audio interruption is acceptable).
- Do not retry failed capture solely on passive device or process notifications. Known permission denials remain active until an explicit `Retry Audio`.
- For 2 seconds immediately following a successful explicit selection from FineTune, perform at most one corrective rewrite if the output reverts to another Bluetooth device, provided the healthy UID and Bluetooth topology have not changed. Do not extend this window on correction or confirmation notifications; invalidate stale correction authority on any new explicit action, topology or observation-health change, or suspend.
- Because OS notifications do not identify the actor, Bluetooth selections made from Control Center during this window cannot be distinguished. A re-selection from FineTune is always treated as the latest action.
- Respect new external selections after the window expires, and never revert them due to a pending confirmation or timeout from an older write. Unresolved failures do not clear merely from elapsed time or duplicate notifications for the same UID.
- If selection still cannot be maintained after correction or confirmation times out, stop rewriting and surface the failure in Mixer and Settings. Clear it only upon healthy observation of the requested target or a new selection.
- This mechanism is not permanent Bluetooth ownership locking. Real-hardware correction effectiveness and audible continuity are outside this contract and subject to separate verification ([verification policy](verification.md)).

### Limit Observed Default Rewrites to Once per Connection Episode

- Limit rewrites of the observed default to at most once per event: connection batch start, disconnect fallback, explicit selection, or settings change. Accept transients reapplied by the OS within the same connection episode (including ear-detection transients) without writing back.
- Apply input lock on the same triggers only. Respect input changes made in Settings, diverging from the upstream behavior where input lock overrides Settings changes.
- Preserve priority behavior (one-time switch on higher-priority device connection, fallback to next-highest on disconnect).
- Do not perform upstream's echo-timeout rewrite (retrying when write confirmation does not return).

## Route Handoff, Cancellation, and Failure Reporting

- Never keep a cancelled route alive for continued use with its callback intake closed. Because cancellation does not by itself stop OS IO or clear source mute, retain ownership until actual termination is confirmed, and begin reclamation without waiting for the next route to become ready.
- Never run duplicate in-flight or pending-reclamation work. Do not commit a new route until termination of the old route is confirmed.
- Explicit capture Retry forces re-preparation of all app routes and retries completed reclamation failures as well as failures that never returned a prepared handle. Because locally healthy routes are also re-established, brief audio interruption is acceptable. A successful retry must not re-emit historical cleanup failures as current failures; if the same failure recurs, keep displaying it and blocking commit.
- Keep known primary failures of old routes in diagnostic history after reclamation. Do not treat a successful reclamation as a failure that blocks committing a new route. Distinguish late `cancelled` records arriving after teardown starts from reclamation failures. Treat `cancelled` on an active route that was not told to stop as a failure, but do not let a late `cancelled` update from an old route create or overwrite current failure displays.
- Maintain diagnostics per app. They must not clear merely because another app succeeded, an old route began reclamation, or a new route started preparing. Clear an app's failure only after that app commits and all requested routes are healthy; success on one output in a multi-output configuration must not hide a fault on another remaining output.
- Mixer and Settings separate diagnostic history from active warnings. Display failures for active apps desiring processing until those apps recover. Do not warn about past route failures after stop, app exit, or Ignore, while preserving diagnostic history.
- Show failures belonging to visible Mixer apps only on their normal-mode row; do not duplicate them in the top banner. Hide per-row warnings during reorder/edit mode and display current state again upon returning to normal mode.
- Present permission denials with shared guidance without hiding independent failures such as persistence or device operation errors.
- Determine cleanup warnings by whether resources are still owned, not by generation age. Keep showing incomplete reclamations and reclamations of routes that failed before returning a prepared handle even after stop or when no app row is present. Clear a warning only after confirmed termination or successful resource release; never clear it due to another route succeeding or a new preparation starting.
- Keep the latest diagnostic as history and track unresolved cleanups per route. An empty unresolved set does not prove all resources have been reclaimed.
- Physical and aggregate outputs require channels 1 and 2. Reject extra inputs, non-contiguous channel numbers, and mismatched format or buffer configurations.

## Quit

- Route the Quit button, `⌘Q`, and the application menu item through the same termination path.
- On termination notification, synchronously stop input monitoring, dismiss the HUD, and flush settings. Do not add custom delayed termination, asynchronous audio reclamation waits, or retry/cancel dialogs on save failure.
- Record save failures in the store without cancelling termination. Rely on OS reclamation of audio resources at process exit, without changing the normal cooperative-stop contract.
- Behavior during active live audio shutdown or on the minimum supported OS version is not guaranteed by this contract ([verification policy](verification.md)).

## Persisted Settings

- Newly created settings use version 12; decode missing or `null` version fields as version 9. Do not reject unknown integer versions during migration.
- Distinguish missing/`null` fields from type mismatches. Preserve defaults for known keys, gain normalization, and enum decoding semantics.
- Define CRUD, direct bindings, debounce, explicit flush, reset, and preset name validation by their persisted results and observable side effects.
- Keep the login service injectable, and never register a real login item merely by loading settings.
- Back up corrupted JSON before resuming. If backup itself fails, suppress writes for that manager and surface observable load/save errors.
- Require an explicit storage directory argument. Never implicitly open the upstream Application Support namespace; importing upstream settings must be an explicit user-initiated action.

## System Alert Mute Synchronization

This is an intentional behavior not present upstream. Rationale and upstream comparison are recorded in [research notes](research.md).

- Set the OS alert volume to `0` only while the System Sounds output device is muted via the software tier.
- Restore the pre-mute alert volume when unmuted. Do nothing for hardware/DDC tier mutes or mutes on devices not serving System Sounds.
- Restore synchronously on termination notification. Check any persisted restore value on next launch before evaluating current mute state so races between termination and restore do not leave mismatched values.
- Store the restore value exclusively in the `alertVolumeBeforeMuteSilencing` schema field, separate from the app's `Alert Volume` setting. Disable the `Alert Volume` control in Settings while silencing is active.

## URL Scheme and External Control

- `finetune://` actions, query parameter ordering, validation, and persistence targets follow the pinned upstream revision.
- Parsing, shared Control operations, and App event/bundle registration are distinct guarantees; a passing parser does not by itself verify full product integration.
- Where the upstream guide and implementation disagree on percentage representation, follow the upstream implementation; proposed changes are tracked as deferred items in [research notes](research.md).
