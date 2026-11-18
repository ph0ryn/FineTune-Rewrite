set shell := ["bash", "-euo", "pipefail", "-c"]

swift_paths := "Package.swift Sources App Tests"
swift_scratch_path := env("SWIFT_SCRATCH_PATH", ".build")
app_derived_data := env("APP_DERIVED_DATA", "DerivedData")
build_jobs := env("BUILD_JOBS", "2")
native_patterns := "'*.h' '*.hpp' '*.cpp' '*.mm'"
clang_format := env("CLANG_FORMAT", "clang-format")
clang_format_version := "21.1.8"

# Check formatting, packaging contracts, Swift unit/contract tests, DSP, and native boundaries.
check configuration="debug": lint (test-unit configuration) (test-contract configuration) (test-dsp configuration) (test-native configuration)

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

# Run isolated Swift test suites in order (unit, contract, then serialized UI).
test configuration="debug": (test-unit configuration) (test-contract configuration) (test-ui configuration)

# Run a filtered Swift test process and reject an empty match set.
_swift_test configuration filter serialized="false":
  #!/usr/bin/env bash
  set -euo pipefail
  args=(
    --scratch-path {{ quote(swift_scratch_path) }}
    --jobs {{ quote(build_jobs) }}
    --configuration {{ quote(configuration) }}
    --filter {{ quote(filter) }}
  )
  if [[ {{ quote(serialized) }} == "true" ]]; then
    args+=(--no-parallel)
  fi
  set +e
  output="$(xcrun swift test "${args[@]}" 2>&1)"
  status=$?
  set -e
  printf '%s\n' "$output"
  if (( status != 0 )); then
    exit "$status"
  fi
  if grep -q 'No matching test cases were run' <<<"$output"; then
    printf 'No tests matched filter %s; refusing to treat this as success.\n' {{ quote(filter) }} >&2
    exit 1
  fi

# Run fast, pure unit tests with zero AppKit, WindowServer, HAL, or disk-store dependencies.
test-unit configuration="debug": (_swift_test configuration "DomainTests|ControlTests|AppPresentationContractTests")

# Run DI/I/O boundary, composition wiring, Swift-native ABI, and app-packaging contract tests.
test-contract configuration="debug": test-build-app (_swift_test configuration "PlatformTests|NativeContractTests|AppCompositionTests")

# Run rendered AppKit/View tests in an isolated, serialized process.
test-ui configuration="debug": (_swift_test configuration "AppRenderedTests" "true")

# Run offline DSP and public C ABI scenarios without audio devices.
test-dsp configuration="debug":
  xcrun swift run --scratch-path {{ quote(swift_scratch_path) }} --jobs {{ quote(build_jobs) }} --configuration {{ quote(configuration) }} DSPTests

# Run native stage/slot/levels ownership tests and fake-HAL C boundary tests.
test-native configuration="debug": (test-native-hal configuration)
  #!/usr/bin/env bash
  set -euo pipefail
  scratch={{ quote(swift_scratch_path) }}
  config={{ quote(configuration) }}
  jobs={{ quote(build_jobs) }}
  for product in NativeStageTests NativeSlotTests NativeLevelsTests; do
    xcrun swift build --scratch-path "$scratch" --jobs "$jobs" --configuration "$config" --product "$product"
  done
  bin_dir="$(xcrun swift build --scratch-path "$scratch" --configuration "$config" --show-bin-path)"
  "$bin_dir/NativeStageTests"
  "$bin_dir/NativeSlotTests"
  "$bin_dir/NativeLevelsTests"

# Compile and run the real native C boundary with only the external HAL provider replaced.
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
  mkdir -p "$directory"
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
    Tests/NativeHALContractTests/*.cpp "-Wl,-map,$directory/link-map.txt" \
    -framework CoreFoundation -o "$executable"
  symbols="$(xcrun nm -u "$executable")"
  if [[ "$symbols" =~ _Audio(Device|Hardware|Object) ]]; then
    printf 'The fake-HAL executable references a real stateful CoreAudio API; refusing to run.\n' >&2
    exit 1
  fi
  linked="$(< "$directory/link-map.txt")"
  if [[ "$linked" == *SystemHal.mm* || "$linked" == *SystemHal.o* ]]; then
    printf 'The real HAL provider was linked into the fake-only unit executable; refusing to run.\n' >&2
    exit 1
  fi
  "$executable"

# Run all C++ DSP and native boundary suites under ASan and UBSan without physical audio.
test-native-sanitizers:
  #!/usr/bin/env bash
  set -euo pipefail
  directory={{ quote(swift_scratch_path) }}/native-sanitizers
  mkdir -p "$directory"
  common_flags=(
    -std=c++20 -Wall -Wextra -Werror -fno-exceptions -fno-rtti
    -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer
    -mmacosx-version-min=15.4 -I Sources/AudioDSP/include -I Sources/NativeAudio/include
  )
  dsp_sources=(
    Sources/AudioDSP/AudioDSP.cpp
    Sources/AudioDSP/Filters/Biquad.cpp Sources/AudioDSP/Filters/AutoEQ.cpp
    Sources/AudioDSP/Dynamics/Loudness.cpp Sources/AudioDSP/Dynamics/ISO226.cpp
    Sources/AudioDSP/Dynamics/SoftLimiter.cpp Sources/AudioDSP/Graph/Pipeline.cpp
    Sources/NativeAudio/BiquadBridge.cpp Sources/NativeAudio/DynamicsBridge.cpp
    Sources/NativeAudio/PipelineBridge.cpp
  )
  xcrun clang++ "${common_flags[@]}" "${dsp_sources[@]}" \
    Tools/DSPTests/main.cpp Tools/DSPTests/LoudnessCompatibilityTests.cpp \
    -o "$directory/DSPTests"
  xcrun clang++ "${common_flags[@]}" "${dsp_sources[@]}" \
    Tests/NativeStageTests/main.cpp -o "$directory/NativeStageTests"
  xcrun clang++ "${common_flags[@]}" \
    Tests/NativeRuntimeTests/CallbackSlotsTests.cpp -o "$directory/NativeSlotTests"
  xcrun clang++ "${common_flags[@]}" \
    Tests/NativeRuntimeTests/CoherentLevelsTests.cpp -o "$directory/NativeLevelsTests"
  xcrun clang++ "${common_flags[@]}" "${dsp_sources[@]}" \
    Sources/NativeAudio/Runtime/NativeRuntime.cpp Tests/NativeHALContractTests/*.cpp \
    "-Wl,-map,$directory/hal-link-map.txt" -framework CoreFoundation \
    -o "$directory/NativeHALContractTests"
  if [[ "$(xcrun nm -u "$directory/NativeHALContractTests")" =~ _Audio(Device|Hardware|Object) ]]; then
    printf 'The fake-HAL sanitizer executable references a real CoreAudio API; refusing to run.\n' >&2
    exit 1
  fi
  if [[ "$(< "$directory/hal-link-map.txt")" == *SystemHal* ]]; then
    printf 'The real HAL provider was linked into the fake-only sanitizer executable; refusing to run.\n' >&2
    exit 1
  fi
  "$directory/DSPTests"
  "$directory/NativeStageTests"
  "$directory/NativeSlotTests"
  "$directory/NativeLevelsTests"
  "$directory/NativeHALContractTests"

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
