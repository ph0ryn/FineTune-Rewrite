import AppKit
import AudioToolbox
import FineTuneDomain
import Observation

@Observable
@MainActor
public final class AudioDeviceMonitor: AudioDeviceProviding {
  public private(set) var outputDevices: [AudioDevice] = []
  public private(set) var inputDevices: [AudioDevice] = []
  public var onDeviceDisconnected: ((String, String) -> Void)?
  public var onDeviceConnected: ((String, String) -> Void)?
  public var onInputDeviceDisconnected: ((String, String) -> Void)?
  public var onInputDeviceConnected: ((String, String) -> Void)?
  public var onSampleRateChanged: ((String, Double) -> Void)?
  public private(set) var lastError: Error?
  private var listeners:
    [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
  private var rates: [String: Double] = [:]
  private var running = false

  public init() {}

  public func device(for uid: String) -> AudioDevice? { outputDevices.first { $0.uid == uid } }
  public func inputDevice(for uid: String) -> AudioDevice? { inputDevices.first { $0.uid == uid } }

  nonisolated public static func isMeaningfulRateChange(oldRate: Double, newRate: Double) -> Bool {
    newRate > 0 && oldRate != newRate
  }

  public func start() {
    guard !running else { return }
    running = true
    refresh()
  }

  public func stop() {
    for (object, storedAddress, block) in listeners {
      var address = storedAddress
      AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
    }
    listeners.removeAll()
    running = false
  }

  public func refresh() {
    do {
      let ids = try AudioProperties.array(
        .system, kAudioHardwarePropertyDevices, initial: AudioDeviceID.unknown)
      var outputs: [AudioDevice] = []
      var inputs: [AudioDevice] = []
      for id in ids {
        guard let uid = try? id.readDeviceUID(), let name = try? id.readDeviceName() else {
          continue
        }
        let outputStreams = try AudioProperties.array(
          id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput,
          initial: AudioStreamID.unknown
        )
        let inputStreams = try AudioProperties.array(
          id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput,
          initial: AudioStreamID.unknown
        )
        if !outputStreams.isEmpty {
          let transport = id.readTransportType()
          let headphoneSource = try? AudioProperties.read(
            id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput,
            initial: UInt32(0)
          )
          let excluded = ["HomePod", "Apple TV", "Studio Display", "Pro Display XDR"]
            .contains { name.localizedCaseInsensitiveContains($0) }
          let supportsAutoEQ: Bool =
            switch transport {
            case .hdmi, .displayPort, .airPlay, .virtual: false
            case .builtIn: headphoneSource == 0x6864_706E
            default: !excluded
            }
          outputs.append(
            AudioDevice(id: id, uid: uid, name: name, icon: nil, supportsAutoEQ: supportsAutoEQ))
          if let rate = try? id.readNominalSampleRate(), rate > 0 {
            if let oldRate = rates[uid],
              Self.isMeaningfulRateChange(oldRate: oldRate, newRate: rate)
            {
              onSampleRateChanged?(uid, rate)
            }
            rates[uid] = rate
          }
        }
        if !inputStreams.isEmpty {
          inputs.append(AudioDevice(id: id, uid: uid, name: name, icon: nil, supportsAutoEQ: false))
        }
      }
      notifyChanges(
        from: outputDevices, to: outputs, removed: onDeviceDisconnected, added: onDeviceConnected)
      notifyChanges(
        from: inputDevices, to: inputs, removed: onInputDeviceDisconnected,
        added: onInputDeviceConnected)
      outputDevices = outputs
      inputDevices = inputs
      rates = rates.filter { key, _ in outputs.contains { $0.uid == key } }
      lastError = nil
      if running { installListeners(ids: ids) }
    } catch { lastError = error }
  }

  private func notifyChanges(
    from old: [AudioDevice], to new: [AudioDevice], removed: ((String, String) -> Void)?,
    added: ((String, String) -> Void)?
  ) {
    for device in old where !new.contains(device) { removed?(device.uid, device.name) }
    for device in new where !old.contains(device) { added?(device.uid, device.name) }
  }

  private func installListeners(ids: [AudioDeviceID]) {
    for (object, storedAddress, block) in listeners {
      var address = storedAddress
      AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
    }
    listeners.removeAll()
    let properties =
      [(AudioObjectID.system, kAudioHardwarePropertyDevices)]
      + ids.map { ($0, kAudioDevicePropertyNominalSampleRate) }
    for (object, selector) in properties {
      var address = AudioProperties.address(selector)
      let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor [weak self] in self?.refresh() }
      }
      if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
        listeners.append((object, address, block))
      }
    }
  }
}

/// Enumerates the OS process-audio snapshot; observing never creates taps or requests permission.
@Observable
@MainActor
public final class AudioProcessMonitor: AudioProcessMonitoring {
  public private(set) var activeApps: [AudioApp] = []
  public var onAppsChanged: (([AudioApp]) -> Void)?
  public private(set) var lastError: Error?
  private var listener: AudioObjectPropertyListenerBlock?

  public init() {}

  public func start() {
    guard listener == nil else { return }
    refresh()
    var address = AudioProperties.address(kAudioHardwarePropertyProcessObjectList)
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in self?.refresh() }
    }
    let status = AudioObjectAddPropertyListenerBlock(.system, &address, .main, block)
    if status == noErr { listener = block } else { lastError = AudioProperties.error(status) }
  }

  public func stop() {
    guard let listener else { return }
    var address = AudioProperties.address(kAudioHardwarePropertyProcessObjectList)
    AudioObjectRemovePropertyListenerBlock(.system, &address, .main, listener)
    self.listener = nil
  }

  public func refresh() {
    do {
      let objects = try AudioProperties.array(
        .system, kAudioHardwarePropertyProcessObjectList, initial: AudioObjectID.unknown)
      var byPID: [pid_t: [AudioObjectID]] = [:]
      for object in objects {
        let pid = try AudioProperties.read(object, kAudioProcessPropertyPID, initial: pid_t(0))
        if pid > 0 { byPID[pid, default: []].append(object) }
      }
      let apps = byPID.keys.sorted().map { pid in
        let application = NSRunningApplication(processIdentifier: pid)
        return AudioApp(
          id: pid, processObjectIDs: byPID[pid] ?? [],
          name: application?.localizedName ?? ProcessNameLookup.name(for: pid) ?? String(pid),
          icon: application?.icon ?? NSImage(), bundleID: application?.bundleIdentifier
        )
      }
      activeApps = apps
      lastError = nil
      onAppsChanged?(apps)
    } catch { lastError = error }
  }
}
