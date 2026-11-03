# DSP compatibility and validation record

## Scope and provenance

The comparison revision is `ronitsingh10/FineTune@2285279d36d3f8115c1c2d4aecd904f1bdf96a51`.
The original GPLv3 test sources remain unchanged in the pinned checkout. The four derived
Swift test files retain their upstream header comments and GPLv3 provenance. Production
C++/C/Swift code and the independent C++ boundary scenarios are newly authored; no upstream
production implementation was copied.

The inventory owner records the original file/body/assertion hashes in
[the census](<../../.indexion/cache/upstreamTestInventory.json>). This scope contains
97 upstream declarations / 138 statically expanded invocations before the explicit
nonportable substitutions below. That count is not an execution result.

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
- Production C++/Native/Platform/App and the DSPTests executable compile/link through
  the central integration gate. Its [numeric debug JSON](<../../.indexion/cache/integrationBuild/numeric-debug.jsonl>)
  was independently grouped by the seven DSP source files: all 152 function declarations
  ended, including 242 expanded invocations, with zero recorded issues. This means
  149 portable-original declarations plus three explicit C-to-D substitutions, not
  152 unchanged-upstream passes. It is a scoped debug unit result, not a full-root,
  release or hardware-validation claim.
- Hardware audio, concurrent handoff and long-duration performance are not validated
  by these deterministic tests.

## Dynamics scope

The additional three upstream files contain 55 declarations / 104 statically expanded
invocations. [LoudnessEqualizerTests](<../../Tests/UpstreamCompatibilityTests/LoudnessEqualizerTests.swift>),
[ISO226ContoursTests](<../../Tests/UpstreamCompatibilityTests/ISO226ContoursTests.swift>) and
[SoftLimiterAdversarialTests](<../../Tests/UpstreamCompatibilityTests/SoftLimiterAdversarialTests.swift>)
are byte-identical copies, with no input, expectation, parameter-vector or tolerance edits.
Together with the Biquad scope this accounts for 152 original declarations / 242 static
invocations: 149 portable original declarations plus the three explicitly classified
processor-internal substitutions, not an unqualified claim of 152 unchanged originals.

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
