set shell := ["bash", "-euo", "pipefail", "-c"]

swift_paths := "Package.swift Sources Tests"
native_patterns := "'*.h' '*.hpp' '*.cpp' '*.mm'"
clang_format := env("CLANG_FORMAT", "clang-format")
clang_format_version := "21.1.8"

# Check formatting, then build and test debug and release in order.
check: lint (build "debug") (test "debug") (build "release") (test "release")

# Show the selected Xcode, Swift, Clang, macOS SDK, and native formatter.
toolchain:
  xcodebuild -version
  xcrun swift --version
  xcrun clang++ --version
  xcrun --sdk macosx --show-sdk-path
  {{ quote(clang_format) }} --version

# Check Swift and native formatting without changing files.
lint: lint-swift lint-native

# Check Swift formatting without changing files.
lint-swift:
  xcrun swift format lint --strict --recursive {{ swift_paths }}

# Check tracked and non-ignored untracked native source formatting.
lint-native: _check-clang-format
  git ls-files --cached --others --exclude-standard -z -- {{ native_patterns }} | xargs -0 {{ quote(clang_format) }} --style=file:.clang-format --dry-run --Werror --

# Format Swift and native sources in place.
format: _check-clang-format format-swift format-native

# Format Swift sources in place.
format-swift:
  xcrun swift format format --in-place --recursive {{ swift_paths }}

# Format tracked and non-ignored untracked native sources in place.
format-native: _check-clang-format
  git ls-files --cached --others --exclude-standard -z -- {{ native_patterns }} | xargs -0 {{ quote(clang_format) }} --style=file:.clang-format -i --

# Build the package in debug or release configuration.
build configuration="debug":
  xcrun swift build --configuration {{ quote(configuration) }}

# Run smoke tests in debug or release configuration.
test configuration="debug":
  xcrun swift test --configuration {{ quote(configuration) }}

_check-clang-format:
  #!/usr/bin/env bash
  set -euo pipefail
  version="$({{ quote(clang_format) }} --version)"
  case "$version" in
    *"clang-format version {{ clang_format_version }}") ;;
    *) printf 'Expected clang-format %s; found %s\n' '{{ clang_format_version }}' "$version" >&2; exit 1 ;;
  esac
