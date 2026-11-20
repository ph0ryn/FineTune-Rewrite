# Shared clang++ inputs and fake-HAL link checks for the native Just recipes.

common_flags=(
  -std=c++20 -Wall -Wextra -Werror -fno-exceptions -fno-rtti
  -mmacosx-version-min=15.4
  -I Sources/AudioDSP/include -I Sources/NativeAudio/include
)

dsp_sources=(
  Sources/AudioDSP/AudioDSP.cpp
  Sources/AudioDSP/Filters/Biquad.cpp
  Sources/AudioDSP/Filters/AutoEQ.cpp
  Sources/AudioDSP/Dynamics/Loudness.cpp
  Sources/AudioDSP/Dynamics/ISO226.cpp
  Sources/AudioDSP/Dynamics/SoftLimiter.cpp
  Sources/AudioDSP/Graph/Pipeline.cpp
  Sources/NativeAudio/BiquadBridge.cpp
  Sources/NativeAudio/DynamicsBridge.cpp
  Sources/NativeAudio/PipelineBridge.cpp
)

verify_fake_hal() {
  local executable="$1" link_map="$2"
  if [[ "$(xcrun nm -u "$executable")" =~ _Audio(Device|Hardware|Object) ]]; then
    printf 'The fake-HAL executable references a real stateful CoreAudio API; refusing to run.\n' >&2
    return 1
  fi
  if [[ "$(< "$link_map")" == *SystemHal* ]]; then
    printf 'The real HAL provider was linked into the fake-only executable; refusing to run.\n' >&2
    return 1
  fi
}
