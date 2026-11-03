import Dispatch
import Foundation
import NativeAudio

/// Immutable pointer ownership is shareable; all blocking operations still use this route's lane.
/// Release happens only after the final Swift borrower disappears and native retirement succeeds.
final class NativeRouteOwner: @unchecked Sendable {
  let pointer: NativeRoutePointer
  let lane: DispatchQueue
  let reportCleanup: @Sendable (FTNativeError) -> Void

  init(
    pointer: NativeRoutePointer, lane: DispatchQueue,
    reportCleanup: @escaping @Sendable (FTNativeError) -> Void
  ) {
    self.pointer = pointer
    self.lane = lane
    self.reportCleanup = reportCleanup
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
    NativeRetirementPool.shared.adopt(pointer, lane: lane, reportCleanup: reportCleanup)
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

  private final class Entry: @unchecked Sendable {
    let pointer: NativeRoutePointer
    let lane: DispatchQueue
    let reportCleanup: @Sendable (FTNativeError) -> Void
    var inFlight = false
    var failed = false
    init(
      _ pointer: NativeRoutePointer, lane: DispatchQueue,
      reportCleanup: @escaping @Sendable (FTNativeError) -> Void
    ) {
      self.pointer = pointer
      self.lane = lane
      self.reportCleanup = reportCleanup
    }
  }

  func adopt(
    _ pointer: NativeRoutePointer, lane routeLane: DispatchQueue,
    reportCleanup: @escaping @Sendable (FTNativeError) -> Void
  ) {
    lane.async { [self] in
      let entry = Entry(pointer, lane: routeLane, reportCleanup: reportCleanup)
      entries[ObjectIdentifier(entry)] = entry
      if timer == nil {
        let source = DispatchSource.makeTimerSource(queue: lane)
        source.schedule(deadline: .now(), repeating: .milliseconds(20))
        source.setEventHandler { [weak self] in self?.service() }
        timer = source
        source.resume()
      }
    }
  }

  private func service() {
    for (id, entry) in entries where !entry.inFlight && !entry.failed {
      entry.inFlight = true
      entry.lane.async { [self, entry] in
        var error = FTNativeError()
        var result = ft_native_route_retire(entry.pointer.value, &error)
        if result == FT_NATIVE_OK { result = ft_native_route_release(entry.pointer.value) }
        let outcome = NativeRouteResult(
          result: result, snapshot: FTNativeRouteSnapshot(), failure: error)
        lane.async { [self, entry] in
          entry.inFlight = false
          if outcome.result == FT_NATIVE_OK {
            entries.removeValue(forKey: id)
          } else if outcome.result == FT_NATIVE_FAILED {
            entry.failed = true
            entry.reportCleanup(outcome.failure)
          }
          if !entries.values.contains(where: { !$0.failed }) {
            timer?.cancel()
            timer = nil
          }
        }
      }
    }
  }
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
