# FineTune-Rewrite

macOS向け[FineTune](https://github.com/ronitsingh10/FineTune)の基本用途を置き換えることを目指す再実装です。
UI・操作・保存設定・外部連携の基本互換を保ち、不具合を再現・修正・保守できる責務分離を重視します。

比較元の固定revisionは[仕様](docs/spec.md)で管理します。最新mainや将来のissue/PR対応を、移植条件へ混ぜません。

## 範囲

Mixer・Settings・キー操作・`finetune:` URLを、同じControlと設定storeへ接続しています。
製品Rootが機器・processの監視、入出力policy、機器操作、Native音声runtime、AutoEQ repository/cacheを組み立て、
UIは同じ状態のsnapshotと共通commandを使います。

| 区分 | 範囲 |
| --- | --- |
| 実装・接続 | 製品Appの組立、表示と操作、保存、OS adapter、C ABI越しのtap/aggregate/IOProcと経路別DSP |
| 自動検証 | 原作由来のunit/component、新境界の独自テスト、実production DSP/C ABIとfake HALの契約試験 |
| 別途確認が必要 | 実音声・権限・物理機器、最小対応OS、callback deadline、署名・公証・配布 |

元と同じ件数やテスト構造の再現は目的ではありません。元の保証と新unitの対応関係は[検証方針](docs/verification.md)で扱います。
テストの成功は、原作用途をすべて置き換えられる製品、実機音声経路、リアルタイム安全性、署名・公証の完成を意味しません。

## 構成

App / FineTuneDomain / FineTuneControl / FineTunePlatform / NativeAudio / AudioDSP の六層に分かれます。
Swiftとnativeの公開境界はC形式で、C++型や所有権をSwift側へ広げません。
責務・依存・所有権は[設計案](docs/architecture.md)、依存の宣言は[Package.swift](Package.swift)を参照してください。

## 開発

環境構築、ビルド、テスト、macOS Appのbundle buildは[開発手順](docs/development.md)にまとめています。

```bash
just check
```

`just check`はformat lint・package build・unit/component・offline DSP・native契約試験を実行します。
描画testとApp bundle buildは含まれません。

## 実音声と診断

AudioProbeによる限定観測の安全条件は[検証方針](docs/verification.md#実音声を確認するときの安全条件)、
`FINETUNE_AUDIO_DIAGNOSTICS`の記録フィールドと有効化方法は[リファレンス](docs/reference.md)を参照してください。

## 文書

- [仕様](docs/spec.md): 外部から観測可能な互換契約
- [設計案](docs/architecture.md): 層分離・所有権・リアルタイム境界
- [検証方針](docs/verification.md): 保証境界・判定原則・限定実機観測
- [開発手順](docs/development.md): 環境構築・ビルド・テスト・review手順
- [リファレンス](docs/reference.md): GPL由来ファイル一覧・診断フィールド・固定revision
- [調査記録](docs/research.md): 原作比較・意図的な差異の根拠
- [開発ガイド](AGENTS.md): 作業の前提と参照基準

## ライセンス

独立して書いた部分は[MIT License](LICENSE)、原作由来のコンポーネントは`GPL-3.0-only`です。ライセンス指定はファイルごとには行わず、コンポーネント単位で行います。

| コンポーネント | ライセンス |
| --- | --- |
| Profiles / AutoEQ | `GPL-3.0-only` |
| DeviceIcons | `GPL-3.0-only` |
| Mixer UI | `GPL-3.0-only` |
| Device observation | `GPL-3.0-only` |
| テスト / DSP | `GPL-3.0-only` |
| その他 | MIT |

著作権表示・GPL本文・KeyboardShortcutsのライセンスは[THIRD_PARTY_NOTICES.txt](App/Resources/THIRD_PARTY_NOTICES.txt)にまとめています。ファイルごとの由来はgit履歴と[リファレンス](docs/reference.md)で追えます。
