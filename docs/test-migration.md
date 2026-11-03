# 原作テストの保証対応と監査

## 目的と母数

比較元は[固定revision](https://github.com/ronitsingh10/FineTune/commit/2285279d36d3f8115c1c2d4aecd904f1bdf96a51)
`2285279d36d3f8115c1c2d4aecd904f1bdf96a51`です。最新mainへ更新しません。

| 元の棚卸し | 件数 | 意味 |
| --- | --- | --- |
| Swift source | 54 | 固定版のtestファイル。UI test targetはあるがUI test sourceはない |
| `@Test`宣言 | 758 | 元の保証シナリオを識別する母数 |
| parameterized宣言 | 44 | literal入力43件と`VolumeHotkeyStep.allCases`1件 |
| 静的展開呼出し | 966 | 714 singletonと上記入力の展開。実行成功数ではない |
| JSON fixture | 3 | 原作ではruntime参照のない資料も含む。保存しただけで試験成功とはしない |

**758宣言・966呼出しを新実装の実行target件数へ固定しません。**
unitで十分ならE2Eへ拡大せず、分割・統合・書換・高依存fixture置換を許容します。
元の保証から新unit/少数componentへのmany-to-many対応と、独立reviewによる十分性の説明が出口です。
optionalな実機/E2Eを通常CIの前提にしません。

## 台帳の正本

[永続manifest](<../Tests/UpstreamCompatibilityTests/migrationManifest.json>)に次を記録します。

- 固定revision、元54path/SHA256、元method ID・line・入力展開数
- 元の入力・本文・assertion・`@Test`属性のversion付きfingerprint
- A/B/C区分、適応/非可搬理由、対応する新しいSwift/C++ unit ID(s)
- 新しい実行入力数、review済みsnapshot、独自D、fixture由来
- authorと異なるreviewer、承認状態、根拠。自己監査だけではapprovedにしない

元IDは`FineTuneTests/<file>.swift::<Suite>.<method>`です。
移植先のfile数やmethod名を元と一致させる必要はありません。
複数元IDを一つのunitへ対応させたり、一つの元IDを複数unitへ分けたりできます。

| 区分 | 判定 |
| --- | --- |
| A | 可搬な入力・出力保証を直接保持。import・namespace・隔離directory等の意味を変えない適応は理由を記録 |
| B | 新設計のunit/少数componentへ同等の保証を再配置。旧本文・件数・呼出順序の一致を要求しない |
| C | 旧private stateや検出位置など非可搬な要求。根拠・新設計での扱い・代替保証を独立承認する |
| D | 新しい公開境界・所有・error/復帰などの独自試験。Cの代替をDとして別記してもよい |

B/Cを承認済みの再設計へ移した場合、元methodがないだけで欠落と判定しません。
一方、理由のない削除、入力削減、許容差緩和、skip、known-issue隠蔽でpassを作りません。

## 静的照合の役割

[監査器](<../scripts/auditUpstreamTests.py>)はPython標準libraryと選択Xcodeの`xcrun swift format`を使います。
原作sourceは固定SHA256を棚卸しと照合した後に解析し、758 IDs/966展開数の一致を独立確認しました。
大きな元本文やproduction実装はmanifestへ埋め込みません。

fingerprint方式は`swift-format-lexical-v1`です。
元棚卸しのraw/token hashと同一アルゴリズムだとは扱いません。
同じformatterで正規化してからcomment・純粋な整形を除く字句を照合し、string内の意味のあるspace、数値、引数を保護します。
multiline literalの実値を変えないindentationや、整形上の末尾commaは許容します。
helper/fixtureの変更もfile単位のreview済みsnapshotで検出します。

これは**改変検知**であり、hash一致だけで保証の十分性を証明するものではありません。
B/Cでは元本文への一致ではなく、review済みの新unitを守ります。
toolchain変更でhashが変わった場合も、期待値を自動採用せず差分の意味を確認します。

review前のseedや自己申告をapprovedへ自動昇格しません。
manifestがpendingなら、実行がGreenでも最終監査は失敗します。
静的確認だけを行う場合:

```bash
python3 scripts/auditUpstreamTests.py --static-only
```

このmodeはruntime未確認を明示するpartial checkであり、移植完了の証拠にはなりません。

## 実行証拠

通常の入口は[Justfile](<../Justfile>)です。

```bash
just audit-tests
just test
just test-dsp
just audit-upstream
just test release
just test-dsp release
just audit-upstream release
```

`just check`はlint/buildと両configurationの上記gateをまとめます。
Xcode App bundle buildはLaunchServices等への登録副作用を分離するため含めず、明示opt-inとdisposable CI stepに分けます。

### Source snapshotとfreshなreport

テスト前にcompiled source・fixture・build設定をhashし、指定した古いevents artifactを空にします。
テスト後に同一snapshotであることとreportの鮮度を検証します。
review manifestや文書はcompile入力でないため、実行後に承認を書き込めます。
production/test sourceを変えた場合は再実行が必要です。

SwiftとC++を同じsource snapshotへ対応付ける低水準手順:

```bash
python3 scripts/auditUpstreamTests.py \
  --capture-snapshot .build/test-source-snapshot-debug.json \
  --events .build/test-events-debug.jsonl \
  --cpp-events .build/test-dsp-results-debug.json
xcrun swift test --jobs 2 --configuration debug \
  --event-stream-output-path .build/test-events-debug.jsonl \
  --event-stream-version 0 --xunit-output .build/test-results-debug.xml
xcrun swift run --jobs 2 --configuration debug DSPTests \
  --report .build/test-dsp-results-debug.json
python3 scripts/auditUpstreamTests.py \
  --source-snapshot .build/test-source-snapshot-debug.json \
  --events .build/test-events-debug.jsonl \
  --cpp-events .build/test-dsp-results-debug.json \
  --json-output .build/test-audit-debug.json
```

C++へ移したunitがあるconfigurationでは、同じrunでnative named reportも生成・監査します。
Swift JSONLの件数へC++の成功を混ぜず、元保証→C++ ID/入力/許容差→実行結果を別に対応付けます。
report schema 1は`complete: true`と、全required caseの`id`・`status: passed`・正の`invocations`を要求します。
途中終了、失敗、欠落、重複、未知case、未知schemaを成功にせず、失敗の実測値等は追加診断fieldとして保持できます。
source snapshotにはTools内のSwift/native sourceやresourceも含め、review用の適応metadataだけを除きます。

### JSONL・XMLの読み方

- Swift Testing JSONL version 0の`test` descriptorと`testStarted`/`testEnded`を対応させる
- parameterizedでは`testCaseStarted`/`testCaseEnded`の異なるcase IDを数え、宣言数と分ける
- 全required新unitのstart/end、期待した入力数、重複なし、issue/skipなし、完了した`runEnded`を要求する
- 複数test productのrunを同一streamで受ける。欠けたproductやtruncated/未知schemaを成功扱いしない
- debug/releaseを一つのevents引数へ混ぜない。同じunitの二重実行になるためconfiguration別に監査する

SwiftPMのXCTest `Executed 0 tests` preambleは、Swift Testingが0件という意味ではありません。
Swift Testing用XMLは`test-results-<configuration>-swift-testing.xml`で、XMLのtestcase数だけでは入力展開の完了を示せません。
JSONL・source snapshot・監査JSONと合わせて読みます。

最終required件数は、review済みmanifestの**新しい対応先**から導出します。
元966への固定比較や、欠落を覆う総数だけの比較は行いません。
optional-hardwareには明示理由とreviewが必要で、通常CIの期待件数から除外します。
明示的に確認するrunだけ`--include-optional-hardware`で要求し、未実施をpassへ加えません。

## 監査器自身の試験

[mutation/snapshot tests](<../Tests/MigrationAuditTests/test_auditUpstreamTests.py>)は次を検証します。

- 期待値・string内space・parameter input・helper・宣言の無断変更を失敗にする
- 純粋なformatとmultiline実値不変を許容する
- pending/自己review、理由・代替のない非可搬扱いを失敗にする
- many-to-many統合により元の2宣言/3呼出しが新1unit/1呼出しになっても、review済みなら受け入れる
- runtime欠落・重複・skip・issue・未完run・未知schema・stale report/変更済みsourceを失敗にする

監査器はCIを通すために再設計を拒否する装置ではなく、説明のない保証低下や証拠の取り違えを検出するものです。

## 保証しない範囲と由来

unit/component passは、App consumer全接続・実HAL音声・権限・最小OS・長時間/RT deadline・署名/公証を証明しません。
[検証方針](<validation.md>)と[互換方針](<compatibility.md>)を参照してください。

原作由来test/fixtureと派生C++ unitもGNU GPL version 3を維持します。
[出自説明](<../Tests/UpstreamCompatibilityTests/README.md>)と[原作copyright/GPL本文](<../Tests/UpstreamCompatibilityTests/COPYING>)を同梱し、
独立production実装や独自試験の[MIT License](<../LICENSE>)と区別します。
