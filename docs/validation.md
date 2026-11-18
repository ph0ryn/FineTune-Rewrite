# 検証方針

## 何を保証するか

原作の意図された用途と、新設計の公開境界を検証します。
元の保証を十分に確かめられるunitを優先し、テストの完全一致・件数維持・旧内部構造の復元は目的にしません。
分割・統合・fixture置換は各テストの出典ヘッダと[互換方針](<compatibility.md>)に沿って、変更ごとのreviewで説明します。
原作issue/PR由来の改良は今回の移植から分離します。

**unitの成功、製品consumerの接続、実機動作、配布可能性は別の判定です。**
未実装のruntimeを単なる実機未検証と言い換えず、componentがあるだけで機能完成ともしません。

現在は製品RootからUI・同じController/store・機器/process観測・入出力policy・実Native runtime・AutoEQ cacheへ接続されています。
実装接続のsource review、少数composition unit、Swift factory契約、C++/fake-HAL実行、実音声はそれぞれ別の証拠です。
移植時の実行記録と現在の確認手順は[テスト移植](<test-migration.md>)で管理し、この文書の実装説明や一部suiteの成功を全製品の合格へ読み替えません。

## 試験のpyramid

### 1. Pure unit

- Domain: 音量の単位・slider mapping・識別・設定値・EQ model
- Control: volume/mute/boost・target選択・保存希望と観測/実行状態の分離・変更計画
- UIの純粋なtoken・表示値・icon選択・focus/scroll計算
- DSPの数式・係数・検出器・gain/smoothing。内部kernelはC++で直接検証でき、test専用Swift/C ABIを増やす必要はない

外部I/Oを必要としない入力と出力を直接確かめます。

### 2. 少数のcomponent/contract

- temporary directoryと注入login serviceを使う保存・flush・debounce・backup失敗
- actual App操作/monitor/registryからControl・store・device portへの接続
- AppKitのoffscreen view/windowやevent poster seam。AppKit import自体はE2Eではない
- 注入property reader・device能力・通知・clock・tap installerを使うOS adapterの選択/失敗/回収契約
- 同じproduction nativeのC ABI・所有/寿命・route/channel独立性・synthetic信号

全アプリ起動や実機に拡大せず、新しい境界の誤配線を検出する範囲へ絞ります。
privateな呼出列だけを検証する巨大mockではなく、公開結果・保存結果・portへ渡した意味を観測します。

#### UI表示leafのoracle

copy・format・静的な表示mappingは、View・window・bitmapを作らない
[AppPresentationContractTests](<../Tests/AppPresentationContractTests/>)で
productionのsemantic projectionを検証します。対象はSettings各tab・Mixer header/footer・
route menu・keyboard/AutoEQ bindings・device row actionsです。
ここでは意味値だけを確認し、glyphの可視性や実際のcontrol接続は証明しません。

実際のAppKit描画を伴う検証は[AppRenderedTests](<../Tests/AppRenderedTests/>)に集約します。
このsuiteはproduction Viewをoffscreenの`NSHostingView`へ描画し、実`NSWindow`の
configured size、native bridge（`NSSwitch`・`NSSegmentedControl`・`NSButton`）、
SwiftUI buttonの描画bounds、status itemのactionを確認します。
OCR・pixel probe・ScreenCaptureKit・pointer event loop・private SwiftUI proxyは使いません
（[renderedTestSupport.swift](<../Tests/AppRenderedTests/renderedTestSupport.swift>)）。
表示文字の認識はVisionの結果が環境に依存するため自動ゲートのoracleにせず、
選択badgeのfill/glyphやslider trackの寸法もsemantic projectionの値で確認します。
bitmap全体の一致や実際に描画されたpixelは保証しません。

status-item testは実`NSStatusItem`の探索・所有actionを検証するため`NSStatusBar.system`
へ一時的にitemを作成し、test内の`defer`で除去します。popoverは開かず、
mouse eventもOSへ送りません。

非描画のrouting・Root・policy suiteは[AppCompositionTests](<../Tests/AppCompositionTests/>)に
置き、共有routing fixtureを[AppTestSupport](<../Tests/AppTestSupport/>)経由で参照します。
両bundleは製品App module（FineTune）を参照するためAppKit/SwiftUIへのlink依存を持ち得ますが、
test自身が描画経路を実行しないことを境界とします。

視覚的な回帰は自動ゲート外で、代表状態のスクリーンショットと人間によるレビューで確認します。
現在の`just check`にはこの手順を含めず、描画時間や撮影成功率の改善も主張しません。

### 3. 限定した実機観測

権限・hardware・OS固有の仮説を確認する必要がある場合だけ、事前に対象と安全条件を決めて実行します。
通常CIのunit/componentを成立させるために、実機・録音・権限承認を必須にしません。
optional hardware/E2E証拠は、未実施のままunitのpassへ合算しません。

## 通常の自動チェック

```bash
just check
```

[Justfile](<../Justfile>)は指定configuration（既定debug）のformat lint、unit・contract・
DSP・native所有/levels/fake-HALを実行します。描画test（`test-ui`）とApp bundle buildは
含めず、CIの別jobで実行します。
通常チェックは製品アプリ起動・音声取得/再生・権限の承認要求（capture/TCC prompt等）・本物の設定移行・実機音量変更を行いません。

注入したclock/transportは、操作後の固定delayではなく登録数・event・task完了を同期点にします。checked continuationを待つtest gateには、個別のfailure deadlineとcancellation pathを持たせます。
所有taskの完了待ちでは、`Task.value`を待つだけでなく、完了eventとdeadlineで待機を区切ります。期限超過・cancel時はtaskをcancelし、fixtureのclockやgateを解放してから別の期限内で終了を確認します。解放callback自身は有限の操作に留め、対象taskの終了を待たせません。解放後も終了しない場合は未終了を明示して失敗にし、cancelでも診断を隠しません。非協調的なtaskと観測用taskが期限後も残る可能性を、回収成功とは扱いません。
この診断を検証する故障注入controlだけは、`withKnownIssue`で意図した未終了issueの発生を要求します。通常caseの失敗を免除する用途には使わず、control自身のgateも解放して対象taskの終了を確認します。
`NativeRetirementPoolRetryTests`は実`DispatchSourceTimer`を動かします。fake cleanup/release callbackのeventで完了を待ち、状態pollingはしません。
`PopupLayoutTests`に残るpollingは、SwiftUI所有のchild popover windowの表示・dismissを最大2秒、10ms間隔で観測します。fixtureからはそのframework-owned window transitionの完了callbackへ接続できないため、実window stateを読むbounded waitを使います。

個別実行:

```bash
just test
just test-dsp
just test-native
just test release
just test-dsp release
just test-native release
```

現在のgateは各runnerの終了statusを確認します。SwiftのXML/event JSONLとnativeのJSON reportは
既定のレシピでは生成しません。個別に確認したい場合は各runnerの`--report`を明示してください。
ソースを変更したら既存の実行結果を成功証拠として再利用せず、同じconfigurationで再実行します。
台帳の確認手順・many-to-many対応・独立reviewは[テスト移植](<test-migration.md>)にまとめます。

- 各runnerの非ゼロ終了は失敗として扱い、成功件数の合計や過去のreportで覆いません。
- parameterized declaration一つと実行row複数は別です。宣言数を実行数と混ぜません。
- SwiftとC++の成功を加算して総成功数を作りません。

CI設定があることと、CIが実際にpassしたことは区別します。
ローカルはmacOS27/Xcode27.2/SDK27.2/Swift6.4.2/arm64、[CI設定](<../.github/workflows/check.yml>)はmacOS26/Xcode26.6/SDK26.5です。
UI leafは実AppKitの構造と幾何を確認しますが、Vision OCR・ScreenCaptureKit・private SwiftUI proxyは使いません。表示文字の可視性は自動ゲートで検証しないため、別途の視覚レビューが必要です。描画結果はOSのAppKit実装に依存するため、別OSのpassを代替証拠にしません。
deployment target15.4での実機結果、両modeの同一入力証拠、別構成のsanitizer結果もそれぞれ分離します。

## DSPとnative境界

[offline DSP executable](<../Tools/DSPTests/main.cpp>)は本番と同じ実装を使い、合成信号で次を確認します。

- 初音・短い片側入力・無音中のfilter tail・無音後の再開
- 任意buffer分割での同一結果、route/channelごとの履歴独立
- bypass/再有効化・configuration交換・不正設定・非有限信号の明示errorと復帰
- C形式のbuffer契約・native-owned係数・停止後回収の前提・C++ heap allocationの検出

C++ named unitへ移した原作シナリオは、Swift JSONLとは別のnative機械reportで対応付けます。
元Swift methodが消えたことだけで欠落と判定せず、入力・許容差・新unitの実行結果をreviewします。
数式の出典・ISO資料の確認限界・sanitizer結果は[数値互換記録](<../Tools/DSPTests/Compatibility.md>)を参照してください。

記録済みのC++単独再検証はDebug、`-O2 -DNDEBUG`のRelease、ASan+UBSanの三構成で、各49 named unit/6654 finite input rowです。
これは移植時の履歴値で、現在のsource inventoryやschema 2 reportの`invocations`（case実行回数）とは同じ数ではありません。
現在の六つのnative executableは77 named caseを登録しています。
実productionを使うDSP・Stages・fake HAL・Callback Slots・Coherent Levels・C no-capture boundaryの六プログラムが対象です。
実行前のsymbol/link検査でphysical SystemHalを除外した証拠であり、Root・Swift factory・実OSの経路全体の合格ではありません。
Stage/HALの対応するRelease false-checkは失敗を検出しますが、非対応の他CLIまで検証済みとはしません。

計測したStage/HAL callbackのordinary/aligned C++ new/deleteは0、HALのowned fake OS resourceも0です。
他suiteで公開していないcounterを0と補完せず、全C malloc/free・CF/OS allocationの不在を主張しません。
allocation検出やASan/UBSanの成功は、実機callbackのdeadline・lock/wait・ARC・全concurrent handoff・PACを証明しません。
停止/quiescent前提の所有契約を、稼働中交換の安全性へ読み替えません。

## 実音声を確認するときの安全条件

実行前に、source app・output device・音量上限・開始/停止・録音保存の有無・失敗時の復帰を明示します。
ユーザーの許可なしに、音声を取得/再生したり、システム音量・default device・権限設定を変更しません。

production runtimeは実装されていますが、実音声の取得・再生・TCC承認は今回実施していません。必要な仮説に応じて次を分けて確認します。

- 1 app → 1 outputの開始/停止と、部分失敗時のsilence・資源回収
- format/sample rate/channel map・aggregate・default変更・切断/再接続
- 初音・idle後の短音・長時間稼働・sleep/wakeと権限の取消/復帰
- software/hardware/DDC/Bluetoothなどbackend別のvolume/muteと保存復元

### 既存AudioProbeの操作範囲

[AudioProbe](<../Tools/AudioProbe/main.swift>)は同じproduction Nativeを使うconsumerです。別の検証専用音声実装ではありません。

```bash
xcrun swift run --jobs 2 AudioProbe --help
```

`--help`と不正引数の処理はproducer構築前です。引数省略/`--list`は実device/processのread-only discovery、`--describe`は指定outputのmetadata読取です。
これらの観測はcaptureしませんが、OSへ触れないunitとは区別します。
`--capture`では`--app`・`--process-revision`・`--output`・`--seconds`を明示し、現在のapp/process bindingを使います。
時間は(0,30]秒でprepareを含むdeadlineがあり、cleanup待ちの上限は追加2秒です。blocked OSやPENDINGを安全解放済みとは扱いません。
source appはtap中mute、EQ/AutoEQ/loudnessは無効、`--gain`は0…1で既定unityです。音量の安全確認を省略しません。
main usage description・armed・first-appliedは権限許可の証明ではなく、失敗時は診断と終了結果を確認します。

これらは事前許可を得た限定観測であり、通常gateに追加せず、機能ごとに巨大E2Eを追加する要件にもなりません。

### 経路無効化の診断

`bindingChanged / certifyFormat / -5101`はローカルの経路無効化コードで、HALの個別エラーやproperty selectorを表すものではありません。
`resolveOutput`の拒否もHALのOSStatusではなく条件別のローカルコードで返します（-5110 identity、-5111 input channels、-5112 aggregate、-5113 stereo order、-5114 layout、-5115 sample-rate disagreement）。
いずれも`unsupported`のまま条件を区別するので、表示は条件別の説明を出し、汎用の「unsupported format」で原因を隠しません。
rate disagreementはデバイスがformat遷移中の一時状態でも成立しますが、この区別は再試行可否の判断ではなく、失敗後に状態が戻っても原因を特定できるようにするためのものです。
nativeは無効化時に最初に記録権を得たイベントだけを保持し、property通知のobject・件数・最初のaddressと、IO callbackのdevice・入力構成・出力構成・出力データ欠損・frame不一致を区別します。
この記録はイベント全体の発生順や根本原因の証明ではなく、既存の証明条件を緩めません。通常idle、DSPエラー、無効化前の状態から理由を推測して埋めることもありません。

`FINETUNE_AUDIO_DIAGNOSTICS=1`で起動した場合、Swiftの非リアルタイム側がこの記録を既存の`AudioRoute`ログへ出します。音声サンプル・buffer pointer・property配列は記録せず、callback内ではログやHAL呼出しを行いません。
[production C境界とfake HALのテスト](<../Tests/NativeHALContractTests/main.cpp>)は理由の区別・同時通知・reader-zero後の履歴・遅延callbackを検証しますが、実際に報告された無効化の原因を再現した証拠ではありません。
実機の再起動・captureは、対象アプリ・出力・時間・音量と復元条件を確認してから行います。

## 製品組立と配布

実Graph/表示model/Host/lifecycleと外部portを使うcomposition testで、同じControl・store・nativeへの接続を確かめます。
観測health、default policy、await後の最新payload、early URL、input停止・repeat取消、stop/flushなどは公開結果を検証します。
Quitは原作同様、終了通知で同期的に入力停止・HUD終了・設定flushを行い、非同期の音声回収を終了条件にはしません。
Hostの公開delegate capabilityと、入力停止・保存結果をcomponentで確認します。実音声中の終了やOSの全資源回収を証明するものではありません。
ただしfake-port呼出0は、実Root起動のglobally OS-inert証明ではありません。Root constructorには設定disk load/backupとnon-prompt AX trust queryがあります。
profile repository/storeのconstructorはURL検証/依存保存だけで、local disk復元はservice開始時です。
Settingsの同一VM参照をsourceで確認することと、実NSWindowのdeallocationを計測することも別です。

新規/欠損設定のcapture希望はfalse、保存trueはdurable wishとして新しいsessionへ渡します。保存値をOS permissionや古いsession tokenと混同しません。
main capture metadataがなければSwiftPM版AppはNative前に明示unavailableです。
[App plist](<../Config/AppInfo.plist>)と[Probe専用plist](<../Tools/AudioProbe/Info.plist>)、[限定linker設定](<../Package.swift>)を分け、library/test hostへその設定を継承させません。
built metadata検査、実権限、物理HALの動作は別の確認です。
停止後も残すweak passive cleanup診断はOS/input observerの例外であり、per-route retired ACKやhistoryからglobal pool drainを証明しません。

`just build-app`は明示opt-inの署名無効開発bundle buildです。
XcodeのbuildだけでもLaunchServices/execution-policyへbundleを登録する場合があるため、通常チェックから除外します。
CIのbundle buildは使い捨てrunnerの別stepです。アプリ未起動と、登録副作用なしは同義ではありません。
実配布では別途、対象OS/architecture、entitlements・usage description・bundle identity、署名・公証・更新/アンインストールを確認します。
原作のユーザー設定を勝手に開かないことと、明示的なimport/移行の安全性も別の受入条件です。
