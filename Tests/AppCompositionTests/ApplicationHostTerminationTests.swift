import AppKit
import Testing

@testable import FineTune

@Suite("Original AppKit termination contract")
@MainActor
struct ApplicationHostTerminationTests {
  @Test("Quit uses normal AppKit termination with synchronous will-terminate cleanup")
  func quitDoesNotEnterDeferredTermination() {
    let host = ApplicationHost()
    // These are the public optional-delegate capabilities AppKit consults, not a fake Quit action.
    // Never terminate the test runner or start the production audio/OS services in this test.
    #expect(!host.responds(to: #selector(NSApplicationDelegate.applicationShouldTerminate(_:))))
    #expect(host.responds(to: #selector(NSApplicationDelegate.applicationWillTerminate(_:))))
  }
}
