set shell := ["bash", "-euo", "pipefail", "-c"]

swift_paths := "Package.swift Sources App Tests"
swift_scratch_path := env("SWIFT_SCRATCH_PATH", ".build")
app_derived_data := env("APP_DERIVED_DATA", "DerivedData")
build_jobs := env("BUILD_JOBS", "2")
native_patterns := "'*.h' '*.hpp' '*.cpp' '*.mm'"
clang_format := env("CLANG_FORMAT", "clang-format")
clang_format_version := "21.1.8"

# Check formatting, non-launching app packaging, and unit/component/DSP/native tests.
check: _clear-reports lint test-build-app (build "debug") (test "debug") (test-dsp "debug") (test-native "debug") (build "release") (test "release") (test-dsp "release") (test-native "release")

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

# Clear stale events, then record unit/component test results.
test configuration="debug":
  mkdir -p {{ quote(swift_scratch_path) }}
  : > {{ quote(swift_scratch_path + "/test-results-" + configuration + ".xml") }}
  : > {{ quote(swift_scratch_path + "/test-results-" + configuration + "-swift-testing.xml") }}
  : > {{ quote(swift_scratch_path + "/test-events-" + configuration + ".jsonl") }}
  xcrun swift test --scratch-path {{ quote(swift_scratch_path) }} --jobs {{ quote(build_jobs) }} --configuration {{ quote(configuration) }} --xunit-output {{ quote(swift_scratch_path + "/test-results-" + configuration + ".xml") }} --event-stream-output-path {{ quote(swift_scratch_path + "/test-events-" + configuration + ".jsonl") }} --event-stream-version 0

# Run native DSP and public C ABI scenarios without audio devices.
test-dsp configuration="debug":
  mkdir -p {{ quote(swift_scratch_path) }}
  printf '{"schema_version":2,"complete":false,"cases":[]}\n' > {{ quote(swift_scratch_path + "/test-dsp-results-" + configuration + ".json") }}
  xcrun swift run --scratch-path {{ quote(swift_scratch_path) }} --jobs {{ quote(build_jobs) }} --configuration {{ quote(configuration) }} DSPTests --report {{ quote(swift_scratch_path + "/test-dsp-results-" + configuration + ".json") }}

# Run named native ownership/levels and fake-HAL C boundary units, without physical audio.
test-native configuration="debug": (_clear-native-reports configuration) (test-native-hal configuration)
  xcrun swift run --scratch-path {{ quote(swift_scratch_path) }} --jobs {{ quote(build_jobs) }} --configuration {{ quote(configuration) }} NativeStageTests --report {{ quote(swift_scratch_path + "/test-native-stage-results-" + configuration + ".json") }}
  xcrun swift run --scratch-path {{ quote(swift_scratch_path) }} --jobs {{ quote(build_jobs) }} --configuration {{ quote(configuration) }} NativeSlotTests --report {{ quote(swift_scratch_path + "/test-native-slot-results-" + configuration + ".json") }}
  xcrun swift run --scratch-path {{ quote(swift_scratch_path) }} --jobs {{ quote(build_jobs) }} --configuration {{ quote(configuration) }} NativeLevelsTests --report {{ quote(swift_scratch_path + "/test-native-levels-results-" + configuration + ".json") }}
  xcrun swift run --scratch-path {{ quote(swift_scratch_path) }} --jobs {{ quote(build_jobs) }} --configuration {{ quote(configuration) }} NativeRuntimeTests --report {{ quote(swift_scratch_path + "/test-native-runtime-results-" + configuration + ".json") }}

# Compile the real native C boundary with only the external HAL provider replaced.
test-native-hal configuration="debug":
  #!/usr/bin/env bash
  set -euo pipefail
  configuration={{ quote(configuration) }}
  case "$configuration" in
    debug) flags=(-O0 -g) ;;
    release) flags=(-O2 -DNDEBUG) ;;
    *) printf 'Expected debug or release configuration.\n' >&2; exit 64 ;;
  esac
  scratch={{ quote(swift_scratch_path) }}
  directory="$scratch/native-hal-$configuration"
  report="$scratch/test-native-hal-results-$configuration.json"
  mkdir -p "$directory"
  printf '{"schema_version":2,"complete":false,"cases":[]}\n' > "$report"
  executable="$directory/NativeHALContractTests"
  # Do not link NativeAudio: its real SystemHal provider must be unreachable here.
  xcrun clang++ -std=c++20 -Wall -Wextra -Werror -fno-exceptions -fno-rtti \
    -mmacosx-version-min=15.4 -I Sources/AudioDSP/include -I Sources/NativeAudio/include \
    "${flags[@]}" Sources/AudioDSP/AudioDSP.cpp \
    Sources/AudioDSP/Filters/Biquad.cpp Sources/AudioDSP/Filters/AutoEQ.cpp \
    Sources/AudioDSP/Dynamics/Loudness.cpp Sources/AudioDSP/Dynamics/ISO226.cpp \
    Sources/AudioDSP/Dynamics/SoftLimiter.cpp Sources/AudioDSP/Graph/Pipeline.cpp \
    Sources/NativeAudio/BiquadBridge.cpp Sources/NativeAudio/DynamicsBridge.cpp \
    Sources/NativeAudio/PipelineBridge.cpp Sources/NativeAudio/Runtime/NativeRuntime.cpp \
    Tests/NativeHALContractTests/main.cpp "-Wl,-map,$directory/link-map.txt" \
    -framework CoreFoundation -o "$executable" 2>&1 | tee "$directory/build.log"
  symbols="$(xcrun nm -u "$executable")"
  printf '%s\n' "$symbols" > "$directory/undefined-symbols.log"
  if [[ "$symbols" =~ _Audio(Device|Hardware|Object) ]]; then
    printf 'The fake-HAL executable references a real stateful CoreAudio API; refusing to run.\n' >&2
    exit 1
  fi
  linked="$(< "$directory/link-map.txt")"
  if [[ "$linked" == *SystemHal.mm* || "$linked" == *SystemHal.o* ]]; then
    printf 'The real HAL provider was linked into the fake-only unit executable; refusing to run.\n' >&2
    exit 1
  fi
  "$executable" --report "$report" 2>&1 | tee "$directory/run.log"

# Replace every configuration report with a complete:false skeleton before any build/run.
_clear-reports:
  #!/usr/bin/env bash
  set -euo pipefail
  scratch={{ quote(swift_scratch_path) }}
  mkdir -p "$scratch"
  for configuration in debug release; do
    : > "$scratch/test-results-$configuration.xml"
    : > "$scratch/test-results-$configuration-swift-testing.xml"
    : > "$scratch/test-events-$configuration.jsonl"
    for target in dsp native-stage native-slot native-levels native-runtime native-hal; do
      printf '{"schema_version":2,"complete":false,"cases":[]}\n' > "$scratch/test-$target-results-$configuration.json"
    done
  done

# Replace the native reports with complete:false skeletons before the native runners start.
_clear-native-reports configuration="debug":
  #!/usr/bin/env bash
  set -euo pipefail
  scratch={{ quote(swift_scratch_path) }}
  configuration={{ quote(configuration) }}
  mkdir -p "$scratch"
  for target in native-stage native-slot native-levels native-runtime native-hal; do
    printf '{"schema_version":2,"complete":false,"cases":[]}\n' > "$scratch/test-$target-results-$configuration.json"
  done

# Verify the public app-build artifact contract without building or launching the product app.
test-build-app:
  bash Tests/BuildAppTests/buildAppContractTests.sh

# Opt in to Xcode bundling and local ad-hoc signing, without launching the app.
build-app configuration="debug":
  bash build.sh {{ quote(configuration) }} {{ quote(app_derived_data) }}

_check-clang-format:
  #!/usr/bin/env bash
  set -euo pipefail
  version="$({{ quote(clang_format) }} --version)"
  case "$version" in
    *"clang-format version {{ clang_format_version }}") ;;
    *) printf 'Expected clang-format %s; found %s\n' '{{ clang_format_version }}' "$version" >&2; exit 1 ;;
  esac
