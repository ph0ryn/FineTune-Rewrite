# FineTune-Rewrite

macOS向けFineTuneの基本互換再実装に向けた、開発用の足場です。
**アプリの機能・音声取得・DSP・設定移行は実装していません。**

## 文書の案内

| 文書 | 内容 |
| --- | --- |
| このREADME | 現在の実装状況、開発環境、実行手順、実行可能なテストの範囲 |
| [開発ガイド](<AGENTS.md>) | 目的・参照基準・作業時の判断ルール |
| [アーキテクチャ設計案](<docs/architecture.md>) | 構成・責務・依存・所有権・未決の設計選択 |
| [検証方針](<docs/validation.md>) | 試験対象・検証方法・実機での確認条件 |

## 開発環境

Swift 6とC++20に対応するXcode、およびXcode付属の`swift format`を使用します。
追加のパッケージマネージャーや外部ライブラリは不要です。

今回確認した環境は次のとおりです。他のツールチェーンやIntel Macでは未検証です。

| 項目 | 検証環境 |
| --- | --- |
| Xcode | 27.2 |
| Swift | 6.4.2、Swift 6 language mode |
| Apple Clang | 21.0.0、C++20 |
| macOS SDK | 27.2 |
| アーキテクチャ | Apple Silicon（arm64） |

[Package.swift](<Package.swift>)のdeployment targetは、共有設計案を出発点にmacOS 15.4としています。
これはビルド設定であり、macOS 15.4上での動作確認や製品の対応OS確定を意味しません。

## 開始手順

リポジトリのルートで実行します。

```bash
# 選択中のXcode・Swift・Clang・macOS SDKを確認
./scripts/dev.sh doctor

# Swiftの書式確認 → debugビルド → スモークテスト
./scripts/dev.sh check
```

[開発スクリプト](<scripts/dev.sh>)は、`xcrun --sdk macosx`で取得したSDKを子プロセスに明示します。
SDKの自動検出が古いCommand Line Toolsを参照する場合にも、選択中のXcodeのSDKで実行するためです。
`xcode-select`やユーザーの永続設定は変更せず、SDKを取得できなければ失敗します。
Xcodeの選択自体が誤っている場合は、先に開発環境の設定を確認してください。

### 個別に実行する

```bash
./scripts/dev.sh build
./scripts/dev.sh test

# build/testにはSwiftPMのオプションを渡せる
./scripts/dev.sh build -c release
./scripts/dev.sh test -c release

# Swiftの書式を修正
xcrun swift format format --in-place --recursive Package.swift Sources Tests/BuildSmokeTests
```

`check`の書式確認対象はSwiftのみです。C++／Objective-C++のlintやリアルタイム検査は含みません。
SwiftPMのビルド生成物と共有キャッシュは`.build/`以下を使用します。
コンパイラ自身がmacOS標準のキャッシュも使うため、sandbox環境ではその書き込み権限が別途必要になる場合があります。

### Xcodeから開く

```bash
open Package.swift
```

ローカルSwift Packageとしてライブラリの開発ができます。
アプリ用Xcodeプロジェクト、bundle ID、署名、権限、配布設定はまだ用意していません。
アプリを起動する手順ではありません。

## リポジトリの構成

| 場所 | 内容 |
| --- | --- |
| [Package.swift](<Package.swift>) | 5つのライブラリtarget、Swift 6／C++20、依存方向の宣言 |
| [Sources](<Sources/>) | 各ライブラリのビルド用の空の骨格。製品APIは未定義 |
| [BuildSmokeTests](<Tests/BuildSmokeTests/BuildSmokeTests.swift>) | Swiftからテスト用C APIを呼ぶスモークテスト |
| [NativeBuildSupport](<Tests/NativeBuildSupport/>) | テスト専用のC++／Objective-C++コード。製品ライブラリからは依存しない |
| [dev.sh](<scripts/dev.sh>) | 環境確認・ビルド・テストの共通入口 |

ライブラリの依存方向は次のとおりです。矢印はコード上の依存を表します。
具体的な宣言の管理元は[Package.swift](<Package.swift>)です。

```text
FineTuneControl  → FineTuneDomain
FineTunePlatform → FineTuneControl, FineTuneDomain, NativeAudio
NativeAudio      → AudioDSP
```

Swift側はC互換の公開ヘッダーだけをimportします。
C++ヘッダーはnative実装内で扱い、SwiftのC++ interoperabilityは有効にしていません。

## 検証の範囲

スモークテストで確認するのは、次の開発基盤だけです。

- Swiftの各moduleとnative targetをコンパイル・リンクできること。
- C++20でコンパイルされたテスト用関数を、C形式の境界を通してSwiftから呼べること。
- Foundationを使うObjective-C++のテスト用関数をSwiftから呼べること。

製品の振る舞い、互換性、DSPの正しさ、リアルタイム安全性、実機の音声経路を確認するテストではありません。
製品の試験と音声経路の検証用プログラムは未作成です。追加する試験の対象・確認条件は[検証方針](<docs/validation.md>)で扱います。
CI・自動配布・外部公開の設定は、この開発準備には含めていません。
