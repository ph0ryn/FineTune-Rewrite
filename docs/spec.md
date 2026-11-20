# 互換仕様

この文書は、FineTune-Rewrite が外部から観測できる形で満たすべき契約を規定する。内部の構造・処理順序・所有権は[設計案](architecture.md)、判断の根拠と原作との比較は[調査記録](research.md)、契約の確認方法は[検証方針](verification.md)に置く。

比較元は[FineTune の固定 revision](https://github.com/ronitsingh10/FineTune/commit/2285279d36d3f8115c1c2d4aecd904f1bdf96a51)である。機能・UI・操作体系・設定・外部連携の基本用途を対象とし、内部の class 構造や旧実装の制約まで複製しない。意図的な差異は本文で契約として示し、理由は[調査記録](research.md)に譲る。

## 保持する意味

- アプリ・機器の volume/mute/boost、software slider の意味、経路選択と保存した希望を保持する。
- 一時的な機器切断や適用失敗で、ユーザーが保存した希望を破壊しない。
- 表示設定・ショートカット・HUD・アイコン・EQ preset などの保存値と選択の意味を保持する。
- UI・キー・URL など入口が異なっても、Control の共通操作へ合流し、音量の意味や状態更新経路を入口ごとに分けない。
- route/channel ごとに独立した DSP 可変状態を持ち、初音・無音区間後の再開を失わない。

## Mixer の表示

- 音量スライダーは 4pt の軌道を持ち、hover/drag 時に native mini thumb を表示する。
- 上部・下部の操作は speaker/mic 切替、鉛筆/checkmark、塗りの歯車、下部の `Quit ⌘Q` を含む。
- デバイス行は、名前の隙間と上下の余白を含む行の非操作部分から default を切り替える。ミュート・音量・パーセント入力は行の切り替えを伴わず、すでに default の行を再選択しても再書込しない。
- 選択バッジは原作の 28pt 円形・アクセント色 gradient・白い glyph とし、未選択時は mono 表示にする。選択は OS の観測 default に従い、既存 checkmark も残す。クリック直後の先行表示や切替中の表示は出さない。
- 音量の binding・未知値/読み取り専用表示・共通 command・現行の ⌘Q 操作・全行の非スクロール表示を維持する。
- ミュートの dim 表示と native 待機時の opacity は分離する。合成 opacity が hit-test 閾値を下回って音量操作を失うことはない。
- アプリ行は 28pt header と上下 6pt・左右 8pt padding の 40pt 行とし、VU・24pt app icon・名前・mute・共通 140pt slider・40pt percentage 枠・boost chevrons・出力先 icon・EQ icon を 1 行に並べる。
- 名前や余白には action を付けない。active app の icon だけが既存 activate action を呼ぶ。停止中の装飾は dim にするが、slider の祖先 opacity は下げず音量操作を維持する。
- 通常は背景を透明とし、hover・focus・EQ 展開時に共通 hover surface を使う。EQ panel の内部操作は変更しない。
- 出力先 picker は 28pt icon trigger と Single/Multi・check/checkbox の 210pt menu を使う。popover の外側クリック・dismiss・window 所有は native SwiftUI に委ねる。mode/UID の先行状態は持たず、選択は観測値に従う。
- 通常の follow-default は名前の下に表示せず、明示経路・multi の要約だけを 9pt subtitle にする。機器がなくなった UID の Unavailable 表示、明示 routeStatus、観測 level 欠損と実測 0 の区別を隠さない。
- アプリ section は APPS 見出し・通常 0pt 行間・編集時 2 列/4pt 間隔・独立した Ignored grid・中央の空表示を使う。
- 表示順は pinned active→pinned inactive→unpinned active を基本とし、各 group 内を locale-aware な case-insensitive 名順にする。同名は永続 ID で決定する。編集時のみ出す unpinned inactive metadata と ignored は末尾の別 group で維持する。
- 表示と keyboard navigation は同じ projection 順に従う。保存済みの pin/ignore 値や経路の所有は変更しない。
- 原作の Donate、0% クリック時の gain 1.0 復元、機器の欠損値 fallback は本契約に含めない。全 Mixer の pixel 単位の一致は保証しない。

## デバイス切り替えと失敗からの復帰

- 出力デバイスの明示選択が成功したとき、default 追従中のアプリの失敗した経路を再試行する。入力の選択・失敗した default 書込・固定先を持つアプリへは再試行を広げない。
- 経路先は policy が承認した UID を使い、非同期の OS 観測を待つ間に旧 default へ再取得しない。観測された default UID と policy 承認先は分けたままとし、補正で既存の健全なアプリ経路を強制作り直さない。capture の再試行範囲も広げない。
- 受動的な機器・process 通知だけで失敗した取得を繰り返さない。既知の権限拒否は明示的な `Retry Audio` まで解除しない。
- FineTune からの明示選択が成功した直後の 2 秒間は、健全な UID・Bluetooth 構成が変わらない場合に限り、別の Bluetooth 出力への巻き戻りを 1 回だけ補正する。この期限は補正や確認通知で延長せず、新しい明示操作・機器構成や観測の健全性の変化・suspend で古い補正権限を失効させる。
- OS 通知には操作元の情報がないため、この区間内の Control Center からの Bluetooth 選択は区別できない。FineTune からの再選択は常に最新の操作として扱う。
- 期限後の新しい外部選択は尊重し、古い書込の確認待ちや timeout で元へ戻さない。未解消の失敗は時間経過や同じ UID の再通知だけでは消えない。
- 補正後も選択を維持できない場合や確認が期限切れになった場合は、無限に書き戻さず、Mixer・Settings へ失敗を表示する。要求先の健全な観測または新しい選択で解消する。
- Bluetooth の所有権を永続的に固定する機能ではない。実機での補正効果と可聴連続性は本契約の保証対象外で、別途の確認に委ねる（[検証方針](verification.md)）。

### 観測 default への再書込は接続エピソード 1 回まで

- 観測 default への書き戻しは、接続バッチ開始・切断フォールバック・明示選択・設定変更の各 1 回に限る。同じ接続エピソード内で OS が再適用した transient（装着検出の transient を含む）には書き返さず受容する。
- 入力ロックも同じ契機でのみ適用する。Settings での入力変更は尊重し、原作の「lock は Settings 変更にも保持する」挙動から外れる。
- 優先度機能（上位デバイス接続時の 1 回の切替、切断時の次点フォールバック）は維持する。
- 原作の echo timeout 時における再書込（書込の確認が戻らなかった場合の再試行）は行わない。

## 経路の受け渡し・取消・失敗表示

- 取消済みの経路は、callback の受付を閉じたまま継続用として残さない。取消は OS の IO 停止や source mute 解除そのものではないため、実際の終了確認まで所有権を維持し、次の経路の準備完了を待たずに回収を始める。
- 進行中・回収待ちの作業を二重実行しない。旧経路の終了確認までは新しい経路を commit しない。
- 明示的な capture Retry では、完了済みの回収失敗と、準備済み handle を返せず残った失敗を再試行する。再試行に成功しても、過去の cleanup failure を現在の失敗として再送しない。同じ失敗が再発した場合は表示と commit 阻止を維持する。
- 旧経路の既知の primary failure は回収後も診断履歴に残す。成功した回収を失敗扱いして新経路の commit を妨げない。終了開始後に遅れて記録される `cancelled` も回収失敗とは区別する。終了を指示していない現行経路の `cancelled` は失敗として扱い、旧経路の遅延更新による `cancelled` は現行の失敗表示を作成・上書きしない。
- 診断はアプリ単位で保持する。別アプリの取得成功・旧経路の回収開始・新しい経路の準備だけでは消えない。そのアプリ自身の commit 後、要求経路すべてが健全な場合に解除し、複数出力の一方の成功だけで残す経路の障害を消さない。
- Mixer・Settings は診断履歴と現在の警告を分ける。処理を希望している現在のアプリの失敗は、そのアプリ自身が復旧するまで表示する。停止・アプリの終了・Ignore 後は過去の経路失敗を警告しないが、診断履歴は保持する。
- Mixer で表示中のアプリに属する失敗は通常モードの行だけに出し、上部へ重複させない。並べ替え中は行内の警告を表示せず、通常モードへ戻ったときに現在の状態を表示する。
- 権限拒否は共通の案内で示し、保存・機器操作などの独立した失敗は隠さない。
- cleanup の警告は世代の新旧ではなく、資源をまだ所有しているかで判断する。未完了の回収と、準備済み handle を返す前に失敗した経路の回収は、停止後やアプリ行がない場合も表示する。終了確認または resource release の成功が確認できた警告だけを外し、別経路の成功や新しい準備では解除しない。
- 最新診断は履歴として残し、未解決の cleanup は経路ごとに追跡する。この集合が空でも、すべての資源が回収済みであることを意味しない。
- 物理/aggregate 出力は channel 1/2 を要求する。余分な入力・不連続な番号・不一致の format/buffer 構成は拒否する。

## Quit

- Quit ボタン・⌘Q・アプリメニューは同じ終了処理へ通す。
- 終了通知では、入力監視の停止・HUD の終了・設定の flush を同期的に行う。独自の遅延終了・非同期の音声回収待ち・保存失敗時の再試行/取消ダイアログは設けない。
- 保存失敗は store に残すが、終了を取り消さない。音声資源はプロセス終了時の OS 回収に従い、通常の cooperative stop の契約は変更しない。
- 実音声中の終了や最低対応 OS での動作は保証しない（[検証方針](verification.md)）。

## 保存設定

- 新規作成時は version 12 とし、version が欠落/null の decode は 9 とする。未知の整数 version を勝手に移行拒否しない。
- 欠落/null と型不一致を区別する。既知 key の default・gain 正規化・enum decode の意味を維持する。
- CRUD・直接 binding・debounce・明示 flush・reset・preset 名検証は、保存結果と観測可能な副作用で扱う。
- login service は注入可能とし、読み込みだけで実ログイン項目を登録しない。
- 不正 JSON は backup して再開する。backup 自体に失敗した場合はその manager の書込を抑止し、load/save error を観測可能にする。
- 保存 directory は必須の明示引数とする。原作の Application Support 名前空間を暗黙に開かず、原作設定の import はユーザーが明示的に選ぶ操作として設計する。

## システムアラートの消音連動

原作にない独自動作である。理由と原作との比較は[調査記録](research.md)に置く。

- System Sounds の出力先デバイスが software tier でミュートされている間だけ、OS のアラート音量を 0 にする。
- 解除時はミュート前のアラート音量へ戻す。hardware/DDC tier と、System Sounds に出ていないデバイスのミュートでは何もしない。
- 終了通知でも同期的に戻す。保存した復元値は次回起動時に確認してから現在のミュートを評価し、終了と復元が競合しても値の取り違えを残さない。
- 復元値は保存 schema の `alertVolumeBeforeMuteSilencing` にだけ置き、アプリ設定の Alert Volume とは別に扱う。silencing 中は Settings の Alert Volume 操作を無効化する。

## URL・外部操作

- `finetune://` actions・query 順序・validation・保存対象は、固定版の原作を基準にする。
- parser・共通 Control 操作・App event/bundle 登録は異なる保証であり、parser だけでは製品連携の完成としない。
- 原作 guide と実装が異なる百分率表現についても原作の現行処理を基準とし、変更案は[調査記録](research.md)の延期事項で扱う。
