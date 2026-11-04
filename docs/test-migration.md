# 原作テストの保証対応と確認

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

## 確定した移植・実行結果

この節は専用の自動監査を削除する前に確定した移植時の記録です。
現在の`just check`は以下の完全監査を再実行しません。

固定版の原54ファイル・全758 ID/966展開数・全baseline fingerprintを保持し、
**A550/B205/C3**の各保証対応と独自**D341台帳record**を独立reviewで確定しました。
DはSwift/C++を含む保証の台帳件数であり、次の実行件数へ重ねて加算しません。

| 移植時に完了した検証 | Debug | Release |
| --- | --- | --- |
| Swift Testing・7 products | 1055宣言 /1349有限入力呼出し | 1055宣言 /1349有限入力呼出し |
| C++・6 programs | 49 named units /6654有限入力呼出し | 49 named units /6654有限入力呼出し |
| 完全監査 | pass・errors0 | pass・errors0 |

Swiftは各7組のrun開始/終了、全function/case開始/終了、XML1055宣言を照合し、
issue/failure/error/skip・compiler warningは0です。C++は6つのpositive reportを同じsnapshotで照合しました。
別のASan+UBSan実行も49/6654がpassし、対応する二つのRelease故障注入controlは意図どおりexit1でした。
故障注入結果をrequired成功件数へ加算したり、通常試験の失敗を隠したりしていません。

両configurationのbefore/after/current入力mapは283ファイルで一致しました。
これはresource/build入力と一部過包含cacheを含む追跡集合であり、283個のコンパイル単位という意味ではありません。
C++の保守的なsource inventory37とは別に、実`-MMD`和は**authored36＋外部境界用generated provider1**です。
未参照umbrella header1件を実compiler依存と数えず、providerもDSP/runtime本体の代用品ではありません。
SystemHalの実ObjC++ typecheckは別のDebug/Release各1 TUで確認し、incremental SDK進捗だけからfresh compileと推論していません。

最後の登録では独立承認済み新D141宣言/180呼出しと、既存37 methodの理由付きFP差のみを追加照合しました。
原baseline・分類・入力・数値期待を変えず、Bool callbackの成功stub適応、共有clock型名、強化したUI/status assertionsを個別に説明しています。
実機・App起動・OS権限・可聴音・RT deadlineの合格をこの結果へ含めません。

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

## 現在の確認手順

専用の自動監査器とそのmutation/snapshot testsは削除しました。
台帳は出自・保証対応・移植時のreview記録として残しますが、現在のソースと実行結果を自動照合するgateではありません。
台帳の承認状態、fingerprint、必要なunitの欠落、source hashとreportの鮮度の横断照合も行いません。

通常の入口は[Justfile](<../Justfile>)です。

```bash
just test
just test-dsp
just test-native
just test release
just test-dsp release
just test-native release
just check
```

`just check`はformat lint・package buildと両configurationの上記テストをまとめます。
各runnerの非ゼロ終了はチェック失敗として扱います。
Xcode App bundle buildはLaunchServices等への登録副作用を分離するため含めず、明示opt-inとdisposable CI stepに分けます。

### 変更時のreview

- 元の保証に対応する新unitの入力・期待値・許容差を確認し、分割・統合や非可搬化の理由を台帳へ記録する
- fixture/helperの変更も含めてreviewし、期待値や入力削減を単なるformat変更へ混ぜない
- pendingや自己reviewを独立承認へ自動昇格しない
- production/test sourceを変更したら、同じconfigurationの該当テストを再実行する。古いreportを現在の成功証拠として再利用しない

台帳に残る`swift-format-lexical-v1` fingerprintは、移植時にformatterで正規化した字句の改変検知用記録です。
hash一致だけで保証の十分性を証明するものではなく、現在の手順では再生成・照合しません。

### 実行結果の読み方

SwiftのJSONL・XMLと六つのnative JSON reportをconfiguration別にscratchへ保存します。
source snapshotと監査JSONは生成しません。実際のproduct/report pathsは[Justfile](<../Justfile>)を管理元とします。

- `just test`は開始時にSwift JSONLを空にする。native executableは起動時にreportを書き直すが、build失敗で起動しなかった旧reportを成功証拠にしない
- Swift Testing JSONL version 0の`test` descriptorと`testStarted`/`testEnded`を対応させる
- parameterizedでは`testCaseStarted`/`testCaseEnded`の異なるcase IDを数え、宣言数と分ける
- 必要なunitの実行、期待した入力数、issue/skipの有無、完了した`runEnded`を確認する
- native report schema 1の`complete: true`、各caseの`id`・`status: passed`・正の`invocations`を確認する
- C++の`invocations`は実際に実行した入力case数で、診断用の`checks`とは区別する
- Swiftの宣言数へC++の成功を混ぜず、元保証→新unit/入力/許容差→実行結果を別に対応付ける
- debug/releaseを混ぜず、途中終了・欠落・重複・不完全なreportを成功扱いしない

SwiftPMのXCTest `Executed 0 tests` preambleは、Swift Testingが0件という意味ではありません。
Swift Testing用XMLは`test-results-<configuration>-swift-testing.xml`で、XMLのtestcase数だけでは入力展開の完了を示せません。
JSONLと併せて読みます。元966への固定比較や、欠落を覆う総数だけの比較は行いません。

optional-hardwareにはSwift/C++を問わず明示理由とreviewが必要で、未実施をpassへ加えません。
実機操作を伴うtestは既定test targetに入れず、別package/明示manual runnerへ隔離してください。
metadataをoptionalにしただけで、通常の`swift test`が実機操作を止めてくれるとは扱いません。

## 保証しない範囲と由来

unit/component passは、App consumer全接続・実HAL音声・権限・最小OS・長時間/RT deadline・署名/公証を証明しません。
[検証方針](<validation.md>)と[互換方針](<compatibility.md>)を参照してください。

原作由来test/fixtureと派生C++ unitもGNU GPL version 3を維持します。
[出自説明](<../Tests/UpstreamCompatibilityTests/README.md>)と[原作copyright/GPL本文](<../Tests/UpstreamCompatibilityTests/COPYING>)を同梱し、
独立MIT部分の[MIT License](<../LICENSE>)と区別します。
製品側にも原作由来data・派生codeのwhole-file GPL区分があり、[正確なファイル範囲と固定元](<compatibility.md#製品側の派生codeとdata>)を記録しています。
テストの隔離を理由に、GPL対象を含む製品binaryの配布条件まで不要とは扱いません。
