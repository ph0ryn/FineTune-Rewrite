# 互換方針

## 比較元と今回の出口

比較元は[FineTuneの固定revision](https://github.com/ronitsingh10/FineTune/commit/2285279d36d3f8115c1c2d4aecd904f1bdf96a51)
`2285279d36d3f8115c1c2d4aecd904f1bdf96a51`です。最新mainへ追従しません。
機能・UI・操作・設定・外部連携の基本用途を比較し、内部class構造・処理順序・旧実装の制約まで複製することは要求しません。

現在のテスト移植では、原作54ファイル・758宣言・静的966呼出しを元の保証の参照母数として扱います。
最終test数・元本文の一致そのものではなく、保証シナリオから新しいunit/componentへの対応と独立reviewを出口にします。
[確認手順](<test-migration.md>)と各テストの出典ヘッダで追跡します。
原作issue/PR由来の改良は、今回の移植へ追加しません。

この固定版に対する移植時の独立review・実行監査は完了しました。以下は専用監査の削除前の記録で、現在の`just check`で監査を再実行するものではありません。
元の分類は**A550/B205/C3**を維持し、新設計の追加保証は独自Dとして分けています。
最終Debug/Releaseは各**Swift 1055宣言/1349呼出し（7 products）**と
**C++ 49 named units/6654呼出し（6 programs）**がpassし、完全監査は両方errors0です。
有限入力の展開と実function/case終了を照合した結果であり、元966との件数合わせではありません。
[実行証拠の読み方と限界](<test-migration.md#移植時に確定したsnapshot>)に詳細を記録します。
これは注入可能なunit/componentと静的な製品consumer接続の受入れで、
実機の音声・権限・OS event順序・GUI見た目・長時間/RT deadlineまで完了したという意味ではありません。

## 保持する意味

- アプリ・機器のvolume/mute/boost、software sliderの意味、経路選択と保存希望
- 一時的な機器切断や適用失敗で、ユーザーが保存した希望を破壊しないこと
- 表示設定・ショートカット・HUD・アイコン・EQ presetなどの保存値と選択の意味
- UI・キー・URLなど入口が異なっても、Controlの共通操作へ合流すること
- 独立したroute/channelごとのDSP可変状態と、初音・無音区間後の再開を失わないこと

fieldやadapterの存在だけで、製品のconsumer接続や実機動作まで完成したとは判断しません。
構成と所有権の出発点は[設計案](<architecture.md>)、保証レベルは[検証方針](<validation.md>)に分けます。

## Mixerの表示互換

音量スライダーと上部・下部の操作は、同じ固定版の原作UIを基準にします。
[共通スライダー](<../App/Design/mixerVolumeSlider.swift>)は4ptの軌道とhover/drag時のnative mini thumb、
[ヘッダー・フッター](<../App/Features/Mixer/mixerChrome.swift>)はspeaker/mic切替、鉛筆/checkmark、塗りの歯車、下部の`Quit ⌘Q`を使います。
[入出力デバイス行](<../App/Features/Devices/deviceRow.swift>)は、名前の隙間と上下の余白を含む行の非操作部分からdefaultを切り替えます。
ミュート・音量・パーセント入力は行の切り替えを伴わず、すでにdefaultの行を再選択しても再書込しません。
[選択中バッジ](<../App/Design/deviceBadge.swift>)は原作の28pt円形・アクセント色gradient・白いglyphを使い、未選択時はmono表示にします。
選択はOSの観測defaultに従い、既存checkmarkも残します。クリック直後の先行表示や切り替え中表示ではありません。
音量のbinding・未知値/読み取り専用表示・共通command・現行の⌘Q操作・全行の非スクロール表示は維持します。
原作のDonateや音声処理、機器の欠損値fallbackは移植しません。
ミュートのdim表示とnative待機時のopacityは分離し、合成opacityがhit-test閾値を下回って音量操作を失うことは再現しません。
[アプリ行](<../App/Features/Mixer/mixerAppRow.swift>)は28pt headerと上下6pt・左右8pt paddingの40pt行にし、
VU・24pt app icon・名前・mute・共通140pt slider・40pt percentage枠・boost chevrons・出力先icon・EQ iconを1行に並べます。
名前や余白にはactionを付けず、active appのiconだけが既存activate actionを呼びます。
停止中の装飾はdimにしますが、sliderの祖先opacityは下げず、音量操作を維持します。
通常は背景を透明にし、hover・focus・EQ展開時に共通hover surfaceを使います。EQ panelの内部操作は変更しません。
[出力先picker](<../App/Features/Mixer/mixerAppRoutePicker.swift>)は28pt icon triggerとSingle/Multi・check/checkboxの210pt menuを使い、
popoverの外側クリック・dismiss・window所有はnative SwiftUIへ任せます。mode/UIDの先行状態は持たず、選択は観測値に従います。
通常のfollow-defaultは名前の下に表示せず、明示経路・multiの要約だけを9pt subtitleにします。
機器がなくなったUIDのUnavailable表示、明示routeStatus、観測level欠損と実測0の区別は隠しません。
この表示変更ではappの既存mute commandを維持し、原作の0%時クリックによるgain 1.0復元までは移植しません。
[アプリsection](<../App/Features/Mixer/mixerView.swift>)はAPPS見出し・通常0pt行間・編集時2列/4pt間隔・独立したIgnored grid・中央の空表示を使います。
表示順はpinned active→pinned inactive→unpinned activeを基本とし、各group内をlocale-awareなcase-insensitive名順にします。
同名は永続IDで決定し、編集時のみ出すunpinned inactive metadataとignoredも末尾の別groupで維持します。
表示とkeyboard navigationは同じprojection順に従い、保存済みのpin/ignore値やRootの経路所有は変更しません。
全Mixerのpixel単位の一致を保証するものではありません。

[表示回帰テスト](<../Tests/AppRenderedTests/MixerControlAppearanceTests.swift>)はfakeを接続した実コンポーネントをoffscreen描画し、
3つのpopup sizeとlight/darkのidle軌道・icon headerを確認します。
専用window内のnative pointer eventで、通常/ミュート時の音量操作とtab・編集・設定・Quitのfake actionも検証します。
入出力それぞれで3つのpopup sizeの行内余白をクリックし、内部controlとの操作分離とdefault再書込の抑制を確認します。
選択中バッジはlight/darkの実bitmapと、観測default変更後にaccent表示が消えることを確認します。
`FINETUNE_MIXER_CONTROL_EVIDENCE`に出力先を指定すると、その描画PNGを保存できます。
[アプリ行テスト](<../Tests/AppRenderedTests/AppRowPresentationTests.swift>)は3つの幅でproduction rowをoffscreen描画し、40pt行・percentage位置・control frame/actionを確認します。
productionの`MixerAppRow`は`MixerAppRowPresentation`からname/subtitleを得ます。テストもその型のsemantic projection値をassertしますが、これは文字列内容の確認であり、実際のText nodeやglyphの可視性・遮蔽のない描画は証明しません。
active icon/name/mute/slider/boost/EQの操作分離と、停止中・ミュート・dark時の共通slider操作をnative pointer eventで確認します。
実際のpicker menuでもSingle/Multi/default/UID選択をfake actionへ通し、観測更新の前に選択状態を先行変更しないことを確認します。
`FINETUNE_APP_ROW_EVIDENCE`で行・picker menuの描画PNGを保存できます。
編集gridはproductionの2列layoutを3つの幅で描画し、44pt行送りと実際のpin/ignore/unignore buttonのapp ID別actionを確認します。name glyphの可視性を検証するものではありません。
[popupテスト](<../Tests/AppRenderedTests/PopupLayoutTests.swift>)はQuitの下部配置・⌘Qと、表示中の自然な高さ変更も検証します。
transientな親popup内で出力先pickerを実際に開き、child windowの出力行をクリックしても親を閉じず、対象appへroute actionが届くことを確認します。
これらの成功を、最小対応OSのnative thumb、実機音声、全UIの操作・見た目の検証へ拡張しません。

## デバイス切り替えと失敗からの復帰

出力デバイスの明示選択が成功したときは、default追従中のアプリの失敗した経路を再試行します。
入力の選択、失敗したdefault書込、固定先を持つアプリへは再試行を広げません。
経路先はpolicyが承認したUIDを使い、非同期のOS観測を待つ間に旧defaultへ再取得しません。
受動的な機器・process通知だけで失敗した取得を繰り返さないこと、既知の権限拒否は明示的な`Retry Audio`まで解除しないことは維持します。

FineTuneからの明示選択が成功した直後の2秒間は、健全なUID・Bluetooth構成が変わらない場合に限り、別のBluetooth出力への巻き戻りを1回だけ補正します。
この期限は補正や確認通知で延長しません。新しい明示操作、機器構成・観測の健全性の変化、suspendは古い補正権限を失効させます。
OS通知には操作元の情報がないため、この短い区間内のControl CenterからのBluetooth選択も区別できません。FineTuneからの再選択は常に最新の操作として扱います。
期限後の新しい外部選択は尊重し、古い書込の確認待ちやtimeoutで元へ戻しません。未解消の失敗は、時間経過や同じUIDの再通知だけでは消しません。
補正後も選択を維持できない場合や確認が期限切れになった場合は、無限に書き戻さず、Mixer・Settingsへ失敗を表示します。要求先の健全な観測または新しい選択で解消します。
観測されたdefault UIDとpolicy承認先は分けたままとし、補正で既存の健全なアプリ経路を強制作り直ししたり、captureの再試行範囲を広げたりしません。
この有限な補正と追従・固定経路の維持は、[policyテスト](<../Tests/AppPolicyContractTests/OutputPolicyTests.swift>)と[実Graphのテスト](<../Tests/AppCompositionTests/OutputPolicyRoutingTests.swift>)で確認します。
Bluetooth所有権を永続的に固定する機能ではなく、AirPods実機での補正効果・可聴連続性はこのテストの保証に含めません。

切り替えを取り消したcandidateは、callbackの受付を閉じたまま継続用のread ownerとして残さず、次の経路のarmedを待たずに回収を開始します。
取消はOSのIO停止やsource mute解除そのものではないため、実際のretired ACKまで所有権を維持します。
取消通知はownerごとに一度とし、遅れて返る旧start/commitがPENDING回収の進捗監視を再取消ししないようにします。
早期に始めた回収が失敗した場合、後の経路がarmedになっても同じ失敗結果を共有し、cleanupを暗黙に再試行したり失敗を消したりしません。
明示的なcapture Retryでは、Controlが保持する完了済みの回収失敗と、prepared handleを返せずnative poolに残った失敗ownerを再試行します。
進行中・PENDINGのtaskを二重実行せず、旧ownerのretired確認までは新経路をcommitしません。poolの再試行は同じfactoryのownerだけが対象で、新しいprepareはその試行の結果を待ちます。再び失敗したownerは保持と警告を続けます。
再試行に成功したときはnative snapshotに残った過去のcleanup failureを現在の失敗として再送せず、同じコードでも今回再発した失敗は表示とcommit阻止を維持します。
[経路の回帰テスト](<../Tests/AppCompositionTests/RoutingTests.swift>)は、取消済み経路のOS IOとrender許可を分け、
次のsourceが無音の間にも旧IOの停止が始まること、PENDINGと失敗を後のhandoffが正しく共有することを確認します。

nativeのarmedはsourceの再生開始ではなく、証明済み構成・一致する正のframe数を持つ出力callbackによるtransport準備完了です。
入力のデータpointerだけが欠けているidleでも旧経路を回収できますが、DSP履歴・適用済みrevision・first-appliedは進めません。
不正なbuffer構成、frame数の不一致、欠けた出力、frame数0、取消後のcallbackを準備完了として扱いません。
[production C境界とfake HALのテスト](<../Tests/NativeHALContractTests/main.cpp>)で、idle中の切り替えとsource再開後のgain ramp、
不正metadataの拒否、取消後のcallbackの無音化を確認します。権限許可や実際のAirPodsのcallback形状を証明するものではありません。
この修正はdefaultの補正回数やcaptureの再試行を増やしません。実機ログの重複tapとコード上の寿命問題は切り分け、Bluetoothへの巻き戻り・可聴音の解消は別途実機確認が必要です。

旧経路の既知のprimary failureは回収後も診断履歴に残しますが、成功した回収を失敗扱いして新経路のcommitを妨げません。
Controlが終了を開始した後、処理中のstart/commitが遅れて記録するprimaryの`cancelled`も回収失敗とは区別します。
それ以外の新しいprimary failure、cleanup failure、明示的な回収失敗は引き続きhandoffを止め、PENDINGは実際のretired通知まで待ちます。
終了を開始したownerは、古いcommitted観測が残っていても再利用や新しいupdateの対象にしません。
旧ownerの遅延updateによる意図的な`cancelled`は、現行の失敗表示を作成・上書きしません。
一方、終了を指示していない現行ownerの`cancelled`は失敗として扱います。
診断はアプリ単位で保持し、別アプリの取得成功、旧ownerの回収開始、新世代のprepareだけでは消しません。
そのアプリ自身のcommit後、再利用したownerを含む要求経路すべてが健全な場合に解除します。複数出力の一方の成功だけで、残す経路の障害を消しません。
Mixer・Settingsは、診断履歴と現在の警告を分けます。処理を希望している現在のアプリの失敗は、そのアプリ自身が復旧するまで表示します。
停止・アプリの終了・Ignore後は過去の経路失敗を警告しませんが、Controlの診断履歴とnative codeは保持します。
Mixerで表示中のアプリに属する失敗は通常モードの行だけに出し、上部へ重複させません。並べ替え中は行内の警告を表示せず、通常モードへ戻ったときに現在の状態を表示します。
権限拒否は共通の案内で示し、保存・機器操作などの独立した失敗は隠しません。

cleanupの警告は世代の新旧ではなく、資源をまだ所有しているかで判断します。
Controlの未完了回収と、prepared handleを返す前に失敗したnative経路の回収は、停止後やアプリ行がない場合も表示します。
Controlのretired ACK、またはnative poolの該当ownerのrelease成功が確認できた警告だけを外します。別ownerの成功や新世代のprepareでは解除しません。
nativeの最新診断は履歴として残し、未解決のcleanupは経路ごとに追跡します。この集合が空でも、エラーのないPENDING経路を含むpool全体のdrain完了は意味しません。
[経路の回帰テスト](<../Tests/AppCompositionTests/RoutingTests.swift>)で、default選択による再試行範囲、即時/PENDING回収、
遅延start/commit/updateとの競合、別アプリ成功時の障害表示と自身の復帰後の解除、
既知のbinding failure・旧sessionの拒否からの復帰と、新しい回収エラーを隠さないことを確認します。
[実Rootの表示テスト](<../Tests/AppCompositionTests/RootPresentationTests.swift>)で、Mixer・Settings・アプリ行の表示と、複数出力の片側故障が別出力のcommitで消えないことも確認します。
この保証はControlと表示の復帰契約であり、物理機器のformat検証・実音声・切り替え時の無音や連続性の保証ではありません。

nativeの入力検証では、所有する単一stereo tapと意図した物理機器だけの構成を読み戻した場合に限り、
streamの開始チャンネル番号が1より大きくても、連続した2chとIOProcのbuffer構成を照合して扱います。
開始番号5・stereo buffer 1個という実測例を、未対応formatやbuffer内の4ch offsetとは解釈しません。
[開始チャンネル番号](<https://developer.apple.com/documentation/coreaudio/kaudiostreampropertystartingchannel>)はdeviceのproperty element番号であり、
[StreamConfiguration](<https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertystreamconfiguration>)がIOProcのbuffer構成に対応します。
物理/aggregate出力は引き続きchannel 1/2を要求し、余分な入力・不連続な番号・不一致のformat/buffer構成は拒否します。
[共通のnative decoder](<../Sources/NativeAudio/Runtime/StreamLayout.hpp>)を通す
[native契約テスト](<../Tests/NativeHALContractTests/main.cpp>)で、開始番号5の新経路を旧経路と併存させて準備し、
arm・旧経路回収・commit後の左右のサンプル、壊れたbufferの無音化と不正な構成の拒否を確認します。
実機のprepare-onlyで同じ開始番号5の拒否が解消したことと、音出し・切り替えの連続性は別の検証です。

## Quitの互換

Quitボタン・⌘Q・アプリメニューは原作と同じ`NSApplication.terminate(nil)`へ通します。
[Host](<../App/Bootstrap/applicationHost.swift>)は`applicationWillTerminate`で同期的に入力監視を停止し、HUDを終了して設定をflushします。
比較元は固定版の[Quitボタン](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/MenuBarPopupView.swift#L368-L382>)と
[終了通知](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/FineTuneApp.swift#L246-L259>)です。
独自の`terminateLater`・非同期の音声回収待ち・保存失敗時の再試行/取消ダイアログは設けません。
保存失敗はstoreの`lastSaveError`に残りますが、原作同様、終了を取り消しません。
音声資源はプロセス終了時のOS回収に従い、通常のcooperative stopの回収結果・安全性契約は変更しません。
[Hostの回帰テスト](<../Tests/AppCompositionTests/ApplicationHostTerminationTests.swift>)は実delegateの公開capabilityを、
[lifecycleテスト](<../Tests/AppCompositionTests/BootstrapLifecycleTests.swift>)は同期保存結果・入力停止・古いcallbackの拒否を確認します。
このcomponent検証は、実音声中の終了や最小対応OSでの動作確認とは別です。

## 保存設定

[保存schema](<../Sources/FineTunePlatform/Persistence/savedSettings.swift>)と
[保存manager](<../Sources/FineTunePlatform/Persistence/settingsManager.swift>)を、隔離したdirectoryで検証します。

- 新規作成時はversion 12、version欠落/nullのdecodeは原作どおり9。未知の整数versionを勝手に移行拒否しない
- 欠落/nullと型不一致を区別する。既知keyのdefault・gain正規化・enum decodeを原作由来unitで確認する
- CRUD・直接binding・debounce・明示flush・reset・preset名検証を保存結果と観測可能なside effectで確認する
- login serviceは注入可能とし、読み込みだけで実ログイン項目を登録しない
- 不正JSONは原作方針に従いbackupして再開する。backup自体に失敗した場合は、そのmanagerの書込を抑止し、load/save errorを観測可能にする

新実装のdirectoryは必須の明示引数です。原作のApplication Support名前空間を暗黙に開きません。
原作設定のimportを実装するときも、ユーザーが明示的に選ぶ操作として設計し、今回のテスト実行で本物の設定を移行・変更しません。

## システムアラートの消音連動（原作にない独自動作）

原作のsoftware tierミュートはtap内のゲインだけで、tap外のシステムアラート音は消しません。
hardware/DDC tierは機器側のミュートでアラートも消えますが、HDMIなどhardwareミュートを持たない出力では
「デバイス無音」でも未処理キーのビープが鳴ります。この差は受け入れ条件の違いとして扱い、次の独自動作にします。

- System Soundsの出力先デバイスがsoftware tierでミュートされている間だけ、OSのアラート音量を0にする
- 解除時はミュート前のアラート音量へ戻す。hardware/DDC tierと、System Soundsに出ていないデバイスのミュートでは何もしない
- will-terminateでも同期的に戻し、保存した復元値は次回起動時に確認してから現在のミュートを評価する。終了と復元が競合しても値の取り違えを残さない
- 復元値は保存schemaの`alertVolumeBeforeMuteSilencing`にだけ置き、アプリ設定のAlert Volumeとは別に扱う。silencing中はSettingsのAlert Volume操作を無効化する

[policyと実際のモデルの接続](<../Tests/AppCompositionTests/SystemAlertSilencingTests.swift>)と
[実モデルのミュート往復](<../Tests/AppCompositionTests/DeviceBackendCompositionTests.swift>)で確認します。
OSのアラート音量を実際に変更する実機確認は別で、このunitの成功は実音声の確認ではありません。

## 新設計への適応

純粋な入力・出力契約は直接保持できます。一方、旧private API、未使用engineを抱えるfixture、
旧vDSP setupの所有、mock自身のdefault値、実OSへの無assert投稿などは、新しい境界へ置き換えます。
元の保証を弱めずにunitへ分割・統合できるなら、旧classを復元した巨大な互換facadeは追加しません。

具体例:

- aggregate/tapの初期設定は新planner・注入可能なroute portで確認し、legacyの呼出名や設定時刻を固定しない
- media keyのhandler/watchdogはactual monitorとControlを使い、OS tap・clock・HUD表示だけを隔離する
- メニュー操作のevent構築・dispatchはposter seamで確認し、test runnerの実event pumpへ投げるだけのsmoke testにしない
- signal helperはnative-owned係数copyへ適応する。旧検出位置・poisoned vDSP stateだけを要求する3件は、理由と有限出力・明示error・state resetの代替保証を個別記録する

DSPの数式・出典・3件の対応・offline検証限界は[数値互換記録](<../Tools/DSPTests/Compatibility.md>)にあります。
数学関数のIEEE境界と、実行可能なDSP設定・信号処理のerror契約は分けます。

## URL・外部操作と延期事項

原作の`finetune://` actions・query順序・validation・保存対象は、固定版の
[URLHandler](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Utilities/URLHandler.swift)を基準にします。
parserのunit、共通Control操作、App event/bundle登録は異なる保証であり、parserだけで製品連携完成とはしません。

原作guideの百分率表現と実装が異なる箇所について、URL値を新たに`s²`へ変更する案やboost拡張は**今回保留**です。
原作の現行処理・既知の問題・将来採用する変更を台帳で分け、無断で「互換修正」に含めません。
同様に、idle・初音・切替・再接続・長時間稼働などのissue/PR案は、将来の再現条件と別の受入条件を定めて扱います。

## ライセンス

原作由来のtest/fixtureと派生物はGNU GPL version 3です。
原作のcopyright表示とGPL本文は、アプリにバンドルする[THIRD_PARTY_NOTICES.txt](<../App/Resources/THIRD_PARTY_NOTICES.txt>)に一本化しています。
各テストの出典はファイル先頭のSPDXヘッダと[確認手順](<test-migration.md>)に記録します。
独立した[MIT License](<../LICENSE>)部分を維持し、下記のwhole-file GPL区分と混同しません。
GPL対象はテストやdataだけではなく派生codeも含むため、productionすべてをMIT-onlyとは表現しません。
GPL対象を含む製品binaryの配布時は、組合せ・対応source・通知とlicense提供等の条件を別途確認します。
テストの隔離だけで製品のGPL条件が消えるとは扱わず、現時点で法的適合性や配布完了を保証しません。

### 製品側の派生codeとdata

以下は現在実在するファイルのSPDX header・固定元path/revisionと実装者確認に基づく区分です。
各ファイル**全体**を`GPL-3.0-only`とします。固定元はすべて本文冒頭の比較revisionであり、最新mainへ変えません。

| 製品ファイル | 参照した境界 | 固定原作のsource |
| --- | --- | --- |
| [DeviceIconCatalog](<../App/DeviceIcons/DeviceIconCatalog.swift>) | 85項目・順序・category/keyword data | [DeviceIconCatalog](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Models/DeviceIconCatalog.swift>) |
| [systemAudioDaemonCatalog](<../Sources/FineTunePlatform/Devices/Observation/systemAudioDaemonCatalog.swift>) | bundle/name prefix語彙 | [AudioProcessMonitor:20–58](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/Monitors/AudioProcessMonitor.swift#L20-L58>) |
| [URLAutomationParser](<../Sources/FineTuneControl/Automation/URLAutomationParser.swift>) | URL grammar・値変換規則 | [URLHandler](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Utilities/URLHandler.swift>) |
| [deviceDefaultEchoes](<../Sources/FineTuneControl/Routing/deviceDefaultEchoes.swift>) | UID別の複数echo token・各2秒失効・消費規則 | [EchoTracker:4–73](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/Engine/EchoTracker.swift#L4-L73>) |
| [deviceBadge](<../App/Design/deviceBadge.swift>) | 選択中の28ptアクセント色gradientと未選択monoの円形バッジ | [DeviceBadge](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/Components/DeviceBadge.swift>) |
| [mixerVolumeSlider](<../App/Design/mixerVolumeSlider.swift>) | 4pt軌道・native mini thumbのhover/drag表示 | [LiquidGlassSlider](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/Components/LiquidGlassSlider.swift>) |
| [mixerChrome](<../App/Features/Mixer/mixerChrome.swift>) | icon header・tabs・Quit capsuleの表示 | [MenuBarPopupView](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/MenuBarPopupView.swift>)・[ViewModifiers](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/DesignSystem/ViewModifiers.swift>) |
| [mixerView](<../App/Features/Mixer/mixerView.swift>) | APPS section・2列編集grid・Ignored/empty表示 | [MenuBarPopupView](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/MenuBarPopupView.swift>) |
| [mixerAppRow](<../App/Features/Mixer/mixerAppRow.swift>) | 40pt行・icon controls・boost chevrons・hover/展開背景 | [AppRow](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/Rows/AppRow.swift>)・[AppRowControls](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/Rows/AppRowControls.swift>)・[AppEditRow](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/Rows/AppEditRow.swift>) |
| [mixerAppRoutePicker](<../App/Features/Mixer/mixerAppRoutePicker.swift>) | icon trigger・route subtitle・Single/Multi/check/checkbox表示 | [DevicePicker](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/Components/DevicePicker.swift>)・[ModeToggle](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Views/Components/ModeToggle.swift>) |
| [AutoEQCatalog](<../Sources/FineTunePlatform/Profiles/AutoEQCatalog.swift>) | INDEX解析・検索順位 | [AutoEQFetcher](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQFetcher.swift>)・[AutoEQProfileManager](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQProfileManager.swift>) |
| [ParametricEQTextParser](<../Sources/FineTunePlatform/Profiles/ParametricEQTextParser.swift>) | APO grammar・filter規則 | [AutoEQParser](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQParser.swift>) |
| [AutoEQProfileRepository](<../Sources/FineTunePlatform/Profiles/AutoEQProfileRepository.swift>) | 取得/cache/importの振る舞い | [AutoEQFetcher](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQFetcher.swift>)・[AutoEQProfileManager](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQProfileManager.swift>) |
| [ProfileFileStore](<../Sources/FineTunePlatform/Profiles/ProfileFileStore.swift>) | cache file/schema/mtime操作 | [AutoEQProfileLoader](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQProfileLoader.swift>)・[AutoEQFetcher](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQFetcher.swift>) |

これは仕様・algorithm・schemaを再構成した境界も含め、実装者が保守的にwhole-file GPLと指定した事実を記録するものです。
新規DTO/diagnostics/port等を含む全行が原作者のliteral copyだとは主張せず、機能語彙・規則自体の権利性も法的に断定しません。
別ファイルの独立HTTP transport・App consumer等のMIT部分は維持します。
外部AutoEqのINDEX/profile corpus自体は同梱しておらず、その取得dataをこの表のsource codeと同一licenseだと再分類もしません。
