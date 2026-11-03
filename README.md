# FineTune-Rewrite

macOS向け[FineTune](https://github.com/ronitsingh10/FineTune)を再設計・再実装するプロジェクトです。
機能・UI・操作体系・設定・外部連携の基本互換を目指し、不具合を自分たちで再現・修正・保守できる構成にします。

## 開発環境

Swift 6とC++20に対応するXcode、およびXcode付属の`swift format`を使用します。
追加のパッケージマネージャーや外部ライブラリは不要です。

開発に使用するツールチェーンは次のとおりです。

| 項目 | 開発環境 |
| --- | --- |
| Xcode | 27.2 |
| Swift | 6.4.2、Swift 6 language mode |
| Apple Clang | 21.0.0、C++20 |
| macOS SDK | 27.2 |
| アーキテクチャ | Apple Silicon（arm64） |

ビルド対象はmacOS 15.4以降です。OS・言語・依存関係の設定は[Package.swift](<Package.swift>)で管理します。

## ビルドとテスト

リポジトリのルートで実行します。

```bash
# 選択中のXcode・Swift・Clang・macOS SDKを確認
xcodebuild -version
xcrun swift --version
xcrun clang++ --version
xcrun --sdk macosx --show-sdk-path

# Swiftの書式確認 → debugビルド → スモークテスト
xcrun swift format lint --strict --recursive Package.swift Sources Tests/BuildSmokeTests
xcrun swift build
xcrun swift test

# release構成でビルド・テスト
xcrun swift build -c release
xcrun swift test -c release

# Swiftの書式を修正
xcrun swift format format --in-place --recursive Package.swift Sources Tests/BuildSmokeTests
```

SDKの自動検出が古いCommand Line Toolsを参照する場合は、選択中のXcodeのSDKを明示して実行できます。
`test`も同様です。Xcodeの選択自体が誤っている場合は、先に開発環境の設定を確認してください。

```bash
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" xcrun swift build
```

書式確認対象はSwiftです。
SwiftPMのビルド生成物は`.build/`以下に作成されます。
SwiftPMやコンパイラはユーザー領域のキャッシュも使うため、sandbox環境ではその書き込み権限が別途必要になる場合があります。

### Xcodeから開く

```bash
open Package.swift
```

ローカルSwift Packageとして各ライブラリを編集・ビルド・テストできます。

## リポジトリの構成

| 場所 | 内容 |
| --- | --- |
| [Package.swift](<Package.swift>) | ライブラリとテストtarget、言語バージョン、依存関係の設定 |
| [Sources](<Sources/>) | 各ライブラリのソースコード |
| [BuildSmokeTests](<Tests/BuildSmokeTests/BuildSmokeTests.swift>) | Swiftからテスト用C APIを呼ぶスモークテスト |
| [NativeBuildSupport](<Tests/NativeBuildSupport/>) | スモークテスト用のC++／Objective-C++コード |

ライブラリの依存方向は次のとおりです。矢印はコード上の依存を表します。
具体的な宣言の管理元は[Package.swift](<Package.swift>)です。

```text
FineTuneControl  → FineTuneDomain
FineTunePlatform → FineTuneControl, FineTuneDomain, NativeAudio
NativeAudio      → AudioDSP
```

Swift側はC互換の公開ヘッダーだけをimportし、C++ヘッダーはnative実装内で扱います。

## テスト

スモークテストでは、次の項目を確認します。

- Swiftの各moduleとnative targetをコンパイル・リンクできること。
- C++20でコンパイルされたテスト用関数を、C形式の境界を通してSwiftから呼べること。
- Foundationを使うObjective-C++のテスト用関数をSwiftから呼べること。

機能・互換性・DSP・音声経路の試験対象と確認条件は[検証方針](<docs/validation.md>)を参照してください。

## 関連ドキュメント

| 文書 | 内容 |
| --- | --- |
| [開発ガイド](<AGENTS.md>) | 目的・参照基準・作業時の判断ルール |
| [アーキテクチャ設計案](<docs/architecture.md>) | 構成・責務・依存・所有権・設計上の検討事項 |
| [検証方針](<docs/validation.md>) | 試験対象・検証方法・実機での確認条件 |
