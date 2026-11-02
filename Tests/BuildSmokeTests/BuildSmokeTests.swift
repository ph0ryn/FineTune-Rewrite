import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import NativeAudio
import NativeBuildSupport
import Testing

@Suite("Development toolchain smoke tests")
struct BuildSmokeTests {
  @Test("Swift can call a C API implemented in C++20")
  func cppInterop() {
    #expect(ft_test_cpp_language_version() >= 202002)
  }

  @Test("Swift can call Objective-C++ linked with Foundation")
  func objectiveCppInterop() {
    #expect(ft_test_objc_runtime_available())
  }
}
