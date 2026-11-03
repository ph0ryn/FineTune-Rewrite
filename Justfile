set shell := ["bash", "-euo", "pipefail", "-c"]

swift_paths := "Package.swift Sources App Tests"
swift_scratch_path := env("SWIFT_SCRATCH_PATH", ".build")
app_derived_data := env("APP_DERIVED_DATA", "DerivedData")
build_jobs := env("BUILD_JOBS", "2")
native_patterns := "'*.h' '*.hpp' '*.cpp' '*.mm'"
clang_format := env("CLANG_FORMAT", "clang-format")
clang_format_version := "21.1.8"

# Check formatting, unit/component/DSP tests and reviewed evidence in both configurations.
check: lint audit-tests (build "debug") (test "debug") (test-dsp "debug") (audit-upstream "debug") (build "release") (test "release") (test-dsp "release") (audit-upstream "release")

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
  xcrun swift build --scratch-path {{ quote(swift_scratch_path) }} --jobs {{ quote(build_jobs) }} --configuration {{ quote(configuration) }}

# Snapshot inputs, clear stale events, then record unit/component test evidence.
test configuration="debug":
  python3 scripts/auditUpstreamTests.py --capture-snapshot {{ quote(swift_scratch_path + "/test-source-snapshot-" + configuration + ".json") }} --events {{ quote(swift_scratch_path + "/test-events-" + configuration + ".jsonl") }} --cpp-events {{ quote(swift_scratch_path + "/test-dsp-results-" + configuration + ".json") }}
  xcrun swift test --scratch-path {{ quote(swift_scratch_path) }} --jobs {{ quote(build_jobs) }} --configuration {{ quote(configuration) }} --xunit-output {{ quote(swift_scratch_path + "/test-results-" + configuration + ".xml") }} --event-stream-output-path {{ quote(swift_scratch_path + "/test-events-" + configuration + ".jsonl") }} --event-stream-version 0

# Test the migration auditor's fail-closed source/event handling.
audit-tests:
  PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/MigrationAuditTests -v

# Check reviewed guarantees, runtime cases and unchanged compiled inputs.
audit-upstream configuration="debug":
  python3 scripts/auditUpstreamTests.py --source-snapshot {{ quote(swift_scratch_path + "/test-source-snapshot-" + configuration + ".json") }} --events {{ quote(swift_scratch_path + "/test-events-" + configuration + ".jsonl") }} --cpp-events {{ quote(swift_scratch_path + "/test-dsp-results-" + configuration + ".json") }} --json-output {{ quote(swift_scratch_path + "/test-audit-" + configuration + ".json") }}

# Run native DSP and public C ABI scenarios without audio devices.
test-dsp configuration="debug":
  xcrun swift run --scratch-path {{ quote(swift_scratch_path) }} --jobs {{ quote(build_jobs) }} --configuration {{ quote(configuration) }} DSPTests --report {{ quote(swift_scratch_path + "/test-dsp-results-" + configuration + ".json") }}

# Opt in to unsigned Xcode bundling, which registers the app with macOS but never launches it.
build-app configuration="debug":
  bash scripts/buildApp.sh {{ quote(configuration) }} {{ quote(app_derived_data) }}

_check-clang-format:
  #!/usr/bin/env bash
  set -euo pipefail
  version="$({{ quote(clang_format) }} --version)"
  case "$version" in
    *"clang-format version {{ clang_format_version }}") ;;
    *) printf 'Expected clang-format %s; found %s\n' '{{ clang_format_version }}' "$version" >&2; exit 1 ;;
  esac
