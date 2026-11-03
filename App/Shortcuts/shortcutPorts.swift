import AppKit
import FineTuneControl
import FineTunePlatform

@MainActor
protocol AudioEngineDispatching: AnyObject {
  var apps: [AudioApp] { get }
  func setVolume(for app: AudioApp, to volume: Float)
  func setMute(for app: AudioApp, to muted: Bool)
  func toggleMute(for app: AudioApp)
  func currentVolume(for app: AudioApp) -> Float
  func isMuted(for app: AudioApp) -> Bool
  func isAudibleNow(bundleID: String) -> Bool
}

@MainActor
protocol PerAppHUDPresenting: AnyObject {
  func showPerAppVolumeHUD(app: AudioApp, sliderFraction: Double)
  func showPerAppMuteHUD(app: AudioApp, isMuted: Bool)
  func showPerAppNotControlledHUD(displayName: String?, bundleID: String?, icon: NSImage?)
}

@MainActor
protocol MediaKeyHUDPresenting: AnyObject {
  func show(sliderFraction: Double, mute: Bool, deviceName: String)
  func swallowObserved()
}

@MainActor
protocol MediaKeyIconFlashing: AnyObject {
  func flashDevice()
}

extension HUDWindowController: MediaKeyHUDPresenting, PerAppHUDPresenting {}
extension AudioEngine: AudioEngineDispatching {}
