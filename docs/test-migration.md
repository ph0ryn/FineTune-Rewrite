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
元の保証から新unit/少数componentへのmany-to-many対応と、変更ごとのreviewによる十分性の説明が出口です。
optionalな実機/E2Eを通常CIの前提にしません。

## 移植時に確定したsnapshot

この節は専用の自動監査を削除する前に確定した移植時の記録です。
現在の`just check`はこの完全監査を再実行しません。

固定版の原54ファイル・全758 ID/966展開数を移植時の監査で照合し、
**A550/B205/C3**の各保証対応と独自**D341**を確定しました。
これらは移植時snapshotの分類であり、現在のsource件数や実行件数ではありません。DはSwift/C++を含む保証の件数で、実行件数へ重ねて加算しません。

| 移植時に完了した検証 | Debug | Release |
| --- | --- | --- |
| Swift Testing・7 products | 1055宣言 /1349有限入力呼出し | 1055宣言 /1349有限入力呼出し |
| C++・6 programs | 49 named units /6654有限入力呼出し | 49 named units /6654有限入力呼出し |
| 完全監査（移植時snapshot、現在は非実行） | pass・errors0 | pass・errors0 |

上の表は**移植時に確定した履歴snapshot**で、現在のsource inventoryや`just check`の結果ではありません。
現在のnative 6 executableの登録named caseは77件（DSP 23、Stage 5、Slot 7、Levels 3、Runtime 1、HAL 38）です。
49 named unit/6654有限入力呼出しを現在のsource件数へ読み替えません。移植時のbaselineは固定版の出自記録として確定済みで、現在のsourceの由来は各テストのSPDXヘッダで示します。

Swiftは各7組のrun開始/終了、全function/case開始/終了、XML1055宣言を照合し、
issue/failure/error/skip・compiler warningは0です。C++は6つのpositive reportを同じsnapshotで照合しました。
別のASan+UBSan実行も49/6654がpassし、対応する二つのRelease故障注入controlは意図どおりexit1でした。
故障注入結果をrequired成功件数へ加算したり、通常試験の失敗を隠したりしていません。

両configurationのbefore/after/current入力mapは283ファイルで一致しました。
これはresource/build入力と一部過包含cacheを含む追跡集合であり、283個のコンパイル単位という意味ではありません。
C++の保守的なsource inventory37とは別に、実`-MMD`和は**authored36＋外部境界用generated provider1**です。
未参照umbrella header1件を実compiler依存と数えず、providerもDSP/runtime本体の代用品ではありません。
SystemHalの実ObjC++ typecheckは別のDebug/Release各1 TUで確認し、incremental SDK進捗だけからfresh compileと推論していません。

移植時の独立D cohortは147宣言/210入力呼出しで、NativeRoute 5宣言/29呼出しとHUD hide-delay 1/1を含みます。D341は別に確定した範囲です。
`test-redesign-final`を承認するには、変更後の同一worktreeでfresh full `just check`をDebug/Release両方に通し、その後にreviewを完了します。過去のpassはsource変更後の証拠に再利用しません。上のpass表は移植時snapshotであり、現行gateの実行結果ではありません。実機・App起動・OS権限・可聴音・RT deadlineの合格も含めません。

## 出典の扱い

旧`migrationManifest.json`、旧`Tests/UpstreamCompatibilityTests/README.md`、旧`COPYING`は削除しました。
固定版のrevisionとGPL由来のファイル範囲は[互換方針](<compatibility.md#ライセンス>)に、
GPL本文とcopyright表示は[THIRD_PARTY_NOTICES.txt](<../App/Resources/THIRD_PARTY_NOTICES.txt>)に記録します。
各テストの由来はファイル先頭のSPDXヘッダで示し、現在の承認状態を管理する台帳は維持しません。
元IDは`FineTuneTests/<file>.swift::<Suite>.<method>`ですが、移植先のfile数やmethod名を一致させる必要はありません。
複数元IDを一つのunitへ対応させたり、一つの元IDを複数unitへ分けたりできます。

移植時は次のA/B/C/Dで分類していました。現行の判断基準ではありません。

| 区分 | 意味 |
| --- | --- |
| A | 可搬な入力・出力保証を直接保持したもの |
| B | 新設計のunit/少数componentへ同等の保証を再配置したもの |
| C | 旧private stateや検出位置など非可搬な要求を置き換えたもの |
| D | 新しい公開境界・所有・error/復帰などの独自試験 |

理由のない削除、入力削減、許容差緩和、skip、known-issue隠蔽でpassを作りません。

## 現在の保証対応

Settings・Mixerのcopy・format・静的な表示mappingは、View・window・bitmap・run loopを作らない
[AppPresentationContractTests](<../Tests/AppPresentationContractTests/>)で確認します。
対象はSettings各tabのexact copy、Mixerのheader/footer・popup semantics・route menuの
single/multi label、multi routeのobserved/missing subtitle、default出力/入力名、
capture noticeのaction labelです。
旧rendered suiteのbinding・action契約（[SettingsViewTests](<../Tests/AppRenderedTests/SettingsViewTests.swift>)、
[MixerTests](<../Tests/AppRenderedTests/MixerTests.swift>)）は描画用の
[AppRenderedTests](<../Tests/AppRenderedTests/>)へ残し、
OCR・pixel・実際のcontrol/actionのoracleは実際に描画するtestへ残します。
描画/OCR/SCKを実行する9 suite・94宣言は`AppRenderedTests`、非描画の18 suite・127宣言は
`AppCompositionTests`に分け、runtime IDはmodule prefix（`AppCompositionTests.`→
`AppRenderedTests.`）だけを変えます。`@Test`属性行・label・argument・invocationは変えません。
この分離は描画時間やScreenCaptureKitの失敗率の改善を主張しません。

物理default出力・入力のpolicy契約は、View・window・bitmap・run loopを作らない
[AppPolicyContractTests](<../Tests/AppPolicyContractTests/>)で、実際のSettingsManagerと
Output/InputDevicePolicyControllerへclock/writer portを注入して確認します。
このtargetは描画/OCR suiteとは別のtest bundleで実行し、共有するtest専用helperは
[AppTestSupport](<../Tests/AppTestSupport/>)へ置きます。
helperは製品targetや製品libraryの一部ではなく、製品側から参照しません。
`FineTunePlatform`の依存frameworkはlinkされ得るためAppKit非linkは主張せず、
このtargetのtestがwindow・bitmap・OCR経路を実行しないことを境界とします。
`OutputPolicyTests`（18宣言）と`InputPolicyTests`（4宣言）のruntime IDはmodule prefixと`@Test`属性行の+1（`import AppTestSupport` 1行追加）のみ
`AppCompositionTests`から`AppPolicyContractTests`へ移り、
suite・type・label・argument・invocationと2秒/5秒のpolicy deadlineは変えません。

asyncのdeadline・cancel/release・drain・known-issue controlの条件は
[検証方針](<validation.md>)の「通常の自動チェック」に整理しています。
固定delayを同期点にせず、解放後も終了しないtaskを成功扱いしない点も同じです。

## 現在の確認手順

専用の自動監査器、そのmutation/snapshot tests、および対応台帳は削除しました。
現在の`just check`はソースと実行結果を自動照合するgateではなく、各runnerの終了statusを確認します。

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

- 元の保証に対応する新unitの入力・期待値・許容差を確認し、分割・統合や非可搬化の理由を変更の根拠として説明する
- fixture/helperの変更も含めてreviewし、期待値や入力削減を単なるformat変更へ混ぜない
- production/test sourceを変更したら、同じconfigurationの該当テストを再実行する。古いreportを現在の成功証拠として再利用しない

### 実行結果の読み方

SwiftのJSONL・XMLと六つのnative JSON reportをconfiguration別にscratchへ保存します。
source snapshotと監査JSONは生成しません。実際のproduct/report pathsは[Justfile](<../Justfile>)を管理元とします。

- `just test`は`test-results-<configuration>.xml`（`--xunit-output`の引数）、別のSwift Testing report sidecar `test-results-<configuration>-swift-testing.xml`、`test-events-<configuration>.jsonl`を実行前に0バイトへ切り詰める。空のXML/JSONLは有効なreportではなく、成功証拠でもない
- `just test-dsp`はDSP reportをschema 2の`complete:false` skeletonへ戻し、`just test-native`はnativeの5 report（Stage・Slot・Levels・Runtime・HAL）を初期化してからrunnerを実行する。`just test-native-hal`単独でもHAL reportをclang buildの前に初期化する
- `just check`はdebug/releaseのSwift XML/JSONLを空にし、native/DSP JSON reportをschema 2の`complete:false` skeletonへ戻してからbuild/runを始める。compile失敗や起動前終了で残る空reportまたはskeletonを成功証拠にしない
- Swift Testing JSONL version 0の`test` descriptorと`testStarted`/`testEnded`を対応させる
- parameterizedでは`testCaseStarted`/`testCaseEnded`の異なるcase IDを数え、宣言数と分ける
- 必要なunitの実行、期待した入力数、issue/skipの有無、完了した`runEnded`を確認する
- native report schema 2の`complete: true`、各caseの`id`・`status: passed`・`failures: 0`を確認する
- `invocations`はrunnerがそのnamed caseを実行した回数で、登録caseは1。0・欠落・重複IDは実行証拠にしない
- `inputs`はcaseがreportへ明示的に宣言した有限シナリオ/入力行の数。単一シナリオのcaseは1、Stage/HALのようにparameter/merge/iterationを明示rowとして数えるcaseはその件数。`assertions`は実際に評価したalways-on checkの数であり、`invocations`とも`inputs`とも別の数
- `inputs`または`assertions`が0のcase、空の`cases`、ID欠落・重複、`invocations`が1でないreportは`complete:true`でも成功扱いしない
- 失敗したcaseは`status: failed`と最初のactual/expected（不明ならnull）を`complete:true`のreportへ残すが、実行は非ゼロ終了する。report内の失敗行を成功件数へ読み替えない
- 期待するcase IDの集合は各executableのsource registryで確認し、総数だけの一致や古いreportの再利用で欠落を覆わない
- Swiftの宣言数へC++の成功を混ぜず、元保証→新unit/入力/許容差→実行結果を別に対応付ける
- debug/releaseを混ぜず、途中終了・欠落・重複・不完全なreportを成功扱いしない

SwiftPMのXCTest `Executed 0 tests` preambleは、Swift Testingが0件という意味ではありません。
`Justfile`は`test-results-<configuration>.xml`を`--xunit-output`へ渡します。
`test-results-<configuration>-swift-testing.xml`は別のSwift Testing report sidecarで、前者の旧名ではありません。
XMLのtestcase数だけでは入力展開の完了を示せないため、event JSONLと併せて読みます。
元966への固定比較や、欠落を覆う総数だけの比較は行いません。

optional-hardwareにはSwift/C++を問わず明示理由とreviewが必要で、未実施をpassへ加えません。
実機操作を伴うtestは既定test targetに入れず、別package/明示manual runnerへ隔離してください。
metadataをoptionalにしただけで、通常の`swift test`が実機操作を止めてくれるとは扱いません。

## 保証しない範囲と由来

unit/component passは、App consumer全接続・実HAL音声・権限・最小OS・長時間/RT deadline・署名/公証を証明しません。
[検証方針](<validation.md>)と[互換方針](<compatibility.md>)を参照してください。

原作由来test/fixtureと派生C++ unitもGNU GPL version 3を維持します。
原作のcopyright表示とGPL本文はアプリにバンドルする[THIRD_PARTY_NOTICES.txt](<../App/Resources/THIRD_PARTY_NOTICES.txt>)に一本化し、
独立MIT部分の[MIT License](<../LICENSE>)と区別します。
製品側にも原作由来data・派生codeのwhole-file GPL区分があり、[正確なファイル範囲と固定元](<compatibility.md#製品側の派生codeとdata>)を記録しています。
テストの隔離を理由に、GPL対象を含む製品binaryの配布条件まで不要とは扱いません。
