# リファレンス

下記の固定元 URL に含まれる revision は[仕様](spec.md)で管理する比較元と同じである。

## ライセンスと出典

独立して書いた部分は[MIT License](../LICENSE)、原作由来のコンポーネントは`GPL-3.0-only`。ライセンス指定はファイルごとには行わず、下記のコンポーネント単位で[THIRD_PARTY_NOTICES.txt](../App/Resources/THIRD_PARTY_NOTICES.txt)に集約する。ファイルごとの由来はgit履歴で追える。

| コンポーネント | ライセンス |
| --- | --- |
| Profiles / AutoEQ | `GPL-3.0-only` |
| DeviceIcons | `GPL-3.0-only` |
| Mixer UI | `GPL-3.0-only` |
| Device observation | `GPL-3.0-only` |
| テスト / DSP | `GPL-3.0-only` |
| その他 | MIT |

原作のcopyright表示とGPL本文はアプリにバンドルする[THIRD_PARTY_NOTICES.txt](../App/Resources/THIRD_PARTY_NOTICES.txt)に一本化する。機能語彙・規則自体の権利性は法的に断定しない。外部AutoEqのINDEX/profile corpus自体は同梱せず、その取得dataを下記source codeと同一licenseへ再分類しない。GPL対象を含む製品binaryの配布時は、組合せ・対応source・通知とlicense提供等の条件を確認する必要がある。テストの隔離で製品のGPL条件が消えることはない。

### 原作由来の製品codeとdata（参照元）

| 製品ファイル | 参照した境界 | 固定原作のsource |
| --- | --- | --- |
| [DeviceIconCatalog](../App/DeviceIcons/DeviceIconCatalog.swift) | 85項目・順序・category/keyword data | [DeviceIconCatalog](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Models/DeviceIconCatalog.swift) |
| [systemAudioDaemonCatalog](../Sources/FineTunePlatform/Devices/Observation/systemAudioDaemonCatalog.swift) | bundle/name prefix語彙 | [AudioProcessMonitor:20–58](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/Monitors/AudioProcessMonitor.swift#L20-L58) |
| [URLAutomationParser](../Sources/FineTuneControl/Automation/URLAutomationParser.swift) | URL grammar・値変換規則 | [URLHandler](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Utilities/URLHandler.swift) |
| [deviceDefaultEchoes](../Sources/FineTuneControl/Routing/deviceDefaultEchoes.swift) | UID別の複数echo token・各2秒失効・消費規則 | [EchoTracker:4–73](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/Engine/EchoTracker.swift#L4-L73) |
| [deviceBadge](../App/Design/deviceBadge.swift) | 選択中の28ptアクセント色gradientと未選択monoの円形バッジ | [DeviceBadge](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/Components/DeviceBadge.swift) |
| [mixerVolumeSlider](../App/Design/mixerVolumeSlider.swift) | 4pt軌道・native mini thumbのhover/drag表示 | [LiquidGlassSlider](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/Components/LiquidGlassSlider.swift) |
| [mixerChrome](../App/Features/Mixer/mixerChrome.swift) | icon header・tabs・Quit capsuleの表示 | [MenuBarPopupView](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/MenuBarPopupView.swift)・[ViewModifiers](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/DesignSystem/ViewModifiers.swift) |
| [mixerView](../App/Features/Mixer/mixerView.swift) | APPS section・2列編集grid・Ignored/empty表示 | [MenuBarPopupView](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/MenuBarPopupView.swift) |
| [mixerAppRow](../App/Features/Mixer/mixerAppRow.swift) | 40pt行・icon controls・boost chevrons・hover/展開背景 | [AppRow](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/Rows/AppRow.swift)・[AppRowControls](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/Rows/AppRowControls.swift)・[AppEditRow](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/Rows/AppEditRow.swift) |
| [mixerAppRoutePicker](../App/Features/Mixer/mixerAppRoutePicker.swift) | icon trigger・route subtitle・Single/Multi/check/checkbox表示 | [DevicePicker](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/Components/DevicePicker.swift)・[ModeToggle](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/Components/ModeToggle.swift) |
| [AutoEQCatalog](../Sources/FineTunePlatform/Profiles/AutoEQCatalog.swift) | INDEX解析・検索順位 | [AutoEQFetcher](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQFetcher.swift)・[AutoEQProfileManager](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQProfileManager.swift) |
| [ParametricEQTextParser](../Sources/FineTunePlatform/Profiles/ParametricEQTextParser.swift) | APO grammar・filter規則 | [AutoEQParser](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQParser.swift) |
| [AutoEQProfileRepository](../Sources/FineTunePlatform/Profiles/AutoEQProfileRepository.swift) | 取得/cache/importの振る舞い | [AutoEQFetcher](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQFetcher.swift)・[AutoEQProfileManager](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQProfileManager.swift) |
| [ProfileFileStore](../Sources/FineTunePlatform/Profiles/ProfileFileStore.swift) | cache file/schema/mtime操作 | [AutoEQProfileLoader](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQProfileLoader.swift)・[AutoEQFetcher](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQFetcher.swift) |

## 音声経路の診断フィールド

`FINETUNE_AUDIO_DIAGNOSTICS=1`で起動すると、既存のnative snapshotから経路の状態・callback数・適用済みrevision・出力peakを`AudioRoute`ログへ記録する。ログは既定で無効。音声サンプル・buffer pointer・property配列は記録せず、HAL callback内ではログ出力とHAL呼出しを行わない。時刻変換の準備とログ出力は非リアルタイム側で行う。出力UID・app識別子は診断のためOSログへ記録する。

| フィールド | 意味 |
| --- | --- |
| `inputJumps` / `outputJumps` | 前回のframe数から期待するsample時刻との差が1 frameを超えた回数。異常音やdropoutの確定ではない |
| `hostGapsOver2Periods` | HALのhost時刻間隔が、直前の出力bufferの公称2周期を超えた回数。実際のunderrunを検知したものではない |
| `maxEntryGapNs` / `maxProcessingNs` | 計測地点間隔と処理時間の累積最大値（ns）。計測区間はcallbackの受付・format検証後から復帰直前までで、HAL全体の所要時間ではない |
| `validMask` | 直近の有効時刻（1=HAL host、2=入力sample、4=出力sample）。欠損・非有限値で比較の基準を切り、復帰時に飛びを捏造しない |
| `lastIOOffsetFrames` | 出力sample時刻−入力sample時刻。異なる時刻原点を含むため、物理的な可聴遅延とはみなさない |
| `maxOutputDelta` / `outputDiscontinuities` | 生成した出力の同一チャンネル内で連続frame間のSample値の差の累積最大値と、それが全尺度の0.2を超えた回数。サンプル抜けやクリックを検出するための量で、音質やBluetooth伝送の是否正常は表さない |

統計は経路の世代ごとに累積し、回収後も保持する。独立atomicの近似snapshotであり、隣接callbackの値が混ざることがある。時刻欠損中のsample値・offsetは最後に観測した値のままで、`validMask`と併せて読む。位相変化はすぐに、継続中の統計は約1秒に1回出力する。これらの診断から権限・音声の正しさ・復旧成功を推定したり、経路を自動変更したりしない。

```bash
open -n --env FINETUNE_AUDIO_DIAGNOSTICS=1 DerivedData/Build/Products/Debug/FineTuneRewrite.app
log show --last 5m --style compact --predicate 'subsystem == "com.finetune-rewrite" AND category == "AudioRoute"'
```

## 外部依存の固定revision

| 依存 | revision |
| --- | --- |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | `1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27` |

## 原作の棚卸し母数

上記の固定revisionに対する参照値。実装のtarget件数ではない（原則は[検証方針](verification.md)）。

| 棚卸し項目 | 件数 | 意味 |
| --- | --- | --- |
| Swift source | 54 | 固定版のtestファイル。UI test targetはあるがUI test sourceはない |
| `@Test`宣言 | 758 | 元の保証シナリオを識別する母数 |
| parameterized宣言 | 44 | literal入力43件と`VolumeHotkeyStep.allCases`1件 |
| 静的展開呼出し | 966 | 714 singletonと上記入力の展開。実行成功数ではない |
| JSON fixture | 3 | 原作ではruntime参照のない資料も含む |
