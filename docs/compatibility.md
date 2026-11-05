# 互換方針

## 比較元と今回の出口

比較元は[FineTuneの固定revision](https://github.com/ronitsingh10/FineTune/commit/2285279d36d3f8115c1c2d4aecd904f1bdf96a51)
`2285279d36d3f8115c1c2d4aecd904f1bdf96a51`です。最新mainへ追従しません。
機能・UI・操作・設定・外部連携の基本用途を比較し、内部class構造・処理順序・旧実装の制約まで複製することは要求しません。

現在のテスト移植では、原作54ファイル・758宣言・静的966呼出しを元の保証の参照母数として扱います。
最終test数・元本文の一致そのものではなく、保証シナリオから新しいunit/componentへの対応と独立reviewを出口にします。
[対応台帳](<../Tests/UpstreamCompatibilityTests/migrationManifest.json>)と[確認手順](<test-migration.md>)で追跡します。
原作issue/PR由来の改良は、今回の移植へ追加しません。

この固定版に対する移植時の独立review・実行監査は完了しました。以下は専用監査の削除前の記録で、現在の`just check`で監査を再実行するものではありません。
元の分類は**A550/B205/C3**を維持し、新設計の追加保証は独自Dとして分けています。
最終Debug/Releaseは各**Swift 1055宣言/1349呼出し（7 products）**と
**C++ 49 named units/6654呼出し（6 programs）**がpassし、完全監査は両方errors0です。
有限入力の展開と実function/case終了を照合した結果であり、元966との件数合わせではありません。
[実行証拠の読み方と限界](<test-migration.md#確定した移植実行結果>)に詳細を記録します。
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
全Mixerのpixel単位の一致を保証するものではありません。

[表示回帰テスト](<../Tests/AppCompositionTests/MixerControlAppearanceTests.swift>)はfakeを接続した実コンポーネントをoffscreen描画し、
3つのpopup sizeとlight/darkのidle軌道・icon headerを確認します。
専用window内のnative pointer eventで、通常/ミュート時の音量操作とtab・編集・設定・Quitのfake actionも検証します。
入出力それぞれで3つのpopup sizeの行内余白をクリックし、内部controlとの操作分離とdefault再書込の抑制を確認します。
選択中バッジはlight/darkの実bitmapと、観測default変更後にaccent表示が消えることを確認します。
`FINETUNE_MIXER_CONTROL_EVIDENCE`に出力先を指定すると、その描画PNGを保存できます。
[アプリ行テスト](<../Tests/AppCompositionTests/AppRowPresentationTests.swift>)は3つの幅で40pt行・percentage位置・非default subtitleを実描画し、
active icon/name/mute/slider/boost/EQの操作分離と、停止中・ミュート・dark時の共通slider操作をnative pointer eventで確認します。
実際のpicker menuでもSingle/Multi/default/UID選択をfake actionへ通し、観測更新の前に選択状態を先行変更しないことを確認します。
`FINETUNE_APP_ROW_EVIDENCE`で行・picker menuの描画PNGを保存できます。
[popupテスト](<../Tests/AppCompositionTests/PopupLayoutTests.swift>)はQuitの下部配置・⌘Qと、表示中の自然な高さ変更も検証します。
これらの成功を、最小対応OSのnative thumb、実機音声、全UIの操作・見た目の検証へ拡張しません。

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
[出自説明](<../Tests/UpstreamCompatibilityTests/README.md>)・[COPYING](<../Tests/UpstreamCompatibilityTests/COPYING>)・
[元path/SHAと対応表](<../Tests/UpstreamCompatibilityTests/migrationManifest.json>)を保持します。
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
