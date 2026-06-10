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

  func testIdentifyPostsUsernameAndEmail() async throws {
    let session = MockSession(response: #"{"event":null,"warnings":[]}"#)
    let analytics = GrowthAnalytics(configuration: configuration(), session: session)

    _ = try await analytics.identify(userId: "user_123", username: "john_wayne", email: "  John@Example.com ")

    let captured = await session.firstRequest()
    let request = try XCTUnwrap(captured)
    let body = try XCTUnwrap(request.httpBody)
    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    XCTAssertEqual(json?["username"] as? String, "john_wayne")
    // Client trims; the server lowercases. We keep the trimmed plaintext here.
    XCTAssertEqual(json?["email"] as? String, "John@Example.com")
  }

  func testIdentityPersistsAcrossInstances() async throws {
    let defaults = UserDefaults(suiteName: "GTMEasyGrowthTests-persist-\(UUID().uuidString)")!
    let config = GrowthAnalyticsConfiguration(
      app: "milelog", writeKey: "test-write-key",
      endpoint: URL(string: "https://gtmeasy.test")!, environment: .development, userDefaults: defaults
    )
    let first = GrowthAnalytics(configuration: config, session: MockSession(response: #"{"event":null,"warnings":[]}"#))
    _ = try await first.identify(userId: "user_123", username: "jw", email: "jw@example.com")

    // Simulate an app relaunch: fresh instance, same durable UserDefaults.
    let session = MockSession(response: #"{"event":null,"warnings":[]}"#)
    let second = GrowthAnalytics(configuration: config, session: session)
    let restored = await second.getUserId()
    XCTAssertEqual(restored, "user_123")
    _ = try await second.track("paywall.opened")
    let captured = await session.firstRequest()
    let request = try XCTUnwrap(captured)
    let httpBody = try XCTUnwrap(request.httpBody)
    let json = try JSONSerialization.jsonObject(with: httpBody) as? [String: Any]
    XCTAssertEqual(json?["userId"] as? String, "user_123")
  }

  func testResetClearsIdentityAndRotatesAnonymousId() async throws {
    let analytics = GrowthAnalytics(configuration: configuration(), session: MockSession(response: #"{"event":null,"warnings":[]}"#))
    _ = try await analytics.identify(userId: "user_123", email: "u@example.com")
    let before = await analytics.getAnonymousId()
    await analytics.reset()
    let clearedUser = await analytics.getUserId()
    XCTAssertNil(clearedUser)
    let after = await analytics.getAnonymousId()
    XCTAssertNotEqual(before, after)
  }

  func testSubmitSurveyPostsTypedAnswers() async throws {
    let session = MockSession(response: #"{"submissionId":"sub_1","accepted":3,"warnings":[]}"#)
    let analytics = GrowthAnalytics(configuration: configuration(), session: session)
    _ = try await analytics.identify(userId: "user_9")

    let response = try await analytics.submitSurvey(
      surveyId: "onboarding_v1",
      responses: [
        .singleChoice("source", "tiktok", label: "TikTok", questionText: "Where did you hear about us?", metadata: ["ms": .number(640)]),
        .rating("satisfaction", 5),
        .text("goal", "Track my screen time"),
      ],
      surveyName: "Onboarding",
      surveyVersion: "2",
      metadata: ["variant": .string("B"), "flow": .string("paywall_first")]
    )

    XCTAssertEqual(response.submissionId, "sub_1")
    XCTAssertEqual(response.accepted, 3)

    let captured = await session.lastRequest()
    let request = try XCTUnwrap(captured)
    XCTAssertEqual(request.url?.path, "/api/v1/growth/surveys")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-gtm-growth-key"), "test-write-key")

    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    XCTAssertEqual(json["surveyId"] as? String, "onboarding_v1")
    XCTAssertEqual(json["surveyName"] as? String, "Onboarding")
    XCTAssertEqual(json["status"] as? String, "completed")
    XCTAssertEqual(json["userId"] as? String, "user_9")
    // The SDK mints the idempotency key on-device (no caller value here) and
    // SENDS it, so a transparent retry reuses the same key for server dedup.
    let submissionId = try XCTUnwrap(json["submissionId"] as? String)
    XCTAssertEqual(submissionId.count, 36)
    // Common context rides under properties._ctx, exactly like track().
    let props = try XCTUnwrap(json["properties"] as? [String: Any])
    let ctx = try XCTUnwrap(props["_ctx"] as? [String: Any])
    XCTAssertEqual(ctx["sdk"] as? String, "gtm-easy-swift")

    let responses = try XCTUnwrap(json["responses"] as? [[String: Any]])
    XCTAssertEqual(responses.count, 3)
    XCTAssertEqual(responses[0]["type"] as? String, "single_choice")
    XCTAssertEqual(responses[0]["choices"] as? [String], ["tiktok"])
    XCTAssertEqual(responses[0]["choiceLabels"] as? [String], ["TikTok"])
    XCTAssertEqual(responses[1]["type"] as? String, "rating")
    XCTAssertEqual(responses[1]["number"] as? Double, 5)
    XCTAssertEqual(responses[2]["text"] as? String, "Track my screen time")
    // Optional nil fields must be omitted, not encoded as null.
    XCTAssertNil(responses[2]["choices"])

    // Submission-level metadata is echoed onto the body; per-answer metadata
    // rides on the answer row. Answers without metadata omit the key entirely.
    let metadata = try XCTUnwrap(json["metadata"] as? [String: Any])
    XCTAssertEqual(metadata["variant"] as? String, "B")
    XCTAssertEqual(metadata["flow"] as? String, "paywall_first")
    let firstAnswerMeta = try XCTUnwrap(responses[0]["metadata"] as? [String: Any])
    XCTAssertEqual(firstAnswerMeta["ms"] as? Double, 640)
    XCTAssertNil(responses[1]["metadata"])
  }

  func testTrackSurveyShownEmitsLifecycleEvent() async throws {
    let session = MockSession(response: #"{"event":{"id":"evt_2","eventName":"survey.shown"},"warnings":[]}"#)
    let analytics = GrowthAnalytics(configuration: configuration(), session: session)

    _ = try await analytics.trackSurveyShown(surveyId: "onboarding_v1", surveyName: "Onboarding")

    let captured = await session.lastRequest()
    let request = try XCTUnwrap(captured)
    XCTAssertEqual(request.url?.path, "/api/v1/growth/events")
    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    XCTAssertEqual(json["eventName"] as? String, "survey.shown")
    let props = try XCTUnwrap(json["properties"] as? [String: Any])
    XCTAssertEqual(props["survey_id"] as? String, "onboarding_v1")
  }

  func testDisabledSuppressesAllNetworkCalls() async throws {
    let session = MockSession(response: #"{"event":{"id":"evt_1","eventName":"app.opened"},"warnings":[]}"#)
    let disabledConfig = GrowthAnalyticsConfiguration(
      app: "milelog",
      writeKey: "test-write-key",
      endpoint: URL(string: "https://gtmeasy.test")!,
      environment: .development,
      userDefaults: UserDefaults(suiteName: "GTMEasyGrowthTests-disabled-\(UUID().uuidString)")!,
      disabled: true
    )
    let analytics = GrowthAnalytics(configuration: disabledConfig, session: session)

    let identifyRes = try await analytics.identify(userId: "user_123", traits: ["plan": .string("pro")])
    let trackRes = try await analytics.track("paywall.opened")
    let surveyRes = try await analytics.submitSurvey(surveyId: "s1", responses: [])

    let requests = await session.requests
    XCTAssertTrue(requests.isEmpty)
    XCTAssertNil(identifyRes.event)
    XCTAssertNil(trackRes.event)
    XCTAssertEqual(surveyRes.accepted, 0)
    XCTAssertFalse(surveyRes.submissionId.isEmpty)
  }

  func testDisabledEchosCallerSubmissionId() async throws {
    let session = MockSession(response: "{}")
    let disabledConfig = GrowthAnalyticsConfiguration(
      app: "milelog",
      writeKey: "test-write-key",
      endpoint: URL(string: "https://gtmeasy.test")!,
      userDefaults: UserDefaults(suiteName: "GTMEasyGrowthTests-disabled-sub-\(UUID().uuidString)")!,
      disabled: true
    )
    let analytics = GrowthAnalytics(configuration: disabledConfig, session: session)
    let res = try await analytics.submitSurvey(surveyId: "s1", responses: [], submissionId: "caller-id")
    XCTAssertEqual(res.submissionId, "caller-id")
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

  func lastRequest() -> URLRequest? {
    requests.last
  }
}
