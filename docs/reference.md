# Reference

All pinned upstream URLs below reference the same comparison revision tracked in the [specification](spec.md).

## Licensing and Provenance

Independently written code is licensed under the [MIT License](../LICENSE); components derived from upstream FineTune are licensed under `GPL-3.0-only`. Licensing is tracked at the component level in [THIRD_PARTY_NOTICES.txt](../App/Resources/THIRD_PARTY_NOTICES.txt) rather than per file. Per-file provenance can be traced through git history.

| Component | License |
| --- | --- |
| Profiles / AutoEQ | `GPL-3.0-only` |
| DeviceIcons | `GPL-3.0-only` |
| Mixer UI | `GPL-3.0-only` |
| Device observation | `GPL-3.0-only` |
| Tests / DSP | `GPL-3.0-only` |
| Other | MIT |

Upstream copyright notices and the GPL license text are consolidated in the bundled [THIRD_PARTY_NOTICES.txt](../App/Resources/THIRD_PARTY_NOTICES.txt). No legal claim is made regarding the copyrightability of feature vocabularies or rules themselves. External AutoEq INDEX/profile corpora are not bundled, and fetched data is not reclassified under the same license as the source code below. When distributing product binaries containing GPL-covered components, verify combined-work, corresponding-source, notice, and license-delivery obligations; isolating tests does not remove GPL obligations on product code.

### Upstream-Derived Product Code and Data (References)

| Product File | Referenced Boundary | Pinned Upstream Source |
| --- | --- | --- |
| [DeviceIconCatalog](../App/DeviceIcons/DeviceIconCatalog.swift) | 85 entries, ordering, category/keyword data | [DeviceIconCatalog](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Models/DeviceIconCatalog.swift) |
| [systemAudioDaemonCatalog](../Sources/FineTunePlatform/Devices/Observation/systemAudioDaemonCatalog.swift) | Bundle/name prefix vocabulary | [AudioProcessMonitor:20–58](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/Monitors/AudioProcessMonitor.swift#L20-L58) |
| [URLAutomationParser](../Sources/FineTuneControl/Automation/URLAutomationParser.swift) | URL grammar and value conversion rules | [URLHandler](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Utilities/URLHandler.swift) |
| [deviceDefaultEchoes](../Sources/FineTuneControl/Routing/deviceDefaultEchoes.swift) | Per-UID echo tokens, 2s expiry each, consumption rules | [EchoTracker:4–73](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/Engine/EchoTracker.swift#L4-L73) |
| [deviceBadge](../App/Design/deviceBadge.swift) | Selected 28pt accent-gradient badge and unselected monochrome circular badge | [DeviceBadge](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/Components/DeviceBadge.swift) |
| [mixerVolumeSlider](../App/Design/mixerVolumeSlider.swift) | 4pt track and native mini thumb on hover/drag | [LiquidGlassSlider](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/Components/LiquidGlassSlider.swift) |
| [mixerChrome](../App/Features/Mixer/mixerChrome.swift) | Icon header, tabs, and Quit capsule presentation | [MenuBarPopupView](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/MenuBarPopupView.swift), [ViewModifiers](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/DesignSystem/ViewModifiers.swift) |
| [mixerView](../App/Features/Mixer/mixerView.swift) | `APPS` section, 2-column edit grid, Ignored/empty views | [MenuBarPopupView](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/MenuBarPopupView.swift) |
| [mixerAppRow](../App/Features/Mixer/mixerAppRow.swift) | 40pt row, icon controls, boost chevrons, hover/expanded surface | [AppRow](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/Rows/AppRow.swift), [AppRowControls](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/Rows/AppRowControls.swift), [AppEditRow](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/Rows/AppEditRow.swift) |
| [mixerAppRoutePicker](../App/Features/Mixer/mixerAppRoutePicker.swift) | Icon trigger, route subtitle, Single/Multi/check/checkbox presentation | [DevicePicker](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/Components/DevicePicker.swift), [ModeToggle](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/Components/ModeToggle.swift) |
| [AutoEQCatalog](../Sources/FineTunePlatform/Profiles/AutoEQCatalog.swift) | INDEX parsing and search ranking | [AutoEQFetcher](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQFetcher.swift), [AutoEQProfileManager](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQProfileManager.swift) |
| [ParametricEQTextParser](../Sources/FineTunePlatform/Profiles/ParametricEQTextParser.swift) | APO grammar and filter rules | [AutoEQParser](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQParser.swift) |
| [AutoEQProfileRepository](../Sources/FineTunePlatform/Profiles/AutoEQProfileRepository.swift) | Fetch/cache/import behavior | [AutoEQFetcher](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQFetcher.swift), [AutoEQProfileManager](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQProfileManager.swift) |
| [ProfileFileStore](../Sources/FineTunePlatform/Profiles/ProfileFileStore.swift) | Cache file, schema, and mtime handling | [AutoEQProfileLoader](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQProfileLoader.swift), [AutoEQFetcher](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQFetcher.swift) |

## Audio Route Diagnostic Fields

When launched with `FINETUNE_AUDIO_DIAGNOSTICS=1`, route state, callback counts, applied revision, and output peaks from the existing native snapshot are emitted to the `AudioRoute` log (disabled by default). Audio samples, buffer pointers, and property arrays are never logged, and neither logging nor HAL calls run inside HAL callbacks. Timebase conversion setup and log emission occur on the non-real-time side. Output UIDs and app identifiers are logged to the OS log for diagnostic purposes.

| Field | Meaning |
| --- | --- |
| `inputJumps` / `outputJumps` | Number of times sample time differed from the expected value (based on previous frame count) by more than 1 frame; does not confirm audible artifacts or dropouts |
| `hostGapsOver2Periods` | Number of times the HAL host-time interval exceeded 2 nominal periods of the previous output buffer; not a direct underrun detector |
| `maxEntryGapNs` / `maxProcessingNs` | Cumulative maximums (in ns) of entry-to-entry gap and processing duration, measured from after callback intake/format validation until right before return (not total HAL callback time) |
| `validMask` | Most recent valid timestamps (`1` = HAL host, `2` = input sample, `4` = output sample). Missing or non-finite values reset the comparison baseline so recovery does not fabricate jumps |
| `lastIOOffsetFrames` | Output sample time minus input sample time. Because origins may differ, do not interpret this as physical audible latency |
| `maxOutputDelta` / `outputDiscontinuities` | Cumulative maximum sample-to-sample delta within the same output channel, and count of deltas exceeding `0.2` full scale. Used to detect dropped samples or clicks; does not indicate overall audio quality or Bluetooth link health |

Statistics accumulate per route generation and persist after reclamation. Snapshots are approximate reads of independent atomics and may mix values from adjacent callbacks. While timestamps are missing, sample values and offsets retain their last observed values and should be read alongside `validMask`. Phase transitions are logged immediately; ongoing statistics are logged roughly once per second. Never use these diagnostics to infer permissions, audio correctness, or recovery success, or to trigger automatic route changes.

```bash
open -n --env FINETUNE_AUDIO_DIAGNOSTICS=1 DerivedData/Build/Products/Debug/FineTuneRewrite.app
log show --last 5m --style compact --predicate 'subsystem == "com.finetune-rewrite" AND category == "AudioRoute"'
```

## Pinned External Dependency Revisions

| Dependency | Revision |
| --- | --- |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | `1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27` |

## Upstream Test Inventory Baseline

Reference counts for the pinned upstream revision above. These are not target counts for the rewrite (see [verification policy](verification.md)).

| Inventory Item | Count | Meaning |
| --- | --- | --- |
| Swift source files | 54 | Test files in the pinned revision (UI test target exists but contains no UI test sources) |
| `@Test` declarations | 758 | Baseline count identifying upstream guarantee scenarios |
| Parameterized declarations | 44 | 43 literal input lists and 1 `VolumeHotkeyStep.allCases` |
| Static expanded invocations | 966 | 714 singletons plus expanded parameterized inputs (not a pass count) |
| JSON fixtures | 3 | Includes fixtures unreferenced at runtime upstream |
