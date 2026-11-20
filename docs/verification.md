# 検証方針

この文書は、成果物の正しさをどう判断するかを規定する。検証する契約は[仕様](spec.md)、実行手順は[開発手順](development.md)を正本とし、ここでは不変条件・判定基準・試験範囲・既知の限界だけを扱う。

**unit/componentの成功、製品consumerの接続、実機の音声、配布可能性は別の判定である。** 一つの成功を別の合格へ読み替えない。

## 保証の範囲

### 試験のpyramid

**Pure unit。** 外部I/Oを必要とせず、入力と出力を直接確かめる。

- Domain: 音量の単位・slider mapping・識別・設定値・EQ model
- Control: volume/mute/boost・target選択・保存希望と観測/実行状態の分離・変更計画
- UI: 純粋なtoken・表示値・icon選択・focus/scroll計算
- DSP: 数式・係数・検出器・gain/smoothing。内部kernelはC++で直接検証し、test専用のSwift/C ABIを増やさない

**少数のcomponent/contract。** 新しい境界の誤配線を検出する範囲へ絞る。

- temporary directoryと注入login serviceを使う保存・flush・debounce・backup失敗
- 実Appのoperation/monitor/registryからControl・store・device portへの接続
- AppKitのoffscreen view/windowとevent poster seam。AppKit import自体はE2Eではない
- 注入したproperty reader・device能力・通知・clock・tap installerを使うOS adapterの選択・失敗・回収契約
- production nativeのC ABI・所有/寿命・route/channel独立性・synthetic信号

全アプリ起動や実機へ拡大しない。privateな呼出列だけを固定する巨大mockではなく、公開結果・保存結果・portへ渡した意味を観測する。構成と所有権の出発点は[設計案](architecture.md)を参照する。

#### UI表示leafのoracle

copy・format・静的な表示mappingは、View・window・bitmapを作らない`AppPresentationContractTests`でproductionのsemantic projectionを検証する。対象はSettings各tab・Mixer header/footer・route menu・keyboard/AutoEQ bindings・device row actionsである。ここでは意味値だけを確認し、glyphの可視性や実際のcontrol接続は証明しない。

実AppKitの描画を伴う検証は`AppRenderedTests`に集約する。production Viewをoffscreenの`NSHostingView`へ描画し、実`NSWindow`のconfigured size、native bridge（`NSSwitch`・`NSSegmentedControl`・`NSButton`）、SwiftUI buttonの描画bounds、status itemのactionを確認する。OCR・pixel probe・ScreenCaptureKit・pointer event loop・private SwiftUI proxyは使わない（[renderedTestSupport.swift](<../Tests/AppRenderedTests/renderedTestSupport.swift>)）。表示文字の認識はVisionの結果が環境に依存するため自動ゲートのoracleにせず、選択badgeのfill/glyphやslider trackの寸法もsemantic projectionの値で確認する。bitmap全体の一致や実際に描画されたpixelは保証しない。

status-item testは実`NSStatusItem`の探索・所有actionを検証するため`NSStatusBar.system`へ一時的にitemを作り、test内の`defer`で除去する。popoverは開かず、mouse eventもOSへ送らない。

非描画のrouting・Root・policy suiteは`AppCompositionTests`に置き、共有routing fixtureを`AppTestSupport`経由で参照する。両bundleは製品App module（FineTune）を参照するためAppKit/SwiftUIへのlink依存を持ち得るが、test自身が描画経路を実行しないことを境界とする。

視覚的な回帰は自動ゲート外で、代表状態のスクリーンショットと人間によるレビューで確認する。描画時間や撮影成功率の改善は主張しない。

### 限定した実機観測

権限・hardware・OS固有の仮説を確認する必要がある場合だけ、事前に対象と安全条件を決めて実行する。通常CIのunit/componentを成立させるために実機・録音・権限承認を必須にせず、optionalなhardware/E2E証拠をunitのpassへ合算しない。

実装が存在することと、aggregate/channel対応・切替・初音・idle復帰が実機で十分かは別の判断である。物理HALのsample rate/channel map、権限取消、sleep/wake、長時間稼働、callback deadline、実音声の正しさは自動ゲートの保証対象外で、方式の適否を判断する限定観測の対象とする。仮説ごとの確認条件は「実音声を確認するときの安全条件」を参照する。

## ゲートの判定原則

- 各runnerの非ゼロ終了は失敗である。成功件数の合計や過去のreportで覆わない
- parameterized declaration一つと実行row複数は別で、宣言数を実行数と混ぜない
- SwiftとC++の成功を加算して総成功数を作らない
- 元の静的呼出し数を固定比較の基準にせず、欠落を覆う総数だけの比較もしない
- sourceを変更したら同じconfigurationで再実行する。過去の結果は現在の証拠にならない
- 同じconfigurationの結果だけを比較する。debugとrelease、ローカルとCIは環境が異なり、別OS/configurationのpassを代替証拠にしない
- CI設定が存在することとCIがpassしたことは別の事実である

## DSPとnative境界

[offline DSP executable](<../Tools/DSPTests/main.cpp>)はproductionと同じ実装を合成信号で動かし、次を確認する。

- 初音・短い片側入力・無音中のfilter tail・無音後の再開
- 任意buffer分割での同一結果、route/channelごとの履歴独立
- bypass/再有効化・configuration交換・不正設定と非有限信号の明示errorと復帰
- C形式のbuffer契約・native-owned係数・停止後回収の前提・C++ heap allocationの検出

C++ named unitへ移した原作シナリオは、Swiftのreportとは別のnative機械reportで対応付ける。元Swift methodが消えたことだけで欠落と判定せず、入力・許容差・新unitの実行結果をreviewする。

debug・release・sanitizerなど複数のconfigurationを別の証拠として実行する。一つのconfigurationのpassは別のconfigurationの証拠にならない。数式の出典と検証の限界は[数値互換記録](<../Tools/DSPTests/Compatibility.md>)を参照する。

allocationの検証は、Stage/HAL callbackで計測したordinary/aligned C++ new/deleteとowned fake OS resourceのcounterに限る。他suiteで公開していないcounterを0と補完せず、全C malloc/free・CF/OS allocationの不在を主張しない。allocation検出やASan/UBSanの成功は、実機callbackのdeadline・lock/wait・ARC・全concurrent handoff・PACを証明しない。停止/quiescent前提の所有契約を、稼働中の交換安全性へ読み替えない。

## 実音声を確認するときの安全条件

実行前に、source app・output device・音量上限・開始/停止・録音保存の有無・失敗時の復帰を明示する。ユーザーの許可なしに音声を取得/再生したり、システム音量・default device・権限設定を変更しない。この観測は通常のゲートに含めない。

必要な仮説に応じて次を分けて確認する。

- 1 app → 1 outputの開始/停止と、部分失敗時のsilence・資源回収
- format/sample rate/channel map・aggregate・default変更・切断/再接続
- 初音・idle後の短音・長時間稼働・sleep/wakeと権限の取消/復帰
- software/hardware/DDC/Bluetoothなどbackend別のvolume/muteと保存復元

### AudioProbeの操作範囲

[AudioProbe](<../Tools/AudioProbe/main.swift>)は同じproduction Nativeを使うconsumerで、検証専用の音声実装ではない。起動方法は[開発手順](development.md)に譲り、ここでは観測範囲と安全条件を扱う。

`--help`と不正引数の処理はproducer構築前である。引数省略と`--list`は実device/processのread-only discovery、`--describe`は指定outputのmetadata読取である。これらはcaptureしないが、OSへ触れないunitとは区別する。`--capture`では`--app`・`--process-revision`・`--output`・`--seconds`を明示し、現在のapp/process bindingを使う。時間は(0,30]秒でprepareを含むdeadlineがあり、cleanup待ちの上限は追加2秒である。blocked OSやPENDINGを安全解放済みとは扱わない。source appはtap中mute、EQ/AutoEQ/loudnessは無効、`--gain`は0…1で既定unityである。音量の安全確認を省略しない。main usage description・armed・first-appliedは権限許可の証明ではなく、失敗時は診断と終了結果を確認する。

事前許可を得た限定観測であり、機能ごとに巨大E2Eを追加する要件にはしない。

### 経路無効化の診断

`bindingChanged / certifyFormat / -5101`はローカルの経路無効化コードで、HALの個別エラーやproperty selectorを表すものではない。`resolveOutput`の拒否もHALのOSStatusではなく条件別のローカルコードを返す（-5110 identity、-5111 input channels、-5112 aggregate、-5113 stereo order、-5114 layout、-5115 sample-rate disagreement）。いずれも`unsupported`のまま条件を区別する。表示は条件別の説明を出し、汎用の「unsupported format」で原因を隠さない。rate disagreementはデバイスがformat遷移中の一時状態でも成立するが、この区別は再試行可否の判断ではなく、失敗後に状態が戻っても原因を特定できるようにするためである。

nativeは無効化時に最初に記録権を得たイベントだけを保持する。property通知のobject・件数・最初のaddressと、IO callbackのdevice・入力構成・出力構成・出力データ欠損・frame不一致を区別する。この記録はイベント全体の発生順や根本原因の証明ではなく、既存の証明条件を緩めない。通常idle・DSPエラー・無効化前の状態から理由を推測して埋めない。

`FINETUNE_AUDIO_DIAGNOSTICS=1`で起動した場合、Swiftの非リアルタイム側がこの記録を既存の`AudioRoute`ログへ出す。音声サンプル・buffer pointer・property配列は記録せず、callback内ではログやHAL呼出しを行わない。[production C境界とfake HALのテスト](<../Tests/NativeHALContractTests/main.cpp>)は理由の区別・同時通知・reader-zero後の履歴・遅延callbackを検証するが、実際に報告された無効化の原因を再現した証拠ではない。実機の再起動・captureは、対象アプリ・出力・時間・音量と復元条件を確認してから行う。

## 製品組立と配布

composition testは実Graph/表示model/Host/lifecycleと外部portを使い、同じControl・store・nativeへの接続を確かめる。観測health・default policy・await後の最新payload・early URL・input停止・repeat取消・stop/flushは公開結果として検証する。Quitは終了通知で同期的に入力停止・HUD終了・設定flushを行い、非同期の音声回収を終了条件にしない。Hostの公開delegate capabilityと、入力停止・保存結果をcomponentで確認する。

fake-portの呼出0は実Root起動がglobally OS-inertである証拠ではない。Root constructorの構築時副作用、capture希望とmain metadataの扱い、plistの分離の仕組みは[設計案](architecture.md)を参照し、ここでは検証の境界だけを扱う。

配布では、対象OS/architecture・entitlements・usage description・bundle identity・署名・公証・更新/アンインストールを別の確認として扱う。原作のユーザー設定のimportはユーザーが明示的に選ぶ操作でなければならず、テスト実行で本物の設定を移行・変更しない。

## 保証対応の対応関係

原作の保証シナリオと新unit/componentはmany-to-manyで対応する。unitで十分ならE2Eへ拡大せず、保証が保たれるなら分割・統合・fixture置換を許容する。理由のない削除・入力削減・許容差緩和・skip・known-issue隠蔽でpassを作らない。

対応は次のとおりである。構成の詳細は[設計案](architecture.md)を参照する。

- copy・format・静的な表示mappingは`AppPresentationContractTests`、実AppKitの構造・幾何・native bridgeは`AppRenderedTests`、非描画のwiringは`AppCompositionTests`に分ける。OCR・pixel probeは使わず（前節参照）、描画時間や撮影成功率の改善は主張しない
- 物理default出力・入力のpolicy契約は`ControlTests`がclock/writer portを注入して確認する。deadline付きの保証と、default追従中の再試行も同じsuiteで扱う
- test専用の共通helperは`AppTestSupport`に置き、製品targetの一部にしない
- 注入したclock/transportは登録数・event・task完了を同期点とし、固定delayを同期点にしない。deadline超過・cancel時はtaskをcancelし、fixtureを解放してから別の期限内で終了を確認する。解放後も終了しないtaskを成功扱いしない
