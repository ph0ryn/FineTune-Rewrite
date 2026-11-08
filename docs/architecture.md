# FineTune-Rewrite アーキテクチャ

## 設計意図・現実装・未検証を分ける

初期の設計案を出発点に、構成・責務・依存・実行時の所有権を整理する。
初期の設計案を検証済み仕様とは扱わず、以下の責務境界、現在接続されている実装、実機で未確認の事項を区別する。
実装状況と開発手順は[README](<../README.md>)、試験対象・証拠と確認条件は[検証方針](<validation.md>)、作業の前提は[開発ガイド](<../AGENTS.md>)で扱う。

## 責務と依存の境界

| 境界 | 担当する責務 | 持ち込まない責務・依存 |
| --- | --- | --- |
| App | SwiftUI／AppKitによる表示・操作受付と依存の組み立て | UI独自の経路判断・音量解釈 |
| FineTuneDomain | OSに依存しない値・識別・音量の意味・経路選択ルール | OS・UI・native実装とOSの生のハンドル |
| FineTuneControl | 操作の受付、状態更新、変更計画、要求の世代管理、外部操作のprotocol | 具体的な機器操作・保存方法・Platform実装 |
| FineTunePlatform | macOS監視・明示directoryの永続化・機器操作・native実装へのadapter | 各adapterの責務を統括する巨大な管理層 |
| NativeAudio | tap・aggregate・IOProc、音声経路の実行・交換・資源管理 | 出力優先順位などの製品仕様の判断 |
| AudioDSP | 音声処理の計算と処理履歴 | Core Audioの機器操作・Foundation・UI |

コード上の依存方向を次に示す。ライブラリの具体的な宣言は[ビルド設定](<../Package.swift>)を正本とする。

```text
App             → FineTuneControl, FineTunePlatform
FineTuneControl → FineTuneDomain
FineTunePlatform → FineTuneControl, FineTuneDomain, NativeAudio
NativeAudio     → AudioDSP
```

Controlが必要な操作のprotocolを定義し、Platformが実装し、Appが組み立てる。
Controlから具体的なPlatform実装への依存を避け、制御ロジックをOS・実機から独立させる。
PlatformはOS固有の情報をDomainの値へ変換し、機器監視・保存・DDC・音声実行のadapterを分離する。

NativeAudioとAudioDSPを分けるのは、機器接続や資源の寿命の問題と、入力波形に対する計算・処理履歴の問題を別々に検証するためである。
aggregateやコールバックの構成はDomain・保存設定・UIの前提にせず、音声経路の方式を変えてもユーザーの希望を表すモデルを維持する。

## 言語とビルドの分担

| 領域 | 言語・管理単位 |
| --- | --- |
| UI・仕様判断・制御 | Swift 6 |
| macOSとの接続 | Swift中心。native側で必要なOS API接続だけObjective-C++ |
| 音声コールバック・DSP・音声資源の寿命管理 | C++20 |
| アプリのbundle・main metadata・リソース、署名・配布の設定 | Xcodeアプリプロジェクト |
| ライブラリの依存・テスト・検証用プログラム | ローカルSwift Package |

フォルダ分けだけでなくbuild targetで依存方向を表し、SwiftとC-familyのtargetを分けて所有権と依存を明示する。
C++を選ぶ意図は、音声処理中に触れるメモリと実行する処理を限定しやすくすることであり、言語変更だけで性能改善や不具合解消を保証するものではない。

## Swiftとnativeの公開境界

C++の型や所有権をSwift側へ広げず、小さなC形式のAPIを公開境界とする。

- 公開する値はopaque handle、固定幅の数値、単純な構造体、ポインタと要素数、明示的な結果コードを基本とする。
- C++のクラス・STLコンテナ・Objective-Cオブジェクトを公開せず、C++例外を境界の外へ出さない。
- AudioDSPのC++ヘッダーはnative実装内で扱い、Swift向けの公開ヘッダーから露出させない。
- Swiftの一時的な配列・文字列へのポインタを呼び出し後まで保持しない。必要なデータは呼び出し中にnative側の所有へ移すかコピーする。
- 音声バッファごとの処理はHALのコールバックからNativeAudio、AudioDSPへ進み、Swiftを経由しない。Swiftは設定変更と状態取得を担う。

ここでは公開境界の契約を示し、個別APIの名前や型は規定しない。

## 状態の所有と操作経路

| 状態・資源 | 所有する境界 |
| --- | --- |
| ユーザーの希望、観測したOS状態、変更要求の世代 | SwiftのControl |
| UI表示用snapshot | MainActor上の表示モデル |
| tap・aggregate・IOProcの生成、停止、破棄 | NativeAudioの非リアルタイム制御経路 |
| フィルター係数などの完成済み設定 | 非リアルタイム側で構築し、リアルタイム側へ公開 |
| フィルター履歴、ramp、limiterの内部状態 | その経路を実行するコールバック |
| メーター、処理回数、適用済み世代 | リアルタイム側で記録し、非リアルタイム側が回収 |

保存するユーザーの希望、OSからの観測状態、実行中の経路を分離する。
機器切断時の一時的な代替で保存済みの希望を失わず、再接続時の復元に使えるようにする。
永続的なアプリの識別と、現在のプロセス・OSの実行時オブジェクトも区別する。

UI・キー操作・URLなどの入口をControlの共通の操作へ通し、各入口が独自に保存や音声実装への反映を行わない。
UIの百分率、PCMの倍率、dB補正、機器側の音量を混同せず、保存値の意味を維持する。

## 現在の製品組立

[ProductionRoot](<../App/Bootstrap/productionRoot.swift>)が一つのSettingsManager、機器/process producer、機器操作model、入出力policy、Native runtimeを保持し、
[ApplicationGraph](<../App/Bootstrap/applicationGraph.swift>)へ同じ依存を渡す。EngineとControllerはその観測を使い、AutoEQ repository/cacheも共通である。
Mixer・Settingsのread/action、キー操作、URLはこの同じControl/storeへ接続する。Settingsのread closureも同じ表示modelを参照し、Rootの別コピーを作らない。
表示snapshotはpure projectionであり、Rootに第二の経路planner・設定集合・download registryを持たせない。

- **希望と実観測:** default追従に使うpolicy承認済みUIDは、物理的に観測したOS default UIDと別である。復帰write失敗でもOS観測を偽装せず、固定先・追従の希望を維持する。
- **観測の健全性:** inventory未開始、discovery失敗、input/outputそれぞれのdefault読取失敗を扱う。last-good UIDをhealthy-currentへ補完しない。失敗中は新prepareやpolicy writeを抑え、利用可能な旧routeは保持できるが、Nativeでbinding無効が確定したrouteは閉じて回収する。
- **非同期の適用:** prepare前のpayloadを有効化時まで固定しない。各await後に世代・binding・default追従先を確認し、start/commitでは現在の設定からstateを作り直す。request受理、armed、commit、first-appliedは別の観測である。
- **Processの識別:** shared producerのprocess revision照合と、Nativeが行うCoreAudio process object→PID再検証は別である。revision一致だけでOS上の同一processを保証しない。

### Lifecycleと構築時の副作用

[coordinator](<../App/Bootstrap/lifecycleCoordinator.swift>)がstart/stop・sleep/wake・session状態・終了時の入力停止/flushを所有する。
[Host](<../App/Bootstrap/applicationHost.swift>)の終了通知で同期的に入力を止めて設定を保存し、RootはHUDも終了する。
原作と同じ通常のAppKit終了に従い、`terminateLater`や非同期のroute回収完了は待たない。
プロセス終了時のOS回収と、通常のstopが返すNative回収結果は別の契約であり、終了できたことを全資源のdrain成功とは扱わない。
one-shot observationはsuspended中も同じ世代で再登録するが、running時だけ通常のeffectを実行する。
wakeでは現在のdefault読取healthとEngine観測を先に取り込み、policyをrebaseし、最後にcaptureを再開する。
input停止はmedia keysだけでなくglobal shortcutsの登録解除とrepeat task取消に及び、suspend/stop中は保持されたRegistry callbackも効果を持たない。
coordinatorの世代付き観測callbackはstop/restart後に旧世代を拒否する。Registry再start後のforeign retained callbackや、OSのqueued key-up順は未測定である。

製品Rootのconstructorはglobally OS-inertではない。設定のdisk load/不正file backupと、non-prompt Accessibility trust queryがある。
profile repository/storeのconstructorは依存保存とURL検証のみで、local profileのdisk復元はservice開始時に行う。
Graph/VMの注入portを使う0-call unitは、実Root起動の0 I/O保証やNSWindow解放の実測ではない。

capture希望は新規・欠損設定でfalse、保存済みtrueはdurableな希望である。Controlは新sessionを作り、保存tokenを再使用しない。
main executableのusage descriptionと保存希望はOS grantではなく、metadata欠損時はNative前にfail closedする。
SwiftPM版App、Xcode App、独立Probeのmain metadataは区別する。

## 経路変更と音声資源の寿命

### 準備・交換・回収を分ける

新しい経路には必要な音量・補正・フォーマットを適用してから有効化する。
変更要求の世代を管理し、準備完了時と有効化時に要求が最新か確認して、古い非同期処理が新しい希望を上書きしないようにする。
actorを使うことだけで、非同期の経路変更全体が不可分になるとは扱わない。
要求の受理と実際の適用を区別し、失敗や復旧の成否を観測できるようにする。

交換先のarmedは、証明済みのbuffer構成・一致する正のframe数を持つ出力callbackによるtransportの準備完了を表す。
入力のデータpointerだけが欠けた通常idleでも成立するが、権限許可・音声取得成功・first-appliedの証拠ではない。
idleではDSP履歴と適用済みrevisionを進めず、破損したmetadata・欠けた出力・frame数0ではarmedにしない。
これにより、旧物理出力の停止を、無音のsource appが次に再生する時刻へ依存させない。

取消済みcandidateはcallbackの受付を閉じても、OSのIOとsource muteが自動で止まるわけではない。
継続用のread ownerとして保持せず、次のcandidateのarmedを待たずに非リアルタイムの回収を開始する。
Controlの取消はownerごとに一度だけ通知し、遅れて終了した旧処理から再通知してPENDING回収の監視を止めない。
資源の解放は引き続き実際のreader-zeroとretired ACKを待つ。回収失敗の結果はownerとともに保持し、後のhandoffから自動再試行しない。
明示的なcapture Retryは、Controlが保持する終了済みの失敗taskだけを再試行する。進行中・PENDINGの回収は共有し、旧ownerを再びrender可能にはしない。
回収中の観測はその試行のcleanup結果を伝え、native snapshotの履歴診断と分ける。同じエラーの再発や、retired ACKに付随する現在のエラーは失敗のまま扱う。

音声処理にはUI・保存・非リアルタイムの資源管理を持ち込まない。
tapなどの生成・停止・破棄やObjective-Cのオブジェクト操作は非リアルタイム側が担う。
旧経路の回収で新経路が利用する資源を破棄しないよう、所有と参照の終了を区別する。

### DSPの可変状態を実行経路ごとに持つ

論理的な処理単位はアプリ×出力機器とし、機器別の補正と処理履歴を独立させる。
切り替えで旧経路と新経路が重なる場合も、同じアプリ・同じ機器だからという理由で可変状態を共有しない。
不変の設定・係数の共有と、コールバックが更新する処理履歴の共有は区別する。

### 設定の公開と旧資源の回収を分ける

完成済みの設定を公開することと、古い設定・経路を解放できることは別の条件である。
コールバックの参照終了を確認してから非リアルタイム側で回収し、固定時間の待機やatomicなポインタ交換だけを参照終了の根拠にしない。

コールバック構成に応じて受け渡し方式を選び、実際の読み手の数に合わないqueueの共有をしない。
単一の読み手を前提とした方式を、複数機器のコールバックでそのまま共有しない。
現実装はcallback slotの参照終了を確認し、native-owned stateを非リアルタイム側で回収する。
同期処理の正本は[Native runtime](<../Sources/NativeAudio/Runtime/>)に置き、ここへAPIやalgorithm全体を複製しない。

### 現在のNative経路と回収結果

app×outputの各routeがtap・private aggregate・IOProc・DSP資源を所有する。
private aggregateのtap drift/qualityは作成後に変更せず、証明のたびにOSからCompositionを読み戻して、所有tap UIDとの一意対応・数値型・値を検証する。作成時の要求辞書や既定値を観測の代わりに使わない。
SubTapListのIDはactive memberの同一性比較に使い、子objectのproperty読取・監視が可能とは仮定しない。aggregateのComposition・tap/subtap listと既存の物理機器・streamを監視し、start前にも再検証する。
同一process内の外部コードが子drift/qualityを直接変更する方式は対応対象外とする。子設定の変更が必ず親Composition通知になる保証や、実機での通知・音声の正しさを確認したという意味ではない。
初期対応は同じsample rateのFloat32 stereoと明示的なchannel/format certificateに制限し、未対応機器を黙示変換で隠さない。
所有する単一tapだけのaggregate入力では、streamのdevice property用開始番号とIOProcのbuffer位置を分け、正の開始番号から連続するstereoと実際のbuffer構成を照合する。raw開始番号自体をRTのoffsetやcertificateの不変値にはしないが、変更通知の監視は続ける。
物理/aggregate出力のchannel 1/2、入力の所有・構成・同一sample rateの検証は緩めず、tap入力の番号に合わせてサンプルのpointerやbuffer ordinalをずらさない。
source appをtap中muteする方式を使うが、実機での音響的な連続性を確認したものではない。

回収PENDINGは既存の20ms pollで実際のreader/aggregate条件を再確認する。FAILEDはownerをretainして報告し、自動failure retryを止める。
所有aggregateへのstop・IOProc破棄・aggregate破棄が`!dev`を返しても、それだけで回収済みとは扱わない。別のpresence queryが成功して不在を確認できた場合だけ、そのdevice操作を完了扱いする。listener・tapは個別に回収し、確認に失敗した場合や別のcleanup errorは所有権とともに残す。
20ms経過による安全freeではない。あるrouteのretired ACKや残ったhistory diagnosticから、private pool全体のdrainやglobal orphan0を推論しない。
通常のOS/input observerは停止するが、single factoryのweakなpassive cleanup変更通知はstop後も表示modelへ残す。
factoryは履歴の最新診断と、経路ごとの未解決cleanupを分けて保持する。poolは該当ownerのnative release成功時だけ完了を通知し、その経路の警告を解除する。
この通知は新しいcapture・route操作・Rootの二重timerを開始せず、権限やglobal回収完了の証拠でもない。

## 実機で未確認の事項

上記の初期実装が存在することと、aggregate/channel対応・切替・初音・idle復帰が実機で十分かは別である。
物理HALのsample rate/channel map、権限取消、sleep/wake、長時間稼働、callback deadline、実音声の正しさは未確認である。
方式の適否を判断するための限定観測と安全条件は[検証方針](<validation.md>)で扱う。
