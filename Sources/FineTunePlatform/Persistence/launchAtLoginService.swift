import ServiceManagement

/// The only persistence-adjacent operation which changes OS registration.
/// Construction and settings loading do not call this service.
@MainActor
public protocol LaunchAtLoginService: AnyObject {
  var isEnabled: Bool { get }
  func setEnabled(_ enabled: Bool) throws
}

@MainActor
public final class SystemLaunchAtLoginService: LaunchAtLoginService {
  public init() {}

  public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

  public func setEnabled(_ enabled: Bool) throws {
    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
  }
}
