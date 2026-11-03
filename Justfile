swift_paths := "Package.swift Sources Tests"

# Check Swift formatting, then build and test debug and release in order.
check: lint (build "debug") (test "debug") (build "release") (test "release")

# Show the selected Xcode, Swift, Clang, and macOS SDK.
toolchain:
  xcodebuild -version
  xcrun swift --version
  xcrun clang++ --version
  xcrun --sdk macosx --show-sdk-path

# Check Swift formatting without changing files.
lint:
  xcrun swift format lint --strict --recursive {{ swift_paths }}

# Format Swift sources in place.
format:
  xcrun swift format format --in-place --recursive {{ swift_paths }}

# Build the package in debug or release configuration.
build configuration="debug":
  xcrun swift build --configuration {{ quote(configuration) }}

# Run smoke tests in debug or release configuration.
test configuration="debug":
  xcrun swift test --configuration {{ quote(configuration) }}
