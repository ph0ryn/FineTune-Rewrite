# 開発手順

環境準備から`just check`、App bundle buildまでの手順。判定基準は[検証方針](verification.md)、設計は[設計案](architecture.md)に置く。

## 開発環境

- macOS、Xcode Command Line Tools、C++20対応Clang
- Swift 6言語モード。package tools-versionは6.0だが、互換テストの`-default-isolation MainActor`にはSwift compiler 6.2以降が必要
- [just](https://just.systems/)、`clang-format` 21.1.8
- Swift側はXcode付属の`swift format`、native側は[.clang-format](../.clang-format)を使う
- 製品のdeployment targetはmacOS 15.4

ローカル環境とCI環境の具体的なOS/Xcode/SDK/Swiftバージョンは、CI設定と追跡対象のtoolchain設定で管理する。CI定義は[.github/workflows/check.yml](../.github/workflows/check.yml)。

```bash
brew install just llvm@21
export CLANG_FORMAT="$(brew --prefix llvm@21)/bin/clang-format"
just toolchain
```

Xcodeを切り替える場合は選択状態を確認してから実行する。

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
xcodebuild -version
xcrun swift --version
```

外部SwiftPM依存は、実ショートカットadapterが使うKeyboardShortcuts。固定revisionは[リファレンス](reference.md)を参照。

## チェック

```bash
just lint
just build
just test
just test-dsp
just test-native
just check
```

`just check`はformat lint、unit/contract test、offline DSP、nativeの所有・levels・fake-HAL試験を実行する。contract testには実Appをbuild・起動せずにbuild CLIの成果物を検証する`just test-build-app`を含む。製品packageのbuild（`just build`）、描画test（`just test-ui`）、App bundle buildは含めず、別のstepで実行する。

scratchとXcode出力先を分離する場合:

```bash
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
SWIFT_SCRATCH_PATH=.indexion/cache/integrationBuild \
BUILD_JOBS=2 just check
```

既定値はSwiftPMが`.build`、Xcodeが`DerivedData`、並列build数が2。

### report出力

既定のレシピはrunnerの終了statusで成否を判定し、XML/event JSONLやnative JSON reportは生成しない。reportが必要な場合は各runnerの`--report`を明示する。

### format

```bash
just format
```

reviewでは純粋な整形とliteral入力・期待値の変更を区別する。原作由来の入力や期待値をformat変更へ紛れ込ませない。

## macOS App

[Xcode project](../FineTune.xcodeproj/project.pbxproj)のschemeは`FineTuneRewrite`、module名は`FineTune`、bundle IDは`com.ph0ryn.FineTuneRewrite`。

```bash
just build-app
just build-app release
open FineTune.xcodeproj
```

ルートの[build.sh](../build.sh)は`bash build.sh [debug|release]`でも直接実行できる。Xcodeのアカウント署名は無効のまま、完成したbundle全体をローカルad-hoc署名し、全architectureをstrict検証する。証明書・署名アカウント・公証は使わず、起動・権限要求もしない。

Xcodeのbundle build自体がLaunchServices/execution-policyへ開発bundleを登録する場合がある。そのため実Appのbundle buildは通常の`just check`から外し、CIでも使い捨てrunnerの別stepへ分離する。`just check`には、実Appを起動せずにbuild CLIの成果物を検証する`just test-build-app`が含まれる。

## リリース

`v0.1.0`のようなタグをpushすると[release workflow](../.github/workflows/release.yml)が走り、`FineTuneRewrite.dmg`がGitHub Releaseへ添付される。release構成のbundleを`hdiutil`でDMGに包むだけで、証明書やsecretの設定は要らない。

タグから`v`を除いた値が`MARKETING_VERSION`と一致しない場合は、xcodebuildの前に停止する。バージョンを上げるときはXcodeプロジェクトを先に更新する。成果物はrunnerのarm64向け単一bundleで、universalにはしない。

ad-hoc署名のbundleを他環境で開くとGatekeeperに止められる。利用者側の対処は[README](../README.md#インストール)に置く。原作のrelease workflowが行うDeveloper ID署名・公証・appcast更新は含めない。[check workflow](../.github/workflows/check.yml)は同じタグpushで並走するが、release jobはその結果を待たない。

## 変更時のreview

- 元の保証に対応する新unitの入力・期待値・許容差を確認し、分割・統合や非可搬な置換の理由を変更の根拠として説明する
- fixture/helperの変更も含めてreviewし、期待値や入力削減を単なるformat変更へ混ぜない
- production/test sourceを変更したら同じconfigurationで該当テストを再実行し、古いreportを成功証拠として再利用しない

実機操作を伴うtestは既定のtest targetへ入れず、別packageまたは明示のmanual runnerへ隔離する。metadataをoptionalにしただけでは、通常の`swift test`が実機操作を止めるわけではない。
