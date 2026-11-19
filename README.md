# FineTune-Rewrite

macOS向け[FineTune](https://github.com/ronitsingh10/FineTune)の基本用途を置き換えることを目指す再実装です。
UI・操作・保存設定・外部連携の基本互換を保ち、不具合を再現・修正・保守できる責務分離を重視します。

比較元は[`2285279d36d3f8115c1c2d4aecd904f1bdf96a51`](https://github.com/ronitsingh10/FineTune/commit/2285279d36d3f8115c1c2d4aecd904f1bdf96a51)に固定しています。
最新mainや将来のissue/PR対応を、現在の移植条件へ混ぜません。

## 現在の範囲

Mixer・Settings・キー操作・`finetune:` URLを、同じControlと設定storeへ接続しています。
製品Rootが機器・processの監視、入出力policy、機器操作、Native音声runtime、AutoEQ repository/cacheを組み立て、
UIは同じ状態のsnapshotと共通commandを使います。offline DSPだけの試験台ではありません。

| 区分 | 現在の範囲 |
| --- | --- |
| 実装・接続 | 製品Appの組立、表示と操作、保存、OS adapter、C ABI越しのtap/aggregate/IOProcと経路別DSP |
| 自動検証 | 原作由来のunit/component、新境界の独自テスト、実production DSP/C ABIとfake HALの契約試験 |
| 別途確認が必要 | 実音声・権限・物理機器、最小対応OS、callback deadline、署名・公証・配布 |

**元と同じ件数やテスト構造の再現は目的ではありません。**
元の保証と新unitの対応、独立review、移植時の実行記録は[移植台帳と確認手順](<docs/test-migration.md>)で管理します。
テストの成功は、原作用途をすべて置き換えられる製品、実機音声経路、リアルタイム安全性、署名・公証の完成を意味しません。
未実装・未接続・未検証を区別し、今回の検証では実音声の取得・再生やTCC承認を行っていません。
実機を必要としない保証をE2Eへ膨らませません。

## 構成

| 場所 | 責務 |
| --- | --- |
| [App](<App/>) | SwiftUI/AppKit表示・操作受付・依存の組立。同一ソースを製品AppとSwiftPM検証moduleで使う |
| [Domain](<Sources/FineTuneDomain/>) | OS非依存の値・識別・音量の意味・保存希望 |
| [Control](<Sources/FineTuneControl/>) | 操作・状態更新・変更計画と外部port |
| [Platform](<Sources/FineTunePlatform/>) | macOS・保存・機器・nativeへのadapter |
| [NativeAudio](<Sources/NativeAudio/>) | C ABI・処理資源の所有とnative実行境界 |
| [AudioDSP](<Sources/AudioDSP/>) | 機器・Foundation・UIに依存しないC++信号処理 |
| [DSPTests](<Tools/DSPTests/>) | 同じproduction nativeを使うoffline信号・C ABI・所有境界の試験 |
| [Tests](<Tests/>) | 原作由来unit/componentと独立した新境界テスト |

Swiftとnativeの公開境界はC形式です。C++型や所有権をSwift側へ広げません。
依存・targetの正本は[Package.swift](<Package.swift>)、設計意図は[アーキテクチャ](<docs/architecture.md>)にあります。

## 開発環境

- macOS、Xcode Command Line Tools、C++20対応Clang
- Swift 6言語モード。package tools-versionは6.0ですが、互換テストの`-default-isolation MainActor`にはSwift compiler 6.2以降が必要
- [just](https://just.systems/)、`clang-format` **21.1.8**
- Swift側はXcode付属の`swift format`、native側は[.clang-format](<.clang-format>)を使う

ローカル検証環境はmacOS 27 / Xcode 27.2 / SDK 27.2 / Swift 6.4.2 / arm64です。
[CI](<.github/workflows/check.yml>)はmacOS 26 / Xcode 26.6 / SDK 26.5を指定しています（Xcode 27のpreview imageはVisionのaccurate OCRが失敗するため）。CIでの実行結果や最小対応OSでの動作確認とは別です。
製品のdeployment targetはmacOS 15.4です。

```bash
brew install just llvm@21
export CLANG_FORMAT="$(brew --prefix llvm@21)/bin/clang-format"
just toolchain
```

Xcodeを切り替える場合は、選択状態を確認してから実行します。

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
xcodebuild -version
xcrun swift --version
```

外部SwiftPM依存は、実ショートカットadapterが使う[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)です。
比較元と同じrevision `1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27`へ固定し、[lockfile](<Package.resolved>)も管理します。

## チェック

```bash
just lint
just build
just test
just test-dsp
just test-native
just check
```

[Justfile](<Justfile>)の`just check`は、format lint・debug/releaseのpackage build、
unit/component test、offline DSP、native所有・levels・fake-HAL試験を実行します。
App bundle buildは通常チェックから外した明示opt-inです。
移植台帳とソース・実行結果を照合する専用の自動監査は含めません。保証対応の変更はreviewで確認します。

scratchとXcode出力先を分離する場合:

```bash
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
SWIFT_SCRATCH_PATH=.indexion/cache/integrationBuild \
BUILD_JOBS=2 just check
```

既定値はSwiftPMが`.build`、Xcodeが`DerivedData`、並列build数が2です。
既定のレシピはrunnerの終了statusで成否を判定し、test reportをscratchへ保存しません。
reportが必要な場合は各runnerの`--report`を明示します。
結果の読み方と台帳の確認手順は[テスト移植](<docs/test-migration.md>)、全体の保証境界は[検証方針](<docs/validation.md>)を参照してください。

formatを適用する場合:

```bash
just format
```

原作由来の期待値や入力をformat変更へ紛れ込ませません。
reviewでは純粋な整形と意味のあるliteral変更を区別し、承認済みの再設計を元の本文へ戻すことは要求しません。

## macOS App

[FineTune.xcodeproj](<FineTune.xcodeproj/project.pbxproj>)のschemeは`FineTuneRewrite`、module名は`FineTune`です。
同じAppソースとlocal package librariesを使い、bundle IDは原作と異なる`com.ph0ryn.FineTuneRewrite`です。

```bash
just build-app
just build-app release
open FineTune.xcodeproj
```

ルートの[build.sh](<build.sh>)は`bash build.sh [debug|release]`でも直接実行できます。
Xcodeのアカウント署名は無効のまま、完成したbundle全体をローカルad-hoc署名し、全architectureをstrict検証します。
これによりbundle ID・Info.plist・リソースを同じ署名へ結び付けます。証明書・署名アカウント・公証は使わず、起動・権限要求もしません。
**Xcodeのbundle build自体がLaunchServices/execution-policyへ開発bundleを登録する場合があります。**
`just check`には、実アプリを起動せずにbuild CLIの成果物を検証する`just test-build-app`も含みます。
実アプリのXcode bundle buildは通常の`just check`では実行せず、CIも使い捨てrunnerの別stepへ分離します。
ビルド成功を、実ユーザー環境での音声取得・再生や機器操作の確認として扱いません。
保存adapterも明示directoryを必須とし、原作の設定を暗黙に読み書きしません。
実hostはApplication Support内の`FineTune-Rewrite`を使い、原作settingsの読取・移行は実施していません。

製品Rootの構築は0 I/Oではありません。設定のdisk load・不正fileのbackup処理と、promptなしのAccessibility trust照会があります。
一方、profile repository/storeの構築は依存保存・URL検証に留まり、local profileの復元はservice開始時です。
注入portを使うGraph/表示modelのunit成功を、実Root起動の無副作用保証へ拡張しません。

### CaptureとSwiftPMの制約

新規・欠損設定のcapture希望はfalseです。保存済みtrueはユーザーの希望として保持し、Controlは新しいsessionを作ります。
保存希望・session・main executableのusage descriptionは、OSの権限許可そのものではありません。
main metadataがないSwiftPM版`FineTune`では、Nativeへ進む前にlive audioを明示unavailableとします。
製品Appのmetadataは[App plist](<Config/AppInfo.plist>)で管理します。

独立した[AudioProbe](<Tools/AudioProbe/main.swift>)は同じproduction Nativeを使い、専用targetにだけmain plistを埋め込みます。
`--help`はproducer構築前に処理されますが、引数省略/`--list`と`--describe`は実OSのread-only観測です。
`--capture`は対象app・process revision・output・時間を明示する実音声操作であり、通常チェックには含めません。
音量・開始停止・許可・失敗時の復帰を合意してから使う[安全条件](<docs/validation.md#実音声を確認するときの安全条件>)を参照してください。

### 音声経路の診断ログ

起動済みの開発AppをQuitした後、環境変数を明示して起動すると、既存のnative snapshotから経路の状態・callback数・適用済みrevision・出力peakを記録できます。
音声サンプルは保存せず、HAL callback内ではログを出しません。出力UID・app識別子は診断のためOSログへ記録します。
ログは既定で無効です。Appの起動は保存済みのcapture希望に従うため、診断有効化を音声処理の停止や権限許可とは扱いません。

有効時は、callbackの計測地点間隔・検証済み処理区間の実行時間（ns）、HALのhost時刻間隔、入力・出力のsample時刻の飛びも記録します。
callback内では固定領域とlock-free atomicだけを使い、時刻変換の準備とログ出力は非リアルタイム側で行います。位相変化はすぐに、継続中の統計は約1秒に1回出力します。

- `inputJumps` / `outputJumps`: 前回のframe数から期待するsample時刻との差が1 frameを超えた回数。異常音やdropoutの確定ではありません。
- `hostGapsOver2Periods`: HALのhost時刻間隔が、直前の出力bufferの公称2周期を超えた回数。実際のunderrunを検知したものではありません。
- `maxEntryGapNs` / `maxProcessingNs`: 計測地点間隔と処理時間の累積最大値。計測区間はcallbackの受付・format検証後から復帰直前までで、HAL全体の所要時間ではありません。
- `validMask`: 直近の有効時刻を示します（1=HAL host、2=入力sample、4=出力sample）。欠損・非有限値で比較の基準を切り、復帰時に飛びを捏造しません。
- `lastIOOffsetFrames`: 出力sample時刻−入力sample時刻。異なる時刻原点を含むため、物理的な可聴遅延とはみなしません。

統計は経路の世代ごとに累積し、回収後も保持します。独立atomicの近似snapshotであり、隣接callbackの値が混ざることがあります。
時刻欠損中のsample値・offsetは最後に観測した値のままなので、`validMask`と併せて読みます。これらの診断から権限・音声の正しさ・復旧成功を推定したり、経路を自動変更したりはしません。

```bash
open -n --env FINETUNE_AUDIO_DIAGNOSTICS=1 DerivedData/Build/Products/Debug/FineTuneRewrite.app
log show --last 5m --style compact --predicate 'subsystem == "com.finetune-rewrite" AND category == "AudioRoute"'
```

## 文書

- [開発ガイド](<AGENTS.md>): 作業範囲・参照基準・責務境界
- [アーキテクチャ](<docs/architecture.md>): 層分離・所有権・リアルタイム境界の設計意図
- [互換方針](<docs/compatibility.md>): 振る舞い・保存・外部操作と今回の延期事項
- [テスト移植](<docs/test-migration.md>): 元の保証から新unitへの対応・独立review・確認方法
- [検証方針](<docs/validation.md>): unit/component・限定実機・配布の保証境界

## ライセンス

本repositoryは複数licenseを含みます。独立MIT部分の[MIT License](<LICENSE>)を維持しますが、production全体や生成AppをMIT-onlyとは扱いません。
原作由来のテスト・fixtureと派生C++ unitはGNU GPL version 3の対象で、MITへ再ライセンスしません。
製品側にも、icon/daemon語彙のdataだけでなく、URL grammar、device-default echo token管理、AutoEQ catalog/parser/repository/storeの派生codeを含みます。
これらは各ファイル全体を`GPL-3.0-only`とし、[製品側の正確な区分と固定元](<docs/compatibility.md#製品側の派生codeとdata>)を記録しています。
これは新規行すべてを原作者のliteral copyと主張するものでも、他の独立MITファイルを再分類するものでもありません。

原作のcopyright表示とGPL本文は、アプリにバンドルする[THIRD_PARTY_NOTICES.txt](<App/Resources/THIRD_PARTY_NOTICES.txt>)に一本化しています。
テストの出典は各ファイルのSPDXヘッダと[互換方針](<docs/compatibility.md#ライセンス>)に記録します。
GPL対象を含む製品binaryを配布する場合は、組合せ・対応するsource・通知やlicense提供等の条件も確認する必要があり、
「GPLはテストだけなので製品には無関係」とは扱えません。現時点で配布適合性の法的保証や配布完了を主張しません。
