import Foundation
import XCTest
@testable import GTMEasyGrowth

final class GrowthAnalyticsTests: XCTestCase {
  func testTrackPostsEventWithWriteKey() async throws {
    let session = MockSession(response: #"{"event":{"id":"evt_1","eventName":"app.opened"},"warnings":[]}"#)
    let analytics = GrowthAnalytics(
      configuration: configuration(),
      session: session
    )

    let response = try await analytics.trackAppOpen()

    XCTAssertEqual(response.event?.eventName, "app.opened")
    let capturedRequest = await session.firstRequest()
    let request = try XCTUnwrap(capturedRequest)
    XCTAssertEqual(request.url?.path, "/api/v1/growth/events")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-gtm-growth-key"), "test-write-key")

    let body = try XCTUnwrap(request.httpBody)
    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    XCTAssertEqual(json?["app"] as? String, "milelog")
    XCTAssertEqual(json?["eventName"] as? String, "app.opened")
    XCTAssertEqual(json?["platform"] as? String, expectedPlatform)
  }

  func testIdentifyPostsUserTraits() async throws {
    let session = MockSession(response: #"{"event":null,"warnings":[]}"#)
    let analytics = GrowthAnalytics(configuration: configuration(), session: session)

    _ = try await analytics.identify(userId: "user_123", traits: ["plan": .string("pro")])

    let capturedRequest = await session.firstRequest()
    let request = try XCTUnwrap(capturedRequest)
    XCTAssertEqual(request.url?.path, "/api/v1/growth/users")
    let body = try XCTUnwrap(request.httpBody)
    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    XCTAssertEqual(json?["userId"] as? String, "user_123")
    XCTAssertEqual((json?["traits"] as? [String: Any])?["plan"] as? String, "pro")
  }

  func testConfigurationDefaultsToProductionEndpoint() {
    let config = GrowthAnalyticsConfiguration(app: "milelog", writeKey: "test-write-key")
    XCTAssertEqual(config.endpoint.absoluteString, "https://www.gtmeasy.com")
    XCTAssertEqual(config.environment, .production)
  }

  func testRejectedResponseThrows() async {
    let session = MockSession(statusCode: 401, response: #"{"error":"bad key"}"#)
    let analytics = GrowthAnalytics(configuration: configuration(), session: session)

    do {
      _ = try await analytics.trackAppOpen()
      XCTFail("Expected rejection")
    } catch GrowthAnalyticsError.ingestRejected(let statusCode, _) {
      XCTAssertEqual(statusCode, 401)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private func configuration() -> GrowthAnalyticsConfiguration {
    GrowthAnalyticsConfiguration(
      app: "milelog",
      writeKey: "test-write-key",
      endpoint: URL(string: "https://gtmeasy.test")!,
      environment: .development,
      userDefaults: UserDefaults(suiteName: "GTMEasyGrowthTests-\(UUID().uuidString)")!
    )
  }

  private var expectedPlatform: String {
    #if os(iOS)
    return "ios"
    #elseif os(macOS)
    return "macos"
    #else
    return "web"
    #endif
  }
}

actor MockSession: GrowthHTTPSession {
  private(set) var requests: [URLRequest] = []
  private let statusCode: Int
  private let response: String

  init(statusCode: Int = 201, response: String) {
    self.statusCode = statusCode
    self.response = response
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    let httpResponse = HTTPURLResponse(
      url: request.url!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: nil
    )!
    return (Data(response.utf8), httpResponse)
  }

  func firstRequest() -> URLRequest? {
    requests.first
  }
}
