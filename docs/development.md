# Development Guide

Procedures from environment setup through `just check` and building the macOS app bundle. Evaluation criteria live in the [verification policy](verification.md), and design details live in the [architecture](architecture.md).

## Development Environment

- macOS, Xcode Command Line Tools, and a C++20-capable Clang
- Swift 6 language mode. The package `tools-version` is 6.0, while `-default-isolation MainActor` in compatibility tests requires Swift compiler 6.2 or later
- [just](https://just.systems/) and `clang-format` 21.1.8
- Use Xcode's bundled `swift format` for Swift sources and [.clang-format](../.clang-format) for native sources
- Product deployment target is macOS 15.4

Exact OS, Xcode, SDK, and Swift versions for local and CI environments are tracked in CI and toolchain configuration. See [.github/workflows/check.yml](../.github/workflows/check.yml).

```bash
brew install just llvm@21
export CLANG_FORMAT="$(brew --prefix llvm@21)/bin/clang-format"
just toolchain
```

When switching Xcode installations, confirm the active selection before running builds:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
xcodebuild -version
xcrun swift --version
```

The external SwiftPM dependency is `KeyboardShortcuts`, used by the live shortcut adapter. See [reference](reference.md) for the pinned revision.

## Checks

```bash
just lint
just build
just test
just test-dsp
just test-native
just check
```

`just check` runs format lint, unit/contract tests, offline DSP tests, and native ownership/levels/fake-HAL tests. Contract tests include `just test-build-app`, which verifies build CLI outputs without building or launching the real app. Building the product package (`just build`), rendered UI tests (`just test-ui`), and building the app bundle are intentionally excluded and run as separate steps.

To isolate scratch and Xcode build outputs:

```bash
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
SWIFT_SCRATCH_PATH=.indexion/cache/integrationBuild \
BUILD_JOBS=2 just check
```

Defaults are `.build` for SwiftPM, `DerivedData` for Xcode, and `2` parallel build jobs.

### Report Output

Default recipes determine pass/fail from runner exit status and do not emit XML/event JSONL or native JSON reports. Pass `--report` explicitly to individual runners when machine-readable reports are needed.

### Formatting

```bash
just format
```

In code review, separate pure formatting changes from edits to literal inputs or expected values. Do not smuggle changes to upstream-derived test inputs or expectations into formatting commits.

## macOS App

In the [Xcode project](../FineTune.xcodeproj/project.pbxproj), the scheme is `FineTuneRewrite`, the module name is `FineTune`, and the bundle ID is `com.ph0ryn.FineTuneRewrite`.

```bash
just build-app
just build-app release
open FineTune.xcodeproj
```

The root [build.sh](../build.sh) script can also be invoked directly as `bash build.sh [debug|release]`. Xcode account signing remains disabled; the finished bundle is locally ad-hoc signed and strictly verified across all architectures. No certificates, signing accounts, or notarization are used, and the script neither launches the app nor requests permissions.

Because building an app bundle with Xcode may itself register the development bundle with LaunchServices or execution policy, real app bundle builds are excluded from standard `just check` and isolated into a separate step on disposable CI runners. `just check` includes `just test-build-app` to verify build CLI outputs without launching the real app.

## Releases

Pushing a tag such as `v0.1.0` triggers the [release workflow](../.github/workflows/release.yml), which attaches `FineTuneRewrite.dmg` to a GitHub Release. It packages the release bundle into a DMG via `hdiutil` without requiring certificates or secrets.

If the tag (stripped of its leading `v`) does not match `MARKETING_VERSION`, the workflow aborts before running `xcodebuild`. Bump the version in the Xcode project first. The artifact is a single `arm64` bundle targeting the runner architecture, not a universal binary.

Opening an ad-hoc-signed bundle on another machine will be blocked by Gatekeeper; user instructions live in [README](../README.md#install). Upstream release steps such as Developer ID signing, notarization, and appcast updates are intentionally omitted. The [check workflow](../.github/workflows/check.yml) runs in parallel on the same tag push, and the release job does not wait on its result.

## Review Checklist for Changes

- Verify inputs, expected values, and tolerances of new units against their corresponding upstream guarantees, and explain the rationale for any splits, merges, or non-portable replacements.
- Review fixture and helper edits as well; never mix expectation changes or reduced inputs into formatting-only diffs.
- Re-run affected tests in the same configuration after modifying product or test sources; never reuse stale reports as proof of passing.

Keep tests that touch real hardware out of default test targets by isolating them in a separate package or explicit manual runner. Merely marking metadata optional does not stop `swift test` from executing live hardware operations.
