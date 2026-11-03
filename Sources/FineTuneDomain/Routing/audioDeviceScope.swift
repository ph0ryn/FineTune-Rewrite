/// A device's logical role, independent of HAL object identifiers.
public enum AudioDeviceScope: String, Equatable, Sendable {
  case output, input
}
