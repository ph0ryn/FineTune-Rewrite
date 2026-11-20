# 調査記録

この文書は、比較元との調査から得た結果と、意図的な差異の根拠を記録する。満たすべき契約は[仕様](spec.md)、構成上の判断は[設計案](architecture.md)、確認の範囲は[検証方針](verification.md)に置く。

## macOS 26 の AirPods 装着検出と transient 再適用

原作は接続直後の猶予中、macOS が既定を接続デバイスへ切り替えるたびに確認済み default へ書き戻し、上書きから 1 秒超の間隔が空いたときだけユーザー操作として受け入れる。macOS 26 の AirPods 装着検出は 0.5 秒周期で transient を再適用する。この周期では 1 秒の idle 条件が永久に成立せず、書き戻しと OS の再適用が繰り返される。原作コードに同じ弱点があり、切り替えロジックを忠実に移植しても解消しない。

原作は troubleshooting ガイドで Automatic Ear Detection に干渉しないことを明示する。原作コードがこの条件で満たせていない仕様をコード側で満たすため、再書込の契機を接続バッチ開始・切断フォールバック・明示選択・設定変更の各 1 回に限定する。同じ接続エピソード内で OS が再適用した transient は受容し、書き返さない。入力ロックも同じ契機だけに適用し、Settings での入力変更を尊重する。優先度機能は維持するが、原作の echo timeout 時における再書込はこの方針では追試行になるため行わない。契約は[仕様](spec.md)に置く。

## 重複 tap と資源の寿命

default の補正回数や capture の再試行は増やさない。重複 tap とコード上の寿命問題は機械的に切り分ける。Bluetooth への巻き戻りや可聴音の解消はこの調査の結論ではなく、別途の実機確認対象である（[検証方針](verification.md)）。

## 入力 stream の開始チャンネル番号

所有する単一 stereo tap と意図した物理機器だけの構成を読み戻した場合に限り、stream の開始チャンネル番号が 1 より大きくても、連続した 2ch なら IOProc の buffer 構成と照合して扱う。開始番号が 5 で stereo buffer が 1 個の構成を、未対応 format や buffer 内の 4ch offset として解釈しない。

[StartingChannel](https://developer.apple.com/documentation/coreaudio/kaudiostreampropertystartingchannel) は device の property element 番号であり、[StreamConfiguration](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertystreamconfiguration) が IOProc の buffer 構成に対応する。両者を混同すると、開始番号をリアルタイム側の offset や certificate の不変値へ持ち込み、連続 2ch を誤って拒否する。物理/aggregate 出力は channel 1/2 を要求し、余分な入力・不連続な番号・不一致の format/buffer 構成は拒否する。音出しと切り替えの可聴連続性は別の検証対象である（[検証方針](verification.md)）。

## software ミュートとシステムアラートの差

原作の software tier ミュートは tap 内のゲインだけを扱い、tap 外のシステムアラート音は消えない。hardware/DDC tier は機器側のミュートでアラートも消えるが、HDMI など hardware ミュートを持たない出力では「デバイス無音」でも未処理キーのビープが鳴る。この差を受け入れ条件の違いとして扱い、System Sounds の出力先が software tier でミュートされている間だけ OS のアラート音量を 0 にする独自動作を採る。復元値をアプリ設定の Alert Volume と分けるのも、この差に起因する。契約は[仕様](spec.md)に置く。

## テストの適応と延期事項

純粋な入力・出力契約は直接保持できる。一方、旧 private API・未使用 engine を抱える fixture・旧 vDSP setup の所有・mock 自身の default 値・実 OS への無 assert 投稿は、新しい境界へ置き換える。元の保証を弱めずに unit へ分割・統合できるなら、旧 class を復元した巨大な互換 facade は追加しない。

- aggregate/tap の初期設定は新しい planner と注入可能な route port で確認し、legacy の呼出名や設定時刻を固定しない。
- media key の handler/watchdog は actual monitor と Control を使い、OS tap・clock・HUD 表示だけを隔離する。
- メニュー操作の event 構築・dispatch は poster seam で確認し、test runner の実 event pump へ投げるだけの smoke test にしない。
- signal helper は native-owned 係数 copy へ適応する。旧検出位置や poisoned vDSP state だけを要求するシナリオは、理由と有限出力・明示 error・state reset の代替保証として個別に記録する。数式・出典・offline 検証の限界は[数値互換記録](<../Tools/DSPTests/Compatibility.md>)に置く。

延期事項として、URL 値を `s²` へ変更する案と boost 拡張を保持する。原作の現行処理・既知の問題・将来採用する変更を分けて扱い、無断で互換修正に含めない。idle・初音・切替・再接続・長時間稼働などの issue/PR 案も、再現条件と別の受入条件を定めて扱う。

## private aggregate の tap drift/quality と SubTapList

private aggregate の tap drift/quality は作成後に変更せず、証明のたびに OS から Composition を読み戻して、所有 tap UID との一意対応・数値型・値を検証する。作成時の要求辞書や既定値を観測の代わりに使わない。期待する drift 値は出力の transport type から導き、tap と出力がクロックを共有する Bluetooth/BLE では OFF を要求する。ON だと HAL が周期的にサンプルを挿入・削除してクラックルが出る。

SubTapList の ID は active member の同一性比較に使う。子 object の property 読取・監視が可能であるとは仮定しない。aggregate の Composition・tap/subtap list と既存の物理機器・stream を監視し、start 前にも再検証する。同一 process 内の外部コードが子 drift/quality を直接変更する方式は対応対象外で、子設定の変更が必ず親 Composition 通知になるという保証はない。構成上の扱いは[設計案](architecture.md)に置く。
