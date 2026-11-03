# FineTune-Rewrite 互換性の基準

## 位置付け

元のFineTuneの機能・UI・操作・設定・外部連携を基本互換で置き換えるための比較基準である。
本プロジェクト自身の過去の実装との後方互換性を求めるものではない。
この文書は実装完了や試験合格を示さない。今回確認したのは原典の文書・ソース・issueであり、旧版・新実装の動作比較と実機再現は未実施である。
責務・所有権は[設計案](<architecture.md>)、試験方法・実行条件は[検証方針](<validation.md>)で扱う。

## 固定する比較元

| 項目 | 基準 |
| --- | --- |
| リポジトリ | [ronitsingh10/FineTune](https://github.com/ronitsingh10/FineTune) |
| revision | [`2285279d36d3f8115c1c2d4aecd904f1bdf96a51`](https://github.com/ronitsingh10/FineTune/commit/2285279d36d3f8115c1c2d4aecd904f1bdf96a51) |
| commit日時 | 2026-07-09 07:54:55 UTC |
| 版の目印 | `Update appcast for v1.9.0`。v1.9.0の配信情報を追加したcommitであり、tagそのものではない |
| 原典確認日 | 2026-11-04 JST |

[commit API](https://api.github.com/repos/ronitsingh10/FineTune/commits/2285279d36d3f8115c1c2d4aecd904f1bdf96a51)でSHA・日時・変更内容を確認した。
[配信情報](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/appcast.xml#L26-L33)はv1.9.0／build 38／macOS 15.4を示す。
固定版の[README](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/README.md#L116-L119)の15.0表記とは異なり、[ビルド設定](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune.xcodeproj/project.pbxproj#L364)も15.4である。これは各OSでの動作確認を意味しない。
比較のたびに最新mainへ追従しない。基準を更新するときは、差分と受け入れ条件への影響を確認してこの文書を更新する。

## 基本互換の対象

固定版が公開している[機能一覧](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/README.md#L53-L94)を出発点とする。
以下は比較範囲であり、全項目の詳細仕様を確定した一覧ではない。

- アプリ別の音量・mute・boost、pin、ignore、未再生中の設定。
- 単一／複数出力、システム既定への追従、機器の優先順位、切断時の代替と再接続時の復元。
- アプリ別EQ・プリセット、機器別AutoEQ、loudness、入力・機器音量、hardware／DDC／softwareの使い分け。
- メニューバー・設定・HUDなどの主要UIと操作、キー・ショートカット、URLからの外部操作。
- 保存された設定の意味と、アプリ・機器の永続的な識別。

## 初期に比較する意味と差分

### 音量と保存値：意味を維持する

[音量変換](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Models/VolumeMapping.swift#L30-L64)では、アプリのslider位置を`s`（0〜1）としてPCM倍率は`s²`、逆変換は平方根である。
従ってUIの50%に対応するgainは0.25であり、保存値0.25をUIの25%と読み替えない。
hardware／DDCの機器音量には同じ平方変換を追加せず、アプリのgainやboostとは区別する。
これは変換実装の静的確認であり、機器の実測特性まで確認したものではない。

[保存model](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Settings/SettingsManager.swift#L94-L139)はversion 12を初期値とし、volume・mute・boost・出力選択・機器別AutoEQなどを別に保存する。
[音量の保存経路](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Models/VolumeState.swift#L37-L57)はgainをそのまま渡す。
[保存用のアプリ識別](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Models/AudioApp.swift#L29-L31)はbundle ID、なければ`name:<name>`であり、PIDとは別である。
旧設定の具体的な欠落値・破損・旧versionの扱いまで、この初期値から推測して確定しない。

### URLの音量：不一致を意図的に修正する

固定版の[set-volumes](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Utilities/URLHandler.swift#L69-L119)は整数0〜100を受け付け、`volume / 100`をgainとして渡す。
この式とUIの逆変換から、URLの10%はgain 0.1、表示は約32%になる。[issue #434](https://github.com/ronitsingh10/FineTune/issues/434)にも表示の不一致が報告されている。
式の帰結とissue報告を確認したもので、こちらでUIを起動して再現した結果ではない。
新実装ではUI・URLの百分率を共通の意味にそろえ、10%ならgain 0.01とする。現行URLの変換結果そのものは互換対象にしない。

### 切断・復元：保存した希望を失わない

[公開されている復元の意図](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/README.md#L67-L71)と[設計案](<architecture.md#L71-L76>)を期待結果とし、一時的な代替で保存した希望を消さない。
ただし、固定版で常に成立していると扱わない。
[multi切断時の呼び出し](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/Engine/AudioEngine.swift#L1373-L1393)は「保存しない」としてidentifierを省略するが、[下位setter](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Models/VolumeState.swift#L162-L175)では既存stateの識別子で保存に進む。
これはsource上の要再現箇所であり、実際の切断・再接続結果は未確認である。

### 機器別の補正：独立して適用する

[AutoEQの説明](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/guide/autoeq.md#L7-L11)は機器ごとの補正を契約としている。
一方、[初期profileの選択](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/Engine/AudioEngine.swift#L812-L835)はprimary機器に基づき、[issue #439](https://github.com/ronitsingh10/FineTune/issues/439)では複数出力へ同じ補正が掛かると報告されている。
新実装は[経路別の処理状態](<architecture.md#L91-L104>)に従い、アプリ×出力機器ごとの補正・可変状態を分離する。全出力に同じ補正が掛かる症状は再現すべき互換挙動に含めない。
音声経路の方式や、報告環境での原因・解決を確認済みとするものではない。

## 最初の比較シナリオ

全項目が未実施である。実装時に、この入力・期待結果を対応する試験へ落とし込む。旧設定は隔離したfixtureで扱い、実ユーザーの設定を書き換えない。

| ID | 分類 | 入力・イベント | 期待結果 |
| --- | --- | --- | --- |
| C1 | 意味の維持 | アプリ音量0／10／50／100%、保存gain 0.25の再読込 | gainは0／0.01／0.25／1。再読込後は50%で、mute・boostは別に保持する |
| C2 | 意図的な修正 | active／inactiveアプリへURLで10／20／30%を指定 | UI直接操作と同じ表示・保存結果となり、gainは0.01／0.04／0.09 |
| C3 | 復元の意図の維持・要再現 | 明示出力Aとdefault追従を区別し、A切断後に再接続。multiの集合{A,B}でも実施 | 代替中も保存した希望を保ち、再接続で復元する。旧版との差と実機結果を別に記録する |
| C4 | 意図的な修正 | 1アプリからA・Bへ別の補正を設定し、Bだけを変更 | 各出力に対応する補正だけが掛かり、Aの処理履歴をBと共有しない。DSP試験と実機試験を分ける |
| C5 | 不具合の再現候補 | Lのみ／Rのみの入力、短い信号、無音からの復帰 | 非無音の信号を片側の無音で誤って消さない。[issue #429](https://github.com/ronitsingh10/FineTune/issues/429)の原因と実機再現は未確認 |

## 実装前に確認する保留事項

- URLの[guide](https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/guide/url-schemes.md#L7-L14)にある400%と、上記handlerの0〜100の不一致。boostの外部指定、異常な引数・部分適用、inactiveアプリに対する他actionの扱いも未確定。
- 旧schemaの欠落key・破損・未知versionへの対応、複数出力時の機器音量の詳細な意味。
- DSPの数値許容差、aggregate・チャンネル対応・切り替え方式、初音とidle・スリープ、長時間・Bluetooth・機器ごとの成立条件。

issue本文・状態は確認日時点の報告であり、固定版の再現成功や修正済みの証拠にはしない。
保留事項は互換性の名目で暗黙に決めず、原典・意図・確認条件をそろえてから受け入れ条件を更新する。
