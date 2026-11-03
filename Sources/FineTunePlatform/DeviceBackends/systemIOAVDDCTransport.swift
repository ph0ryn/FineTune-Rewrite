import Darwin
import Foundation
import IOKit
import OSLog

/// Optional, fixed-source IOAV ABI. Symbol resolution does not establish ABI or hardware correctness.
/// Discovery, complete wire transactions, CF release and library teardown share one non-realtime queue.
public final class SystemIOAVDDCTransport: DDCDisplayTransport, @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "com.finetune-rewrite.ddc", qos: .utility, autoreleaseFrequency: .workItem)
  private let resources = IOAVOwnedResources()

  public init() {}

  deinit {
    let owned = resources
    queue.async {
      do { try owned.close() } catch {
        IOAVDiagnostics.logger.error("DDC teardown failed: \(error)")
      }
    }
  }

  public func discover() async throws -> [DDCDisplaySnapshot] {
    try await execute { owned, cancellation in try owned.discover(cancellation: cancellation) }
  }

  public func writeVolume(displayID: UUID, percent: Int) async throws -> DDCVCPValue {
    guard (0...100).contains(percent) else {
      throw DeviceBackendError.invalidVolume(Float(percent) / 100)
    }
    return try await execute { owned, cancellation in
      let connection = try owned.connection(for: displayID)
      guard let initialVolume = connection.initialVolume else {
        throw DeviceBackendError.unsupported("DDC volume without a successful probe")
      }
      _ = try DDCVolumeScale.percent(of: initialVolume)
      let session = connection.session(cancellation: cancellation)
      try session.writeVolume(rawValue: UInt16(percent))
      return try session.readVolume()
    }
  }

  public func readVolume(displayID: UUID) async throws -> DDCVCPValue {
    try await execute { owned, cancellation in
      try owned.connection(for: displayID).session(cancellation: cancellation).readVolume()
    }
  }

  public func close() async throws {
    try await execute(ignoringCancellation: true) { owned, _ in try owned.close() }
  }

  private func execute<Value: Sendable>(
    ignoringCancellation: Bool = false,
    _ operation: @escaping @Sendable (IOAVOwnedResources, DeviceIOCancellation) throws -> Value
  ) async throws -> Value {
    let cancellation = DeviceIOCancellation()
    let owned = resources
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          do {
            if !ignoringCancellation { try cancellation.check() }
            let value = try operation(owned, cancellation)
            if !ignoringCancellation { try cancellation.check() }
            continuation.resume(returning: value)
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
  }
}

private enum IOAVDiagnostics {
  static let logger = Logger(subsystem: "com.finetune-rewrite", category: "DDC")
}

/// Only the owning dispatch queue accesses these fields; no CF object crosses the public async API.
private final class IOAVOwnedResources: @unchecked Sendable {
  private var library: IOAVLibrary?
  private var connections: [UUID: IOAVConnection] = [:]

  func connection(for id: UUID) throws -> IOAVConnection {
    guard let value = connections[id] else {
      throw DeviceBackendError.unavailableDevice("DDC display \(id.uuidString)")
    }
    return value
  }

  func close() throws {
    // Release every created CF service while its owning image is still loaded.
    connections.removeAll()
    let loaded = library
    library = nil
    try loaded?.close()
  }

  func discover(cancellation: DeviceIOCancellation) throws -> [DDCDisplaySnapshot] {
    connections.removeAll()
    if library == nil { library = try IOAVLibrary() }
    guard let library else { throw DeviceBackendError.unsupported("DDC volume") }
    var iterator: io_iterator_t = 0
    let status = IOServiceGetMatchingServices(
      kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator)
    guard status == kIOReturnSuccess else { throw DeviceBackendError.osStatus(status) }
    defer { release(iterator) }
    var displays: [DDCDisplaySnapshot] = []
    while true {
      try cancellation.check()
      let entry = IOIteratorNext(iterator)
      guard entry != 0 else { break }
      defer { release(entry) }
      let location =
        IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? String
      if location == "Embedded" { continue }
      let id = UUID()
      let name = displayName(for: entry)
      guard let service = library.create(kCFAllocatorDefault, entry) else {
        displays.append(
          DDCDisplaySnapshot(
            id: id, name: name, edid: nil, volume: nil,
            error: "The display's optional DDC service could not be created."))
        continue
      }
      let connection = IOAVConnection(service: service, library: library)
      let session = connection.session(cancellation: cancellation)
      var edid: DDCDisplayEDID?
      var volume: DDCVCPValue?
      var diagnostics: [String] = []
      do { edid = try session.readEDID() } catch is CancellationError {
        throw CancellationError()
      } catch {
        diagnostics.append(error.localizedDescription)
      }
      do {
        volume = try session.readVolume()
      } catch is CancellationError { throw CancellationError() } catch {
        diagnostics.append(error.localizedDescription)
      }
      if let volume {
        connection.initialVolume = volume
        connections[id] = connection
      }
      displays.append(
        DDCDisplaySnapshot(
          id: id, name: name, edid: edid, volume: volume,
          error: diagnostics.isEmpty ? nil : diagnostics.joined(separator: " ")))
    }
    return displays
  }

  private func displayName(for entry: io_registry_entry_t) -> String? {
    guard IOObjectRetain(entry) == kIOReturnSuccess else { return nil }
    var current = entry
    for _ in 0..<10 {
      if let dictionary = IODisplayCreateInfoDictionary(
        current, UInt32(kIODisplayOnlyPreferredName))?
        .takeRetainedValue() as? [String: Any],
        let names = dictionary[kDisplayProductName] as? [String: String],
        let name = names.values.filter({ !$0.isEmpty }).sorted().first
      {
        release(current)
        return name
      }
      var parent: io_registry_entry_t = 0
      let status = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
      release(current)
      guard status == kIOReturnSuccess, parent != 0 else { return nil }
      current = parent
    }
    release(current)
    // The original "External Display" fallback is not evidence of a known display name.
    return nil
  }

  private func release(_ object: io_object_t) {
    let status = IOObjectRelease(object)
    if status != kIOReturnSuccess {
      IOAVDiagnostics.logger.error("DDC registry release failed: \(status)")
    }
  }
}

private final class IOAVConnection {
  private let service: Unmanaged<CFTypeRef>
  private let library: IOAVLibrary
  var initialVolume: DDCVCPValue?

  init(service: Unmanaged<CFTypeRef>, library: IOAVLibrary) {
    self.service = service
    self.library = library
  }

  deinit {
    // The +1 Create result is balanced explicitly before Swift releases the library field.
    withExtendedLifetime(library) { service.release() }
  }

  func session(cancellation: DeviceIOCancellation) -> DDCWireSession {
    DDCWireSession(
      io: DDCI2COperations(
        write: { [self] chip, address, bytes in
          try cancellation.check()
          let status = bytes.withUnsafeBufferPointer { buffer in
            library.write(
              service.takeUnretainedValue(), chip, address, buffer.baseAddress!,
              UInt32(buffer.count))
          }
          guard status == kIOReturnSuccess else { throw DeviceBackendError.osStatus(status) }
        },
        read: { [self] chip, address, count in
          try cancellation.check()
          var bytes = [UInt8](repeating: 0, count: count)
          let status = bytes.withUnsafeMutableBufferPointer { buffer in
            library.read(
              service.takeUnretainedValue(), chip, address, buffer.baseAddress!,
              UInt32(buffer.count))
          }
          guard status == kIOReturnSuccess else { throw DeviceBackendError.osStatus(status) }
          return bytes
        },
        sleepMilliseconds: { Thread.sleep(forTimeInterval: Double($0) / 1000) }))
  }
}

/// These are exactly the three declarations/image/symbols present in the fixed comparison source.
private final class IOAVLibrary {
  typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
  typealias Read =
    @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutablePointer<UInt8>, UInt32) -> IOReturn
  typealias Write =
    @convention(c) (CFTypeRef, UInt32, UInt32, UnsafePointer<UInt8>, UInt32) -> IOReturn
  let create: Create
  let read: Read
  let write: Write
  private var handle: UnsafeMutableRawPointer?

  init() throws {
    #if arch(arm64)
      let path =
        "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer"
      guard let opened = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
        throw DeviceBackendError.unsupported("The optional DDC API")
      }
      guard let createAddress = dlsym(opened, "IOAVServiceCreateWithService"),
        let readAddress = dlsym(opened, "IOAVServiceReadI2C"),
        let writeAddress = dlsym(opened, "IOAVServiceWriteI2C")
      else {
        dlclose(opened)
        throw DeviceBackendError.unsupported("The optional DDC API symbols")
      }
      handle = opened
      create = unsafeBitCast(createAddress, to: Create.self)
      read = unsafeBitCast(readAddress, to: Read.self)
      write = unsafeBitCast(writeAddress, to: Write.self)
    #else
      throw DeviceBackendError.unsupported("DDC volume on this architecture")
    #endif
  }

  func close() throws {
    guard let opened = handle else { return }
    handle = nil
    guard dlclose(opened) == 0 else {
      throw DeviceBackendError.operationFailed("The optional DDC library could not be closed.")
    }
  }

  deinit {
    if let handle, dlclose(handle) != 0 {
      IOAVDiagnostics.logger.error("The optional DDC library could not be closed during teardown.")
    }
  }
}
