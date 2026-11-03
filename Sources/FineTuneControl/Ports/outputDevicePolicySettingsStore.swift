/// The same real store's output priority, including reconnect-preserving order maintained by the store.
@MainActor
public protocol OutputDevicePolicySettingsStore: AnyObject {
  var devicePriorityOrder: [String] { get }
  func ensureDeviceInPriority(_ uid: String)
}
