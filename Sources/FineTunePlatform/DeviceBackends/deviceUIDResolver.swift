import AudioToolbox
import Foundation

/// Public HAL UID translation: a missing UID may return noErr with an unknown object, not a device.
public enum CoreAudioDeviceUIDResolver {
  public static func resolve(uid: String) throws -> AudioDeviceID {
    var qualifier = uid as CFString
    var address = AudioProperties.address(kAudioHardwarePropertyTranslateUIDToDevice)
    var device = AudioDeviceID.unknown
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withUnsafePointer(to: &qualifier) { qualifier in
      withUnsafeMutablePointer(to: &device) { device in
        AudioObjectGetPropertyData(
          .system, &address, UInt32(MemoryLayout<CFString>.size), qualifier, &size, device)
      }
    }
    guard status == noErr else { throw DeviceBackendError.osStatus(status) }
    guard device.isValid else { throw DeviceBackendError.unavailableDevice(uid) }
    return device
  }
}
