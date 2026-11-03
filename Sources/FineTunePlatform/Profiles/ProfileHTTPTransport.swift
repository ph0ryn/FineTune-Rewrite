import Foundation

public struct ProfileHTTPResponse: Sendable {
  public let data: Data
  public let statusCode: Int

  public init(data: Data, statusCode: Int) {
    self.data = data
    self.statusCode = statusCode
  }
}

public protocol ProfileHTTPTransport: Sendable {
  func get(_ url: URL) async throws -> ProfileHTTPResponse
}

/// A real transport; creating the value starts no request.
public struct URLSessionProfileTransport: ProfileHTTPTransport {
  public init() {}

  public func get(_ url: URL) async throws -> ProfileHTTPResponse {
    let (data, response) = try await URLSession.shared.data(from: url)
    guard let response = response as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    return ProfileHTTPResponse(data: data, statusCode: response.statusCode)
  }
}
