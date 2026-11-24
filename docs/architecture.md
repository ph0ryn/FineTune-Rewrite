# FineTune-Rewrite Architecture

## Scope

This document covers module structure, responsibilities, dependencies, and runtime ownership. Observable contracts live in the [specification](spec.md), test targets and acceptance criteria in the [verification policy](verification.md), and build/workflow steps in the [development guide](development.md).

## Responsibility and Dependency Boundaries

| Boundary | Responsibilities | Excluded Responsibilities / Dependencies |
| --- | --- | --- |
| `App` | SwiftUI/AppKit presentation, input intake, and dependency composition | UI-specific routing logic or volume interpretation |
| `FineTuneDomain` | OS-independent values, identifiers, volume semantics, and route selection rules | OS, UI, native implementations, and raw OS handles |
| `FineTuneControl` | Command intake, state updates, change planning, request generation tracking, external operation protocols | Concrete device manipulation, storage mechanisms, Platform implementations |
| `FineTunePlatform` | macOS observation, explicit-directory persistence, device control, adapters to native implementation | A monolithic manager orchestrating all adapter responsibilities |
| `NativeAudio` | Taps, aggregates, IOProcs, audio route execution, swapping, and resource management | Product-level policy decisions such as output priority |
| `AudioDSP` | Audio signal processing math and filter state history | Core Audio device operations, Foundation, UI |

Code-level dependency directions are shown below. Concrete library declarations are authoritative in [Package.swift](<../Package.swift>).

```text
App              → FineTuneControl, FineTunePlatform
FineTuneControl  → FineTuneDomain
FineTunePlatform → FineTuneControl, FineTuneDomain, NativeAudio
NativeAudio      → AudioDSP
```

Control defines protocols for the operations it needs, Platform implements them, and App wires them together.
Avoiding dependencies from Control on concrete Platform implementations keeps control logic independent of macOS and real hardware.
Platform translates OS-specific data into Domain values and keeps device observation, persistence, DDC, and audio execution in separate adapters.

`NativeAudio` and `AudioDSP` are separated so device connectivity and resource lifetime issues can be verified independently from waveform math and processing state.
Aggregate and callback layouts are never assumptions in Domain, persisted settings, or UI, allowing the audio routing mechanism to change without altering the model of user intent.

## Language and Build Split

| Area | Language / Management Unit |
| --- | --- |
| UI, specification logic, control | Swift 6 |
| macOS integration | Primarily Swift; Objective-C++ only where native OS API bridging is required |
| Audio callbacks, DSP, audio resource lifetimes | C++20 |
| App bundle, main metadata, resources, signing/distribution config | Xcode app project |
| Library dependencies, tests, verification tools | Local Swift Package |

Dependency directions are enforced by build targets rather than directory layout alone, separating Swift and C-family targets to make ownership and dependencies explicit.
C++ is chosen to constrain the memory touched and work performed during audio callbacks; changing languages alone does not guarantee performance gains or bug elimination.

## Swift and Native Public Boundary

Expose a small C-style API at the boundary instead of leaking C++ types or ownership into Swift.

- Prefer opaque handles, fixed-width integers, plain structs, pointer-plus-count spans, and explicit status codes.
- Never expose C++ classes, STL containers, or Objective-C objects across the boundary, and never let C++ exceptions escape it.
- Keep `AudioDSP` C++ headers internal to the native implementation; do not expose them in Swift-facing public headers.
- Never retain pointers to transient Swift arrays or strings beyond the call; transfer or copy required data into native ownership during the call.
- Per-buffer audio processing flows from the HAL callback through `NativeAudio` and `AudioDSP` without crossing into Swift. Swift handles configuration changes and state queries only.

This section defines the boundary contract and does not prescribe individual API names or types.

## State Ownership and Control Paths

| State / Resource | Owning Boundary |
| --- | --- |
| User preferences, observed OS state, change-request generations | Swift Control |
| UI presentation snapshots | View model on `MainActor` |
| Creation, stopping, and destruction of taps, aggregates, and IOProcs | Non-real-time control path in `NativeAudio` |
| Precomputed configurations such as filter coefficients | Built on the non-real-time side and published to the real-time side |
| Filter history, ramps, and limiter internal state | The callback executing that route |
| Level meters, callback counts, and applied generation | Recorded on the real-time side and read by the non-real-time side |

Keep persisted user intent, observed OS state, and active execution routes separate.
Temporary fallbacks during device disconnects must not overwrite saved preferences so they can be restored on reconnect.
Distinguish persistent app identity from live processes and runtime OS objects.

Route UI, keyboard, and URL entry points through shared Control operations so no entry point writes to storage or mutates audio backends directly.
Do not conflate UI percentages, PCM gain multipliers, dB adjustments, and hardware device volumes; preserve the meaning of each persisted value.

## Product Composition

[ProductionRoot](<../App/Bootstrap/productionRoot.swift>) owns a single `SettingsManager`, device/process producer, device control model, input/output policy, and Native runtime, passing the same dependencies into [ApplicationGraph](<../App/Bootstrap/applicationGraph.swift>). The Engine and Controller share these observations, as well as the AutoEQ repository and cache.
Mixer and Settings reads/actions, keyboard input, and URL handling all connect to this same Control and store. Settings read closures reference the same presentation model rather than creating a second copy in Root.
Presentation snapshots are pure projections; Root must not hold a second route planner, settings collection, or download registry.

- **Intent vs. Observation:** The policy-approved UID used for follow-default routing is stored separately from the physically observed OS default UID.
- **Observation Health:** Explicitly track unstarted inventory, discovery failures, and independent input/output default-read failures. Never backfill a last-good UID as healthy-current. While unhealthy, suppress new route preparations and policy writes; usable existing routes may stay alive, but routes whose bindings are confirmed invalid by Native are closed and reclaimed.
- **Asynchronous Application:** Never freeze pre-prepare payloads until activation. After every `await`, re-check generation, binding, and follow-default target, and rebuild state from current settings at start/commit. Treat request acceptance, armed, commit, and first-applied as distinct observations.
- **Process Identity:** Shared-producer process revision matching and Native's Core Audio process-object-to-PID re-verification are separate paths. A matching revision alone does not guarantee the same live OS process.

Externally observable contracts are maintained in the [specification](spec.md).

### Lifecycle and Construction Side Effects

[LifecycleCoordinator](<../App/Bootstrap/lifecycleCoordinator.swift>) owns start/stop, sleep/wake, session state, and shutdown input stop/flush.
On termination notification from [ApplicationHost](<../App/Bootstrap/applicationHost.swift>), input monitoring stops and settings flush synchronously, and Root dismisses the HUD.
External termination contracts live in the [specification](spec.md). Treat OS process-exit reclamation separately from the Native reclamation results returned by normal stop.
One-shot observations re-register under the same generation while suspended, but run normal effects only while running.
On wake, ingest current default-read health and Engine observations first, rebase policy, and resume capture last.
Stopping input covers not only media keys but also unregistering global shortcuts and cancelling repeat tasks; retained Registry callbacks have no effect while suspended or stopped.
Generation-tagged observation callbacks in the coordinator reject stale generations after stop/restart. Foreign retained callbacks after Registry restart and OS queued key-up ordering are handled at the verification boundary in the [verification policy](verification.md).

The production Root constructor is not globally OS-inert: it performs settings disk load (including corrupt-file backup) and a non-prompting Accessibility trust query.
Profile repository/store constructors only store dependencies and validate URLs; disk restoration of local profiles happens when the service starts.
Unit tests with injected ports and real Root startup side effects are distinct verification targets, bounded in the [verification policy](verification.md).

Capture intent defaults to `false` for new or missing settings; a persisted `true` represents durable user intent. Control creates a new session and never reuses saved tokens.
Main executable usage descriptions and persisted intent are not OS permission grants; missing metadata fails closed before touching Native.
Distinguish main metadata across the SwiftPM App, Xcode App, and standalone Probe binaries.

## Route Transitions and Audio Resource Lifetimes

### Separate Preparation, Swap, and Reclamation

Apply required volume, correction, and format settings to a new route before activating it.
Track change-request generations and verify that a request is still current upon preparation completion and activation so stale async work never overwrites newer intent.
Do not assume an `actor` makes an entire asynchronous route transition atomic.
Distinguish request acceptance from actual application so failures and recovery outcomes remain observable.

A replacement route's `armed` state indicates transport readiness confirmed by an output callback with a certified buffer configuration and matching positive frame count.
It can succeed during normal idle when only the input data pointer is absent, but it is not proof of permission grant, audio capture success, or `first-applied`.
During idle, do not advance DSP history or applied revision; never arm on corrupted metadata, missing output, or zero frames.
This avoids tying teardown of the old physical output to whenever a silent source app next plays audio.

Closing callback intake on a cancelled candidate does not automatically stop OS IO or clear source mute.
Do not retain it as a read owner for continued playback; begin non-real-time reclamation without waiting for the next candidate to arm.
Notify Control of cancellation at most once per owner so late completion of old work does not stop monitoring of `PENDING` reclamation.
Resource release still waits for actual reader-zero and a retired ACK. Retain failed reclamation results with the owner and do not auto-retry them from subsequent handoffs.
Explicit capture Retry retries completed failed tasks retained by Control and forces re-preparation of all app routes. Share in-flight and `PENDING` reclamations, and never make an old owner renderable again.
Reclamation observations report that attempt's cleanup result separately from historical diagnostics in native snapshots. Recurring errors or current errors attached to a retired ACK remain failures.

Keep UI, persistence, and non-real-time resource management out of audio processing.
Creation, stopping, and destruction of taps and Objective-C object operations belong on the non-real-time side.
Separate ownership from reference completion so reclaiming an old route never destroys resources used by a new route.

### Keep Mutable DSP State per Execution Route

The logical processing unit is `app × output device`, keeping per-device correction and filter history independent.
Even when an old route and a new route overlap during a transition for the same app and device, do not share mutable state.
Distinguish sharing immutable settings/coefficients from sharing callback-mutated processing history.

### Separate Configuration Publication from Resource Reclamation

Publishing a ready configuration and being allowed to free an old configuration or route are distinct conditions.
Confirm that callbacks have finished referencing old state before reclaiming it on the non-real-time side; never rely on fixed sleeps or atomic pointer swaps alone as proof of reference completion.

Choose handoff primitives to match the callback topology and never share a queue across more readers than it supports.
Do not share a single-reader scheme directly across callbacks for multiple devices.
Verify callback-slot reference completion before reclaiming native-owned state on the non-real-time side.
The authoritative synchronization implementation lives in the [Native runtime](<../Sources/NativeAudio/Runtime/>); do not duplicate its APIs or full algorithms here.

### Native Routes and Reclamation Results

Each `app × output` route owns its tap, private aggregate, IOProc, and DSP resources.
Never mutate a private aggregate's tap drift or quality after creation; on every certification, read `Composition` back from the OS and verify a unique match with the owned tap UID, numeric types, and values. Do not substitute creation-time request dictionaries or defaults for observation. Require sub-tap drift compensation ON (`1`) with high quality across all transports, including Bluetooth/BLE, so Core Audio tracks Bluetooth adaptive-latency clock-rate ramps without corrupting tap input. See [research notes](research.md) for rationale.
Use `SubTapList` IDs for active-member identity checks without assuming child object properties are readable or observable. Observe the aggregate's `Composition`, tap/subtap lists, and underlying physical devices/streams, and re-verify before start.
Direct mutation of child drift/quality by external code in the same process is unsupported; there is no guarantee that child mutations emit parent `Composition` notifications.
Initial support is restricted to Float32 stereo at matching sample rates with an explicit channel/format certificate; do not hide unsupported devices behind implicit conversion.
For aggregate inputs containing only a single owned tap, distinguish the stream's device-property starting channel from IOProc buffer positions, matching contiguous stereo starting from a positive channel number against the actual buffer layout. Do not use the raw starting channel as a real-time offset or certificate invariant, while continuing to observe change notifications.
Keep strict validation for physical/aggregate output channels 1/2 and input ownership, layout, and matching sample rate; never shift sample pointers or buffer ordinals to match tap input channel numbers.
Mute the source app while tapping. Audible continuity verification is scoped in the [verification policy](verification.md).

`PENDING` reclamation re-checks actual reader and aggregate conditions on the existing 20ms poll. `FAILED` retains the owner, reports the failure, and halts automatic failure retries.
If stop, IOProc destruction, or aggregate destruction on an owned aggregate returns `!dev`, do not treat that alone as reclaimed; mark that device operation complete only when a separate presence query succeeds and confirms absence. Reclaim listeners and taps individually, retaining ownership on confirmation failure or any other cleanup error.
Elapsed 20ms intervals are not a safe-free timer. Never infer full private-pool drain or global zero-orphan state from one route's retired ACK or leftover historical diagnostics.
Normal OS and input observers stop on shutdown/stop, while the single factory's weak passive cleanup change notification stays connected to the presentation model.
The factory tracks latest historical diagnostics separately from per-route unresolved cleanups. The pool notifies completion only when native release succeeds for that owner, clearing that route's warning.
Explicit capture Retry also reaches failed owners moved into the pool without returning a prepared handle. Retries are scoped per factory and share in-flight reclamation. A new prepare waits until the target attempt reaches retired or `FAILED`, without treating that as full pool drain or capture permission.
Passive cleanup notifications never start new capture, route operations, or a duplicate Root timer, nor are they proof of permission or global reclamation completion.

Physical HAL sample-rate/channel-map behavior, permission revocation, sleep/wake, long-running stability, callback deadlines, and live audio correctness are outside automated gates and are scoped under bounded observation in the [verification policy](verification.md).
