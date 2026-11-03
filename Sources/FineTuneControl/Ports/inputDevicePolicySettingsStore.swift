import FineTuneDomain

/// The same saved store used by app Control; preferred intent and current fallback lock stay distinct.
@MainActor
public protocol InputDevicePolicySettingsStore: AnyObject {
  var appSettings: AppSettings { get }
  var preferredInputDeviceUID: String? { get }
  var lockedInputDeviceUID: String? { get }
  var inputDevicePriorityOrder: [String] { get }
  func setPreferredInputDeviceUID(_ uid: String?)
  func setLockedInputDeviceUID(_ uid: String?)
}
