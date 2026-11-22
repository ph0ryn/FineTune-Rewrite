# Verification Policy

This document defines how artifact correctness is judged. The contracts under test live in the [specification](spec.md) and execution procedures live in the [development guide](development.md); this document covers invariants, evaluation criteria, test scope, and known limits only.

**Unit/component passes, product consumer wiring, live hardware audio, and distributability are distinct verdicts.** Never reinterpret a pass in one category as a pass in another.

## Scope of Guarantees

### Test Pyramid

**Pure unit tests.** Require no external I/O and assert outputs directly from inputs.

- Domain: volume units, slider mapping, identifiers, setting values, EQ models
- Control: volume/mute/boost, target selection, separation of saved intent from observed/active state, change planning
- UI: pure tokens, display values, icon selection, focus/scroll calculations
- DSP: math, coefficients, detectors, gain/smoothing; verify internal kernels directly in C++ without expanding test-only Swift/C ABI surface

**Small component/contract tests.** Focused on catching miswiring across new boundaries.

- Persistence, flush, debounce, and backup failure using temporary directories and an injected login service
- Wiring from real App operations, monitors, and registries into Control, store, and device ports
- Offscreen AppKit views/windows and event-poster seams (importing AppKit does not make a test E2E)
- OS adapter selection, failure, and reclamation contracts using injected property readers, device capabilities, notifications, clocks, and tap installers
- Production native C ABI, ownership/lifetimes, route/channel independence, and synthetic signals

Do not expand these into full-app launches or real-hardware tests. Observe public outputs, persisted results, and semantic calls passed to ports rather than brittle mocks locking private call sequences. See the [architecture](architecture.md) for structure and ownership boundaries.

#### Oracles for UI Presentation Leaves

Copy, formatting, and static presentation mappings are verified in `AppPresentationContractTests` against production semantic projections without creating views, windows, or bitmaps. Coverage includes Settings tabs, Mixer header/footer, route menu, keyboard/AutoEQ bindings, and device row actions. This verifies semantic values only; it does not prove glyph visibility or live control wiring.

Verification involving real AppKit rendering is consolidated in `AppRenderedTests`. Production views are rendered into an offscreen `NSHostingView` to check configured `NSWindow` sizes, native bridges (`NSSwitch`, `NSSegmentedControl`, `NSButton`), rendered SwiftUI button bounds, and status-item actions. Do not use OCR, pixel probes, ScreenCaptureKit, pointer event loops, or private SwiftUI proxies ([renderedTestSupport.swift](<../Tests/AppRenderedTests/renderedTestSupport.swift>)). Because Vision text recognition is environment-dependent, it is not an automated gate oracle; selection badge fills/glyphs and slider track dimensions are verified via semantic projections. Whole-bitmap equality and rendered pixels are not guaranteed.

Status-item tests temporarily add an item to `NSStatusBar.system` to verify real `NSStatusItem` discovery and owned actions, removing it in `defer`. They do not open popovers or post OS mouse events.

Non-rendering routing, Root, and policy suites live in `AppCompositionTests` and share routing fixtures via `AppTestSupport`. Both bundles reference the product App module (`FineTune`) and may link AppKit/SwiftUI, with the boundary being that tests themselves do not execute rendering paths.

Visual regression checks stay outside automated gates via representative screenshots and human review. No claims are made about improved render time or screenshot capture reliability.

### Bounded Hardware Observation

Run hardware observation only when validating permission-, hardware-, or OS-specific hypotheses, with explicit targets and safety conditions defined upfront. Never require real hardware, audio recording, or permission grants for standard CI unit/component gates, and never fold optional hardware/E2E evidence into unit pass counts.

Having an implementation in place is separate from proving that aggregate/channel support, switching, first-audio onset, and idle recovery are adequate on real hardware. Physical HAL sample rates/channel maps, permission revocation, sleep/wake, long-running stability, callback deadlines, and live audio correctness are outside automated gates and belong to bounded observation. See "Safety Conditions for Live Audio Verification" for per-hypothesis checks.

## Gate Evaluation Principles

- Any non-zero exit code from a runner is a failure; never mask it with aggregate pass counts or stale reports.
- One parameterized declaration and multiple executed rows are distinct; never mix declaration counts with execution counts.
- Never sum Swift and C++ pass counts into a single combined pass total.
- Never use upstream static invocation counts as a fixed target, nor use total-count comparisons that hide missing coverage.
- Re-run tests in the same configuration after any source change; prior results are not evidence for the current tree.
- Compare results only within the same configuration; debug vs. release and local vs. CI differ, so passes from another OS or configuration do not substitute as evidence.
- The existence of a CI workflow is not evidence that CI passed.

## DSP and Native Boundary

The [offline DSP executable](<../Tools/DSPTests/main.cpp>) runs production implementations against synthetic signals to verify:

- First-audio onset, short single-channel impulses, filter tails in silence, and resume after silence
- Bit-equivalent results across arbitrary buffer splits and independent per-route/per-channel history
- Bypass/re-enable, configuration swaps, and explicit errors plus recovery for invalid configs and non-finite signals
- C buffer contracts, native-owned coefficients, post-stop reclamation assumptions, and C++ heap allocation detection

Upstream scenarios migrated to named C++ units are mapped via separate native machine reports rather than Swift test reports. Do not judge a removed Swift method as missing coverage without reviewing inputs, tolerances, and execution results of the replacement unit.

Run multiple configurations (debug, release, sanitizers) as separate pieces of evidence; passing in one configuration does not prove another. See [Compatibility.md](<../Tools/DSPTests/Compatibility.md>) for formula provenance and verification limits.

Allocation checks cover only ordinary/aligned C++ `new`/`delete` measured during Stage/HAL callbacks and owned fake OS resource counters. Do not backfill unexposed counters in other suites as zero, and do not claim the absence of all C `malloc`/`free` or CF/OS allocations. Passing allocation checks or ASan/UBSan does not prove real-hardware callback deadlines, lock/wait freedom, ARC behavior, all concurrent handoffs, or PAC safety. Do not reinterpret stop/quiescent ownership contracts as live-swap safety.

## Safety Conditions for Live Audio Verification

Before running live audio checks, explicitly state the source app, output device, volume ceiling, start/stop steps, whether recordings are saved, and failure recovery. Never capture or play audio or modify system volume, default devices, or permissions without user consent. Keep these observations outside standard gates.

Verify hypotheses separately as needed:

- `1 app → 1 output` start/stop, plus silence and resource reclamation on partial failure
- Format, sample rate, channel map, aggregate handling, default switching, and disconnect/reconnect
- First-audio onset, short sounds after idle, long-running sessions, sleep/wake, and permission revocation/restoration
- Per-backend volume/mute and persistence/restore across software, hardware, DDC, and Bluetooth

### AudioProbe Operational Scope

[AudioProbe](<../Tools/AudioProbe/main.swift>) is a consumer of the same production Native layer, not a test-only audio implementation. Invocation commands live in the [development guide](development.md); this section defines observation scope and safety constraints.

`--help` and invalid-argument handling run before constructing the producer. No arguments and `--list` perform read-only discovery of real devices/processes, and `--describe` reads metadata for a specified output. None of these capture audio, though they remain distinct from OS-inert unit tests. `--capture` requires explicit `--app`, `--process-revision`, `--output`, and `--seconds`, binding to the current app/process. Duration is bounded to `(0, 30]` seconds with an overall deadline including preparation, plus up to 2 additional seconds for cleanup wait. Never treat blocked OS calls or `PENDING` reclamation as safely released. The source app is muted while tapped, EQ/AutoEQ/loudness are disabled, and `--gain` is in `0…1` (default unity). Never skip volume safety checks. Main usage descriptions, `armed`, and `first-applied` do not prove OS permission grants; inspect diagnostics and exit status on failure.

This is a pre-authorized bounded observation tool and must not be turned into a requirement for large per-feature E2E tests.

### Route Invalidation Diagnostics

`bindingChanged / certifyFormat / -5101` is a local route-invalidation code and does not represent an individual HAL error or property selector. `resolveOutput` rejections likewise return condition-specific local codes rather than HAL `OSStatus` values (`-5110` identity, `-5111` input channels, `-5112` aggregate, `-5113` stereo order, `-5114` layout, `-5115` sample-rate disagreement). All remain `unsupported` while distinguishing conditions. UI surfaces condition-specific explanations rather than masking causes behind a generic "unsupported format" message. Rate disagreement can occur transiently while a device transitions formats; this distinction exists to preserve root-cause visibility after state settles, not to decide retry policy.

Native retains only the first event that wins the recording slot upon invalidation. It distinguishes property notifications (object, count, first address) from IO callbacks (device, input layout, output layout, missing output data, frame mismatch). This record is not a complete event timeline or root-cause proof and does not relax existing certification requirements. Never infer or backfill reasons from normal idle, DSP errors, or pre-invalidation state.

When launched with `FINETUNE_AUDIO_DIAGNOSTICS=1`, the Swift non-real-time layer logs this record to the existing `AudioRoute` log. Audio samples, buffer pointers, and property arrays are never recorded, and no logging or HAL calls occur inside callbacks. The [production C boundary and fake-HAL tests](<../Tests/NativeHALContractTests/main.cpp>) verify reason differentiation, concurrent notifications, post-reader-zero history, and late callbacks, but do not prove reproduction of real-world invalidation causes. Before restarting or capturing on real hardware, confirm target app, output, duration, volume, and restore conditions.

## Product Composition and Distribution

Composition tests use real Graph, presentation model, Host, lifecycle, and external ports to verify shared wiring into Control, store, and Native. Observation health, default policy, post-`await` latest payloads, early URLs, input stop, repeat cancellation, and stop/flush are verified via public outcomes. Quit synchronously stops input, dismisses the HUD, and flushes settings on termination notification without making async audio reclamation a termination condition. Component tests verify Host's public delegate capabilities alongside input stop and persistence results.

Zero calls on a fake port do not prove that real Root startup is globally OS-inert. Refer to the [architecture](architecture.md) for Root constructor side effects, capture intent, main metadata handling, and plist separation; this document defines only the verification boundaries.

Distribution verifies target OS/architecture, entitlements, usage descriptions, bundle identity, signing, notarization, and update/uninstall separately. Importing upstream user settings must be an explicit user action; test runs must never migrate or modify real user settings.

## Guarantee Mapping

Upstream guarantee scenarios map many-to-many onto new unit and component tests. When a unit test suffices, do not inflate it to E2E; splitting, merging, and fixture replacement are allowed as long as the guarantee holds. Never manufacture passes by unjustified deletion, input reduction, loosened tolerances, skips, or hiding known issues.

The mapping is as follows (see [architecture](architecture.md) for structural details):

- Split copy, formatting, and static presentation mapping into `AppPresentationContractTests`; real AppKit structure, geometry, and native bridges into `AppRenderedTests`; and non-rendering wiring into `AppCompositionTests`. Avoid OCR and pixel probes (see above) and make no claims about render speed or screenshot reliability.
- Verify physical default output/input policy contracts in `ControlTests` with injected clock and writer ports, including deadline-bounded guarantees and follow-default retries.
- Place shared test-only helpers in `AppTestSupport` rather than in product targets.
- Use registration counts, events, and task completion—never fixed delays—as synchronization points for injected clocks and transports. On deadline expiry or cancellation, cancel the task, release fixtures, and verify termination within a bounded timeout; never treat a task that outlives fixture release as passing.
