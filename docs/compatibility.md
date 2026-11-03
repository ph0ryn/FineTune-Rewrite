# 互換方針

## 比較元と今回の出口

比較元は[FineTuneの固定revision](https://github.com/ronitsingh10/FineTune/commit/2285279d36d3f8115c1c2d4aecd904f1bdf96a51)
`2285279d36d3f8115c1c2d4aecd904f1bdf96a51`です。最新mainへ追従しません。
機能・UI・操作・設定・外部連携の基本用途を比較し、内部class構造・処理順序・旧実装の制約まで複製することは要求しません。

現在のテスト移植では、原作54ファイル・758宣言・静的966呼出しを元の保証の参照母数として扱います。
最終test数・元本文の一致そのものではなく、保証シナリオから新しいunit/componentへの対応と独立reviewを出口にします。
[対応台帳](<../Tests/UpstreamCompatibilityTests/migrationManifest.json>)と[監査手順](<test-migration.md>)で追跡します。
原作issue/PR由来の改良は、今回の移植へ追加しません。

## 保持する意味

- アプリ・機器のvolume/mute/boost、software sliderの意味、経路選択と保存希望
- 一時的な機器切断や適用失敗で、ユーザーが保存した希望を破壊しないこと
- 表示設定・ショートカット・HUD・アイコン・EQ presetなどの保存値と選択の意味
- UI・キー・URLなど入口が異なっても、Controlの共通操作へ合流すること
- 独立したroute/channelごとのDSP可変状態と、初音・無音区間後の再開を失わないこと

fieldやadapterの存在だけで、製品のconsumer接続や実機動作まで完成したとは判断しません。
構成と所有権の出発点は[設計案](<architecture.md>)、保証レベルは[検証方針](<validation.md>)に分けます。

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
| [AutoEQCatalog](<../Sources/FineTunePlatform/Profiles/AutoEQCatalog.swift>) | INDEX解析・検索順位 | [AutoEQFetcher](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQFetcher.swift>)・[AutoEQProfileManager](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQProfileManager.swift>) |
| [ParametricEQTextParser](<../Sources/FineTunePlatform/Profiles/ParametricEQTextParser.swift>) | APO grammar・filter規則 | [AutoEQParser](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQParser.swift>) |
| [AutoEQProfileRepository](<../Sources/FineTunePlatform/Profiles/AutoEQProfileRepository.swift>) | 取得/cache/importの振る舞い | [AutoEQFetcher](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQFetcher.swift>)・[AutoEQProfileManager](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQProfileManager.swift>) |
| [ProfileFileStore](<../Sources/FineTunePlatform/Profiles/ProfileFileStore.swift>) | cache file/schema/mtime操作 | [AutoEQProfileLoader](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQProfileLoader.swift>)・[AutoEQFetcher](<https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/AutoEQ/AutoEQFetcher.swift>) |

これは仕様・algorithm・schemaを再構成した境界も含め、実装者が保守的にwhole-file GPLと指定した事実を記録するものです。
新規DTO/diagnostics/port等を含む全行が原作者のliteral copyだとは主張せず、機能語彙・規則自体の権利性も法的に断定しません。
別ファイルの独立HTTP transport・App consumer等のMIT部分は維持します。
外部AutoEqのINDEX/profile corpus自体は同梱しておらず、その取得dataをこの表のsource codeと同一licenseだと再分類もしません。
