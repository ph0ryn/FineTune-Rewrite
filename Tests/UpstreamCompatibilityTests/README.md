# 原作互換性テスト

## 比較元とライセンス

比較元は[FineTune](https://github.com/ronitsingh10/FineTune)の固定revision
[`2285279d36d3f8115c1c2d4aecd904f1bdf96a51`](https://github.com/ronitsingh10/FineTune/commit/2285279d36d3f8115c1c2d4aecd904f1bdf96a51)です。
元の場所は`FineTuneTests/`です。比較元を最新mainへ更新しません。

原作に由来するテスト・fixtureとその派生物は、**GNU GPL version 3**の対象です。
Copyright (C) 2026 Ronit Singh。原作のcopyrightとライセンス本文を
[COPYING](<COPYING>)に原文のまま収録しています。独立して作成した新設計の実装・テストの扱いは
[ルートREADMEのライセンス](<../../README.md#ライセンス>)と[MIT License](<../../LICENSE>)を参照してください。
ファイルを移動・修正しても原作由来のコードをMITへ再ライセンスしません。

## 検証対象

原作の54 Swiftファイルには758個の`@Test`宣言があります。
44個はparameterized testで、固定入力を展開した静的呼出し数は966件です。
これは比較元の調査母数であり、新しいtest targetの件数を固定する合格条件ではありません。
宣言数・parameter case数・実行結果は別々に集計し、保証する振る舞いを監査台帳へ対応付けます。
unit testを中心にし、必要なAppKit/native componentだけを個別に検証します。
実アプリ・実機器を使うE2Eは通常のgateに含めず、明示的なopt-inで区別します。
Xcode projectにUI test targetはありますが、固定版にUI testソースはありません。
AppKit/SwiftUIを使う単体テストはこの互換性テストに含まれます。

各項目は次の区分で追跡します。

- **A: 可搬な振る舞い** — 通常は期待値・許容差・入力集合を保ってunitへ移す。再編時も同じ保証を対応付ける。
- **B: 内部構造に依存する性質** — 新設計の同等テストへ対応付け、保証する性質を弱めない。
- **C: 非移植** — 旧実装にだけ意味がある根拠・新設計での扱いを記録し、lead確認を受ける。
- **D: 独自テスト** — C ABI、所有・寿命、処理履歴、保存など新しい公開境界の必要な試験を追加する。

移植状況・必要なimport/API/環境適応・非移植理由は監査台帳で追跡します。
分割・統合・新しいseamによるunitへの置換は可能ですが、保証を弱める期待値変更や無言の欠落でpassを作りません。
原作のissue/PR由来の改良は、この移植の完了条件に含めません。

## 実行と隔離

[Package.swift](<../../Package.swift>)の単一`UpstreamCompatibilityTests` targetは、
製品と同じ`App/`ソースから作る`FineTune` moduleと実ライブラリを検証します。
`@testable import`で製品のentryやservice組立は実行されず、このimport自体をE2Eとは扱いません。
旧実装を丸ごと埋めた互換専用moduleやfake外部依存は使いません。

Swiftの**言語モード6**とコンパイラの機能要件は別です。
[原作のtest target設定](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune.xcodeproj/project.pbxproj#L506-L545)にある
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`を、互換targetだけの
`-default-isolation MainActor`で再現します。このflagにはSwift 6.2以降のコンパイラが必要です。
原作の`isolated deinit`を削除せず、Domain/Control/Platform/Appの既定isolationは変更しません。
ローカル実証はSwift 6.4.2 / Xcode 27.2 / macOS 27 arm64であり、CIの固定toolchainでの結果とは区別します。

```bash
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SWIFT_SCRATCH_PATH=.indexion/cache/integrationBuild
just test
just test-dsp
just test-native
just test release
just test-dsp release
just test-native release
```

実行結果は指定scratch内の`test-results-<configuration>-swift-testing.xml`と
`test-events-<configuration>.jsonl`へ保存します。XMLのtestcase数は宣言数であり、
parameterized入力ごとの呼出しはJSONの`testCaseStarted` / `testCaseEnded`で確認します。
`just test-dsp`は実C++unitを実行し、`test-dsp-results-<configuration>.json`へnamed caseごとの
結果を保存します。C++に対応付けた保証はSwiftの宣言数へ加算せず、このreportで独立に検証します。
`just test`は実行前にSwift eventsを空にし、native executableは実行時にreportを書き直します。
専用の自動監査は削除したため、台帳・fingerprint・source hashと実行結果の照合は行いません。
保証対応や入力・期待値の変更はreviewし、ソース変更後は該当するテストを再実行します。
[対応台帳](<migrationManifest.json>)と[確認手順](<../../docs/test-migration.md>)も参照してください。

- AppKitを使うテストはMainActor上の`NSApplication.shared`だけを必要に応じて初期化します。
  実アプリの起動、録音、音声再生、権限要求はbootstrapへ含めません。
- 保存テストはtemporary directoryと明示的なLaunchAtLogin adapterを使います。
  ユーザーの本物の設定やログイン項目を読み書きしません。
- event tapや機器接続はDIの境界を使い、テストのためにユーザーの権限・機器音量を変更しません。
- [Fixtures](<Fixtures/>)の3 JSONファイルは原作とbyte-identicalに保存し、テストbundleへコピーします。
  原作がinlineで使っている入力も、入力集合を省略せず維持します。

成功は可搬・同等性質・必要な新境界テストの範囲を示します。
実機の音声経路、最小対応OSでの実行、リアルタイム安全性、署名・公証の成立とは区別します。
詳細は[検証方針](<../../docs/validation.md>)を参照してください。
