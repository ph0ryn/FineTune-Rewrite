import NativeAudio

// Passive, opt-in NRT read on the owner lane. No samples or pointer addresses are recorded.
func nativeInvalidationSnapshot(
  _ pointer: OpaquePointer, enabled: Bool
) -> FTNativeInvalidationSnapshot? {
  guard enabled else { return nil }
  var snapshot = FTNativeInvalidationSnapshot()
  guard ft_native_route_invalidation(pointer, &snapshot) == FT_NATIVE_OK,
    snapshot.source != FT_NATIVE_INVALIDATION_NONE
  else { return nil }
  return snapshot
}

func nativeInvalidationDescription(_ snapshot: FTNativeInvalidationSnapshot) -> String {
  let reason: String
  switch snapshot.reason {
  case FT_NATIVE_INVALIDATION_REASON_NONE: reason = "none"
  case FT_NATIVE_INVALIDATION_PROPERTY_NOTIFICATION: reason = "propertyNotification"
  case FT_NATIVE_INVALIDATION_IO_WRONG_DEVICE: reason = "wrongDevice"
  case FT_NATIVE_INVALIDATION_IO_INPUT_SHAPE: reason = "inputShape"
  case FT_NATIVE_INVALIDATION_IO_OUTPUT_SHAPE: reason = "outputShape"
  case FT_NATIVE_INVALIDATION_IO_ABSENT_OUTPUT: reason = "absentOutput"
  case FT_NATIVE_INVALIDATION_IO_FRAME_MISMATCH: reason = "frameMismatch"
  default: reason = "unknown"
  }
  var fields = [
    "source=\(snapshot.source.rawValue)", "reason=\(reason)(\(snapshot.reason.rawValue))",
  ]
  if snapshot.source == FT_NATIVE_INVALIDATION_PROPERTY {
    fields += [
      "object=\(snapshot.property_object_id)", "count=\(snapshot.property_count)",
      "hasAddress=\(snapshot.has_property_address)",
    ]
    if snapshot.has_property_address {
      fields += [
        "selector=0x\(String(snapshot.property_selector, radix: 16))",
        "scope=0x\(String(snapshot.property_scope, radix: 16))",
        "element=\(snapshot.property_element)",
      ]
    }
  } else if snapshot.source == FT_NATIVE_INVALIDATION_IO {
    fields += [
      "observedDevice=\(snapshot.observed_device_id)",
      "expectedDevice=\(snapshot.expected_device_id)",
    ]
  }
  return fields.joined(separator: " ")
}
