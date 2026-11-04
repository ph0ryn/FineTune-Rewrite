import FineTunePlatform

/// UI-only image ownership. The Root supplies cached device state; this never discovers hardware.
@MainActor
final class RootMenuBarIconCoordinator: MediaKeyIconFlashing {
  private let readBaseline: () -> MenuBarIconState
  private let readDeviceSymbol: () -> String
  private let apply: (MenuBarIconImage) -> Void
  private let clock: DeviceBackendClock
  private var isRunning = false
  private var flashingSymbol: String?
  private var restoreTask: Task<Void, Never>?

  init(
    readBaseline: @escaping () -> MenuBarIconState,
    readDeviceSymbol: @escaping () -> String,
    apply: @escaping (MenuBarIconImage) -> Void, clock: DeviceBackendClock
  ) {
    self.readBaseline = readBaseline
    self.readDeviceSymbol = readDeviceSymbol
    self.apply = apply
    self.clock = clock
  }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    refresh()
  }

  func refresh() {
    guard isRunning else { return }
    let state = flashingSymbol.map { MenuBarIconState.deviceFlash(symbol: $0) } ?? readBaseline()
    apply(state.image)
  }

  func flashDevice() {
    guard isRunning else { return }
    flashingSymbol = readDeviceSymbol()
    refresh()
    restoreTask?.cancel()
    let clock = clock
    restoreTask = Task { @MainActor [weak self] in
      do { try await clock.sleep(.seconds(1.1)) } catch { return }
      guard !Task.isCancelled, let self, self.isRunning else { return }
      self.flashingSymbol = nil
      self.restoreTask = nil
      self.refresh()
    }
  }

  func stop() {
    isRunning = false
    restoreTask?.cancel()
    restoreTask = nil
    flashingSymbol = nil
  }

  deinit { restoreTask?.cancel() }
}
