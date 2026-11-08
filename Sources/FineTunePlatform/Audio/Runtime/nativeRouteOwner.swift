import Dispatch
import Foundation
import NativeAudio

/// Immutable pointer ownership is shareable; all blocking operations still use this route's lane.
/// Release happens only after the final Swift borrower disappears and native retirement succeeds.
final class NativeRouteOwner: @unchecked Sendable {
  let pointer: NativeRoutePointer
  let lane: DispatchQueue
  let reportCleanup: @Sendable (FTNativeError) -> Void
  let reportRetired: @Sendable () -> Void
  let cleanupOwnerID: UUID
  let retirementPool: NativeRetirementPool

  init(
    pointer: NativeRoutePointer, lane: DispatchQueue, cleanupOwnerID: UUID,
    retirementPool: NativeRetirementPool,
    reportCleanup: @escaping @Sendable (FTNativeError) -> Void,
    reportRetired: @escaping @Sendable () -> Void
  ) {
    self.pointer = pointer
    self.lane = lane
    self.cleanupOwnerID = cleanupOwnerID
    self.retirementPool = retirementPool
    self.reportCleanup = reportCleanup
    self.reportRetired = reportRetired
  }

  @MainActor
  func perform<Result: Sendable>(
    _ body: @escaping @Sendable (OpaquePointer) -> Result
  ) async -> Result {
    await withCheckedContinuation { continuation in
      lane.async { [self] in continuation.resume(returning: body(pointer.value)) }
    }
  }

  func cancel() { ft_native_route_cancel(pointer.value) }

  deinit {
    ft_native_route_cancel(pointer.value)
    retirementPool.adopt(
      pointer, lane: lane, cleanupOwnerID: cleanupOwnerID,
      reportCleanup: reportCleanup, reportRetired: reportRetired)
  }
}

/// Failed/pending native owners remain owned, not timer-delayed or freed optimistically.
/// Native admission bounds the total to 256. This timer only rechecks a pending predicate;
/// failures are retained and reported, not retried in a tight or automatic failure loop.
final class NativeRetirementPool: @unchecked Sendable {
  static let shared = NativeRetirementPool()
  private let lane = DispatchQueue(label: "FineTune.NativeAudio.Retirement")
  private var entries: [ObjectIdentifier: Entry] = [:]
  private var timer: DispatchSourceTimer?
  private let retireAndRelease: @Sendable (NativeRoutePointer) -> NativeRouteResult

  init(
    retireAndRelease: @escaping @Sendable (NativeRoutePointer) -> NativeRouteResult =
      retireNativeOwner
  ) {
    self.retireAndRelease = retireAndRelease
  }

  private struct RetryWaiter {
    let entries: Set<ObjectIdentifier>
    let continuation: CheckedContinuation<Void, Never>
  }
  private var retryWaiters: [RetryWaiter] = []

  func retryFailed(cleanupOwnerID: UUID) async {
    await withCheckedContinuation { continuation in
      lane.async { [self] in
        let selected = entries.filter { $0.value.cleanupOwnerID == cleanupOwnerID }
        guard !selected.isEmpty else {
          continuation.resume()
          return
        }
        // Rearm only failures from this factory. PENDING/in-flight entries keep their existing
        // operation and polling cadence; another explicit request merely joins their settlement.
        for entry in selected.values where entry.failed { entry.failed = false }
        retryWaiters.append(
          RetryWaiter(entries: Set(selected.keys), continuation: continuation))
        beginMonitoring()
      }
    }
  }

  private func finishRetries() {
    for index in retryWaiters.indices.reversed()
    where retryWaiters[index].entries.allSatisfy({
      entries[$0] == nil || entries[$0]?.failed == true
    }) {
      retryWaiters.remove(at: index).continuation.resume()
    }
  }

  private final class Entry: @unchecked Sendable {
    let pointer: NativeRoutePointer
    let lane: DispatchQueue
    let reportCleanup: @Sendable (FTNativeError) -> Void
    let reportRetired: @Sendable () -> Void
    let cleanupOwnerID: UUID
    var inFlight = false
    var failed = false
    init(
      _ pointer: NativeRoutePointer, lane: DispatchQueue, cleanupOwnerID: UUID,
      reportCleanup: @escaping @Sendable (FTNativeError) -> Void,
      reportRetired: @escaping @Sendable () -> Void
    ) {
      self.pointer = pointer
      self.lane = lane
      self.cleanupOwnerID = cleanupOwnerID
      self.reportCleanup = reportCleanup
      self.reportRetired = reportRetired
    }
  }

  func adopt(
    _ pointer: NativeRoutePointer, lane routeLane: DispatchQueue, cleanupOwnerID: UUID,
    reportCleanup: @escaping @Sendable (FTNativeError) -> Void,
    reportRetired: @escaping @Sendable () -> Void
  ) {
    lane.async { [self] in
      let entry = Entry(
        pointer, lane: routeLane, cleanupOwnerID: cleanupOwnerID,
        reportCleanup: reportCleanup, reportRetired: reportRetired)
      entries[ObjectIdentifier(entry)] = entry
      beginMonitoring()
    }
  }

  private func beginMonitoring() {
    guard timer == nil else { return }
    let source = DispatchSource.makeTimerSource(queue: lane)
    source.schedule(deadline: .now(), repeating: .milliseconds(20))
    source.setEventHandler { [weak self] in self?.service() }
    timer = source
    source.resume()
  }

  private func service() {
    for (id, entry) in entries where !entry.inFlight && !entry.failed {
      entry.inFlight = true
      entry.lane.async { [self, entry] in
        let outcome = retireAndRelease(entry.pointer)
        lane.async { [self, entry] in
          entry.inFlight = false
          if outcome.result == FT_NATIVE_OK {
            entries.removeValue(forKey: id)
            entry.reportRetired()
          } else if outcome.result == FT_NATIVE_FAILED {
            entry.failed = true
            entry.reportCleanup(outcome.failure)
          }
          finishRetries()
          if !entries.values.contains(where: { !$0.failed }) {
            timer?.cancel()
            timer = nil
          }
        }
      }
    }
  }
}

private func retireNativeOwner(_ pointer: NativeRoutePointer) -> NativeRouteResult {
  var error = FTNativeError()
  var result = ft_native_route_retire(pointer.value, &error)
  if result == FT_NATIVE_OK { result = ft_native_route_release(pointer.value) }
  return NativeRouteResult(result: result, snapshot: FTNativeRouteSnapshot(), failure: error)
}

final class NativeRouteMonitor: @unchecked Sendable {
  private let source: DispatchSourceTimer
  init(_ event: @escaping @Sendable () -> Void) {
    source = DispatchSource.makeTimerSource(queue: .main)
    source.schedule(deadline: .now(), repeating: .milliseconds(20))
    source.setEventHandler(handler: event)
    source.resume()
  }
  func cancel() { source.cancel() }
  deinit { source.cancel() }
}
