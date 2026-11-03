# 検証方針

## 何を保証するか

原作の意図された用途と、新設計の公開境界を検証します。
元の保証を十分に確かめられるunitを優先し、テストの完全一致・件数維持・旧内部構造の復元は目的にしません。
分割・統合・fixture置換は[対応台帳](<../Tests/UpstreamCompatibilityTests/migrationManifest.json>)と独立reviewで説明します。
原作issue/PR由来の改良は今回の移植から分離します。

**unitの成功、製品consumerの接続、実機動作、配布可能性は別の判定です。**
未実装のruntimeを単なる実機未検証と言い換えず、componentがあるだけで機能完成ともしません。

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

### 3. 限定した実機観測

権限・hardware・OS固有の仮説を確認する必要がある場合だけ、事前に対象と安全条件を決めて実行します。
通常CIのunit/componentを成立させるために、実機・録音・権限承認を必須にしません。
optional hardware/E2E証拠は、未実施のままunitのpassへ合算しません。

## 通常の自動チェック

```bash
just check
```

[Justfile](<../Justfile>)はformat lint、監査器のmutation tests、debug/releaseのpackage build・unit/component、
offline DSP・移植監査を実行します。App bundle buildは含めません。
通常チェックはアプリ起動・音声取得/再生・権限要求・本物の設定移行・実機音量変更を行いません。

個別実行:

```bash
just audit-tests
just test
just test-dsp
just audit-upstream
just test release
just test-dsp release
just audit-upstream release
```

source snapshotはテスト直前に取得し、同じconfigurationのfreshなイベントと照合します。
ソースを変更したら既存イベントを成功証拠として再利用せず、再実行します。
[監査器](<../scripts/auditUpstreamTests.py>)の`--static-only`はreview/静的照合専用で、runtime gate成功ではありません。
手順・JSONL/XMLの読み方・many-to-many対応・独立reviewは[テスト移植](<test-migration.md>)にまとめます。

CI設定があることと、CIが実際にpassしたことは区別します。
ローカルのmacOS/Xcode/Swift版、CI環境、deployment targetの実機結果もそれぞれ記録します。

## DSPとnative境界

[offline DSP executable](<../Tools/DSPTests/main.cpp>)は本番と同じ実装を使い、合成信号で次を確認します。

- 初音・短い片側入力・無音中のfilter tail・無音後の再開
- 任意buffer分割での同一結果、route/channelごとの履歴独立
- bypass/再有効化・configuration交換・不正設定・非有限信号の明示errorと復帰
- C形式のbuffer契約・native-owned係数・停止後回収の前提・C++ heap allocationの検出

C++ named unitへ移した原作シナリオは、Swift JSONLとは別のnative機械reportで対応付けます。
元Swift methodが消えたことだけで欠落と判定せず、入力・許容差・新unitの実行結果をreviewします。
数式の出典・ISO資料の確認限界・sanitizer結果は[数値互換記録](<../Tools/DSPTests/Compatibility.md>)を参照してください。

allocation検出やASan/UBSanの成功は、実機callbackのdeadline・lock/wait・ARC・concurrent handoffをすべて証明しません。
停止/quiescent前提の所有契約を、稼働中交換の安全性へ読み替えません。

## 実音声を確認するときの安全条件

実行前に、source app・output device・音量上限・開始/停止・録音保存の有無・失敗時の復帰を明示します。
ユーザーの許可なしに、音声を取得/再生したり、システム音量・default device・権限設定を変更しません。

必要なproduction runtimeが実装された後、条件に応じて次を分けて確認します。

- 1 app → 1 outputの開始/停止と、部分失敗時のsilence・資源回収
- format/sample rate/channel map・aggregate・default変更・切断/再接続
- 初音・idle後の短音・長時間稼働・sleep/wakeと権限の取消/復帰
- software/hardware/DDC/Bluetoothなどbackend別のvolume/muteと保存復元

AudioProbeを追加する場合もproduction nativeを共有するconsumerに留め、検証専用の別音声実装を作りません。
これらは必要な仮説の限定観測であり、機能ごとに巨大E2Eを追加する要件ではありません。

## 製品組立と配布

Appのfactory/依存と少数composition testで、表示・Control・store・native portの接続と停止/flush lifecycleを確かめます。
表示componentの成功だけで、Mixer・Settings・URL・AutoEQ import・routingなどの製品consumer完成とはしません。

`just build-app`は明示opt-inの署名無効開発bundle buildです。
XcodeのbuildだけでもLaunchServices/execution-policyへbundleを登録する場合があるため、通常チェックから除外します。
CIのbundle buildは使い捨てrunnerの別stepです。アプリ未起動と、登録副作用なしは同義ではありません。
実配布では別途、対象OS/architecture、entitlements・usage description・bundle identity、署名・公証・更新/アンインストールを確認します。
原作のユーザー設定を勝手に開かないことと、明示的なimport/移行の安全性も別の受入条件です。
