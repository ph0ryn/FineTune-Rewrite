import NativeAudio
import Testing

@testable import FineTunePlatform

@Suite("Native invalidation diagnostic metadata")
struct NativeInvalidationDiagnosticTests {
  @Test("Property diagnostics distinguish an absent address from a real zero-valued address")
  func propertyAddressPresenceIsExplicit() {
    var value = FTNativeInvalidationSnapshot()
    value.source = FT_NATIVE_INVALIDATION_PROPERTY
    value.reason = FT_NATIVE_INVALIDATION_PROPERTY_NOTIFICATION
    value.property_object_id = 801
    value.property_count = 3
    value.has_property_address = true
    value.property_selector = 0x736C_6179
    value.property_scope = 0x6F75_7470
    value.property_element = 2
    let detail = nativeInvalidationDescription(value)
    #expect(detail.contains("reason=propertyNotification(1)"))
    #expect(detail.contains("object=801 count=3 hasAddress=true"))
    #expect(detail.contains("selector=0x736c6179 scope=0x6f757470 element=2"))
    value.has_property_address = false
    let absent = nativeInvalidationDescription(value)
    #expect(absent.contains("hasAddress=false"))
    #expect(!absent.contains("selector=") && !absent.contains("scope="))
  }

  @Test("All IO rejection categories retain device identity without samples or raw pointers")
  func ioRejectionNamesAreDistinct() {
    let reasons: [(FTNativeInvalidationReason, String)] = [
      (FT_NATIVE_INVALIDATION_IO_WRONG_DEVICE, "wrongDevice"),
      (FT_NATIVE_INVALIDATION_IO_INPUT_SHAPE, "inputShape"),
      (FT_NATIVE_INVALIDATION_IO_OUTPUT_SHAPE, "outputShape"),
      (FT_NATIVE_INVALIDATION_IO_ABSENT_OUTPUT, "absentOutput"),
      (FT_NATIVE_INVALIDATION_IO_FRAME_MISMATCH, "frameMismatch"),
    ]
    for (reason, name) in reasons {
      var value = FTNativeInvalidationSnapshot()
      value.source = FT_NATIVE_INVALIDATION_IO
      value.reason = reason
      value.observed_device_id = 901
      value.expected_device_id = 902
      let detail = nativeInvalidationDescription(value)
      #expect(detail.contains("reason=\(name)(\(reason.rawValue))"))
      #expect(detail.contains("observedDevice=901 expectedDevice=902"))
      #expect(!detail.contains("selector=") && !detail.contains("pointer="))
    }
  }
}
