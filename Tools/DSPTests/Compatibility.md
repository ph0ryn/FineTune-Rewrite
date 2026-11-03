# DSP compatibility and validation record

## Scope and provenance

The comparison revision is `ronitsingh10/FineTune@2285279d36d3f8115c1c2d4aecd904f1bdf96a51`.
The original GPLv3 test sources remain unchanged in the pinned checkout. The seven derived
Swift files and the translated [pure C++ numerical units](<LoudnessCompatibilityTests.cpp>)
retain GPLv3 provenance. Production C++/C/Swift code and the independent C++ boundary
scenarios/runner are newly authored MIT work; no upstream production implementation was
copied. Linking these units produces a mixed-origin test executable, not an all-MIT set of
independent tests. The [small test metadata header](<DSPTestUnits.hpp>) adds no product API.

The inventory owner records the original file/body/assertion hashes in
[the census](<../../.indexion/cache/upstreamTestInventory.json>). This scope contains
97 Biquad source declarations / 138 statically expanded invocations before the explicit
nonportable substitutions below; the additional dynamics scope is described later.
Those original-source counts are not execution results.

## Standard derivation

Coefficient calculations are independently expressed from the normalized transfer
functions in the [W3C Audio EQ Cookbook, 8 June 2021](<https://www.w3.org/TR/2021/NOTE-audio-eq-cookbook-20210608/#formulae>),
adapted there from Robert Bristow-Johnson. Peaking, low-shelf and high-shelf sections use
`A=10^(gainDB/40)`, `omega=2*pi*f/Fs`, `alpha=sin(omega)/(2*Q)`, and divide all five stored
coefficients by `a0`. The prewarp is the inverse/forward bilinear frequency substitution.
Runtime processing uses an independently written transposed direct-form-II recurrence
with two double accumulators for every section and channel.

Raw math retains the analytical frequency-zero boundary. Executable configuration is a
separate boundary and rejects non-finite/unstable coefficients using the second-order
Jury denominator conditions. Wrong graphic band counts and above-Nyquist batch bands
retain the explicitly tested upstream unity behavior.

## Portable adaptations

- Both math test files are copied byte-for-byte, including all inputs and tolerances.
- In the two signal files, six helper sites replace `vDSP_biquad_CreateSetup` and
  `swapSetup` with production `replaceCoefficients(coeffs, sectionCount:)`.
  The approved three boundary substitutions also import `NativeAudio` to name explicit
  result codes; this is the actual production boundary, not a test-only implementation.
  Coefficients are synchronously copied into native-owned fixed storage; no opaque
  legacy vDSP object or delayed-destruction imitation is introduced.
- Signal assertions, inputs, parameter arrays and tolerances otherwise remain unchanged,
  except for the three individually classified nonportable methods below.
- `setEnabled(false)` is bit-exact bypass and freezes history. Re-enabling resumes that
  instance's own history, preserving the portable disable/enable scenario.
- `configure`/coefficient replacement resets history. The upstream settled-response
  assertions do not depend on preserving an incompatible old setup's delays.

## Nonportable upstream methods and replacement boundaries

Lead approved these classifications and the new finite-signal contract on 2026-11-04 JST.
These are not reported as upstream tests passing unchanged or as upstream issue fixes.
The original files/methods remain auditable in the pinned checkout; there are no skip or
conditional-disable annotations in the derived runnable files.

| Original census method ID | Why not portable | New derived test method / independent boundary |
| --- | --- | --- |
| `FineTuneTests/BiquadProcessorSignalAdversarialTests.swift::NaNMidBufferTests.nanMidBufferNotCaughtBySafetyNet` | Explicitly requires vDSP NaN propagation to escape a check of only output samples 0/1. It tests an old detection-position limitation rather than the new processing boundary. | `NaNMidBufferTests.nonFiniteMidBufferReportsErrorAndMutesBlock`; C++ `validationAndRecovery`: same frame-500/mid-buffer invalid input reports an error and mutes the entire block. |
| `FineTuneTests/BiquadProcessorSignalAdversarialTests.swift::NaNMidBufferTests.nanPropagatesViaDelayStateToNextCall` | Explicitly requires poisoned vDSP delay storage to survive one call and silence the next clean call. The new boundary owns different, immediately reset state. | `NaNMidBufferTests.nonFiniteBlockResetsHistoryBeforeNextCleanBlock`; C++ `validationAndRecovery`: the very next clean block matches a fresh independent processor. |
| `FineTuneTests/BiquadProcessorSignalAdversarialTests.swift::ExtremeAmplitudeTests.infinityInputBypassesSafetyNet` | Requires the old isNaN-only detector to miss infinity and contaminate later frames. | `ExtremeAmplitudeTests.infinityInputReportsErrorAndMutesBlock`; C++ `validationAndRecovery` covers both infinity signs, bounded mute and clean recovery. |

Scalar `SoftLimiter` IEEE assertions are not part of these exclusions and must retain
upstream NaN/Infinity expectations in the dynamics scope.

## New ownership / realtime contract

- One processor instance belongs to one serialized execution path. A configuration-only
  copy initializes fresh history; copying mutable processor objects is disabled.
- Non-RT coefficient preparation/copy is separate from processing. Replacement and
  destruction require the owner to quiesce callbacks. No concurrent pointer publication
  or fixed-delay reclamation is claimed by this DSP layer.
- Fixed storage supports at most ten sections (graphic EQ / Domain AutoEQ maximum) and
  eight channels. Unsupported configurations fail explicitly; these bounds do not
  assert that any hardware format has been validated.
- The first sample sees the prepared filter. There is no startup fade, silence gate,
  lookahead or initial buffering; silence still advances genuine filter tails.
- RT processing uses no allocation, locks, exception, Foundation, Core Audio or Swift
  callback. Non-finite values are detected inside the ordinary processing loop, not in
  an extra normal-path full-buffer scan. Detection mutes that block, resets state and
  returns `FT_BIQUAD_NONFINITE_SIGNAL`.

## Red / Green evidence

- Initial standalone compile of the public boundary scenarios failed at link with the
  not-yet-implemented coefficient, processor and C ABI symbols (exit 1), before the
  corresponding implementations were written. Raw log is in the ignored local scratch.
- First standalone Green: C++20, `-Wall -Wextra -Werror -fno-exceptions -fno-rtti`;
  `DSP boundary scenarios: PASS (0 failures)`.
- Initial production Swift test build failed because the NativeAudio umbrella had not
  yet included its new Biquad header. This is an integration Red, not a signal result.
- ASan + UBSan Green: `-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer`
  with exceptions/RTTI disabled; boundary scenarios passed with zero sanitizer reports.
- Configuration-copy coverage verifies that a new route starts with fresh history,
  rejects mismatched channel counts and survives destruction of the source owner.
  Six planar channels are checked against independent mono references.
- Mutation check: a scratch-only source variant replaced per-channel filter delays
  with shared channel-0 delays. The unchanged boundary executable failed (exit 1),
  detecting one-sided-channel corruption and planar history sharing.
- The pre-refactor central gate compiled/linked C++/Native/Platform/App and DSPTests.
  Its [baseline numeric JSON](<../../.indexion/cache/integrationBuild/numeric-debug.jsonl>)
  was independently grouped by seven DSP files: 152 declarations / 242 invocations,
  issue0. The reviewed DSP source checkpoint is `ff7800b755e96e9862e84b19562e67ee13c336bc`.
  This means 149 portable-original declarations plus three explicit C-to-D substitutions,
  not 152 unchanged-upstream passes. It is baseline evidence, not execution proof for
  the later C++ unit migration, a full-root/release result or hardware validation.
- Hardware audio, concurrent handoff and long-duration performance are not validated
  by these deterministic tests.

## Dynamics scope

The additional three upstream files contain 55 declarations / 104 statically expanded
invocations. [ISO226ContoursTests](<../../Tests/UpstreamCompatibilityTests/ISO226ContoursTests.swift>)
and [SoftLimiterAdversarialTests](<../../Tests/UpstreamCompatibilityTests/SoftLimiterAdversarialTests.swift>)
remain byte-identical. [The equalizer Swift file](<../../Tests/UpstreamCompatibilityTests/LoudnessEqualizerTests.swift>)
now retains settings defaults and three outer units; eleven pure numerical source scenarios
run as fifteen named [C++ rows](<LoudnessCompatibilityTests.cpp>) against the same real kernels.
Inputs, expectations, parameter vectors and tolerances are retained; no legacy helper API
or alternate numerical implementation is used. Full-file identity is no longer claimed
for the adapted equalizer file. [The exact mapping](<adaptations.json>) records each source
ID, destination row, input and tolerance.

With Biquad, the original census still covers 152 declarations / 242 static invocations:
149 portable source guarantees plus three explicitly classified substitutions. The current
static destination layout is 141 Swift declarations / 227 invocations plus eleven source
scenarios / fifteen C++ rows, not 152 unchanged Swift tests. Fresh runtime evidence is
checked per language rather than adding incompatible declaration and row counts.

The scalar limiter is independently derived as the odd-symmetric rational continuation
`threshold + headroom * overshoot / (overshoot + headroom)`. It joins the identity with
unit slope and approaches the ceiling without overflowing for the largest finite
Float32. NaN/Infinity scalar behavior remains IEEE, as required by the portable tests.

Loudness analysis owns its ring allocation at construction on the control path. The
callback only advances preallocated power samples, K-weighting delays, hop/envelope
state and a shared per-frame gain. Channel powers are combined without summing the
waveforms, so opposite-phase channels do not cancel the detector. The K-weighting
approximation is tested by the upstream frequency-response tolerances; passing them
is not an exact BS.1770 certification claim. Configuration clones copy settings only,
never analysis windows or gain/filter history.

### ISO numerical data and approximation provenance

The [official ISO page](<https://www.iso.org/standard/83117.html>) confirms ISO 226:2023,
third edition, and the 20 Hz–12.5 kHz reference range. Its JavaScript
[OBP preview](<https://www.iso.org/obp/ui/en/#iso:std:iso:226:ed-3:v1:en>) did not expose
the full table/formula in the fetched text. Full-table independent verification against
the paid standard is therefore **not claimed**.

The row-oriented numerical table is transcribed as mathematical reference facts from
the pinned compatibility source, with its critical values independently asserted by
the unchanged upstream tests. No upstream production function bodies were copied.
The contour equation is independently expressed from the cited ISO Formula (1), with
normalization around the 1 kHz reference handled separately.

The four-section approximation is newly designed: low shelves at 55/250 Hz, a 3.5 kHz
peaking section and a 9 kHz high shelf. A fixed-size, damped four-variable Gauss-Newton
solve fits gains off the realtime path over 96 log-spaced frequencies. This is not a
translation of upstream fitting code. An independent prototype measured worst error
1.38–1.80 dB and all-band RMS 0.54–0.78 dB for low/mid volume at 48/96 kHz; the unchanged
upstream gate specifically requires worst error <=3 dB and low-frequency RMS <=2 dB
at 3% system volume / 48 kHz.

A separate Dynamics Red failed at link for the not-yet-implemented contour, detector
and equalizer symbols before their implementation. The full standalone Biquad +
Dynamics executable subsequently passed with exceptions/RTTI disabled and under
ASan+UBSan, with no reports. Both public headers also pass strict C11 syntax checking;
owned C++ and production Swift files pass their target format/lint checks.

## Direct numerical unit migration and named reporting

Task-31 removes only product-unused numerical helper surfaces: 17 C functions, three
opaque helper types and five Swift helper types. All twenty retained C ABI signatures,
outer equalizer/compensator Swift APIs, Pipeline code, native DSP algorithms/headers and
ISO data remain unchanged relative to the reviewed checkpoint. Four retained Swift unit
bodies are byte-identical; their new runtime execution is a separate integration gate.
No new product abstraction or test framework was introduced. The shared waveform/RMS
helper serves both response bounds and monotonicity without duplicating signal generation.

The [runner](<main.cpp>) accepts `DSPTests --report path.json`. Schema1 contains
`complete` and named `cases` with stable `id`, `status` and `invocations:1`. A fresh
`complete:false` report is written before execution; `complete:true` appears only after
all units finish. Failed rows include the first actual/expected measurement, with explicit
NaN/Infinity strings and null for unknown legacy boolean measurements. Case failure,
unknown/missing CLI arguments or report I/O failure all return nonzero. Auditing requires
fresh source-matched output plus process exit, not a leftover JSON file alone.

Migration evidence, distinct from the baseline snapshot:

- Red: the old runner's numeric scenarios passed but it produced no required named report
  for `--report`; [the assertion failed as intended](<.build/task31-red.log>).
- Green: C++20/macOS15.4, exceptions/RTTI disabled, full Native/Pipeline linkage and
  ASan+UBSan passed all fifteen derived rows and eight independent groups with no reports.
  [The 23-row JSON](<.build/task31-green.json>) was checked for exact IDs, unique rows,
  completion, passed status and invocation1. [The run log](<.build/task31-green.log>) retains
  human names. No-argument execution also passed; unknown flag, missing report path and
  a directory used as report target each returned exit1 without fallback.
- Sensitivity: an in-memory kernel copy neutralized only K-weighting's +4dB pre-emphasis.
  The unchanged suite detected four failed rows (2/4/10kHz response and monotonic boost),
  emitted [a completed failing report with measurements](<.build/task31-mutation.json>)
  and [exited1](<.build/task31-mutation.log>). Production source was not mutated.
- Scoped unwrap dry-run found no candidates before/after. The post-edit 90% duplicate
  scan of the two test translation units found zero similar pairs/function duplicates.
  These diagnostics supplement consumer review; legitimate FFI/platform adapters remain.

Central product-scope [Debug](<../../.indexion/cache/integrationBuild/test-dsp-results-debug.json>)
and [Release](<../../.indexion/cache/integrationBuild/test-dsp-results-release.json>) both
exited0. The reviewer independently checked exact source-mapped fifteen derived plus D8,
23 unique passed rows, invocation1 and complete schema1. This is current C++ product proof,
not the old 152-test snapshot. [The independent supplement](<../../.indexion/cache/dsp31IndependentReview.md>)
approves exact source mapping, unchanged outer bodies and separate fresh sanitizer/reporter
negative controls, including NaN/Infinity/null values and stale-success overwrite on abrupt exit.

The four retained Swift units also passed independently in Debug and Release against actual
production Domain/Platform sources and freshly compiled current native C++/C ABI. The small
[recipe](<.build/task31-retained-swift.py>), [proof with19 before/after hashes](<.build/task31-retained-swift/proof.json>),
[Debug log](<.build/task31-retained-swift/debug/run.log>) and
[Release log](<.build/task31-retained-swift/release/run.log>) record import-only test adaptation
with inverse byte equality. Production source is not copied, no behavior is stubbed, and no
App/root build is claimed. Initial missing Testing framework/plugin flags were corrected in
the leaf recipe; their setup logs remain archived, and no test/expectation was skipped.

These close task31's scoped boundary guarantee: eleven moved source scenarios/fifteen C++
rows plus the four retained Swift scenarios. The broader Swift141/227 and final whole-root
execution remain integration's later gates, not prerequisites for native consumer work.
Hardware, permissions, HAL stop/concurrency and callback latency remain outside this proof.
