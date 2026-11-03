import FineTuneDomain
import Foundation
import Testing

@Suite("Explicit capture preference")
struct CapturePreferenceTests {
  @Test("Only an explicit saved wish enables restoration; missing data never grants access")
  func defaultsOffAndRoundTripsExplicitWish() throws {
    let decoder = JSONDecoder()
    let missing = try decoder.decode(AppSettings.self, from: Data("{}".utf8))
    #expect(!AppSettings().explicitUserCaptureEnabled)
    #expect(!missing.explicitUserCaptureEnabled)

    var enabled = missing
    enabled.explicitUserCaptureEnabled = true
    let data = try JSONEncoder().encode(enabled)
    #expect(try decoder.decode(AppSettings.self, from: data).explicitUserCaptureEnabled)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["explicitUserCaptureEnabled"] as? Bool == true)
    #expect(object["sessionID"] == nil)
    #expect(object["authorizationStatus"] == nil)

    let malformed = Data(#"{"explicitUserCaptureEnabled":"yes"}"#.utf8)
    #expect(throws: DecodingError.self) {
      try decoder.decode(AppSettings.self, from: malformed)
    }
  }
}
