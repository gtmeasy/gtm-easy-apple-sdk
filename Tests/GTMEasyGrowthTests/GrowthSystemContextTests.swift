import Foundation
import XCTest
@testable import GTMEasyGrowth

final class GrowthSystemContextTests: XCTestCase {
  func testBcp47PreferredLanguageNormalizesUnderscoresAndStripsIcuExtensions() {
    XCTAssertEqual(GrowthSystemContext.bcp47PreferredLanguage("en_US"), "en-US")
    XCTAssertEqual(GrowthSystemContext.bcp47PreferredLanguage("zh_Hans_CN"), "zh-Hans-CN")
    XCTAssertEqual(GrowthSystemContext.bcp47PreferredLanguage("en_US@rg=inzzzz"), "en-US")
    XCTAssertEqual(GrowthSystemContext.bcp47PreferredLanguage("en-GB"), "en-GB")
  }

  func testAsContextPropertiesIncludesCoreFields() {
    let snap = GrowthSystemContext(
      locale: "en-US",
      timezone: "America/Los_Angeles",
      region: "US",
      language: "en",
      utcOffsetMinutes: -420,
      preferredLanguages: ["en-US", "es-ES"],
      calendar: "gregorian",
      measurementSystem: "us"
    )
    let props = snap.asContextProperties
    XCTAssertEqual(props["locale"], .string("en-US"))
    XCTAssertEqual(props["timezone"], .string("America/Los_Angeles"))
    XCTAssertEqual(props["region"], .string("US"))
    XCTAssertEqual(props["language"], .string("en"))
    XCTAssertEqual(props["utc_offset_min"], .number(-420))
    XCTAssertEqual(props["preferred_languages"], .array([.string("en-US"), .string("es-ES")]))
    XCTAssertEqual(props["calendar"], .string("gregorian"))
    XCTAssertEqual(props["measurement_system"], .string("us"))
  }

  func testCaptureFromFoundationIsNonEmpty() {
    let snap = GrowthSystemContext.capture()
    XCTAssertFalse(snap.locale.isEmpty)
    XCTAssertFalse(snap.timezone.isEmpty)
    // BCP-47 uses hyphens, not underscores (except we never leave raw ICU @).
    XCTAssertFalse(snap.locale.contains("_"))
    XCTAssertFalse(snap.locale.contains("@"))
  }

  func testTrackUsesInjectedSystemContextForTopLevelAndCtx() async throws {
    let fixed = GrowthSystemContext(
      locale: "zh-Hans-CN",
      timezone: "Asia/Shanghai",
      region: "CN",
      language: "zh",
      utcOffsetMinutes: 480,
      preferredLanguages: ["zh-Hans-CN", "en-US"],
      calendar: "gregorian",
      measurementSystem: "metric"
    )
    let session = MockSession(response: #"{"event":{"id":"evt_1","eventName":"app.opened"},"warnings":[]}"#)
    let analytics = GrowthAnalytics(
      configuration: GrowthAnalyticsConfiguration(
        app: "milelog",
        writeKey: "test-write-key",
        endpoint: URL(string: "https://gtmeasy.test")!,
        environment: .development,
        userDefaults: UserDefaults(suiteName: "GTMEasyGrowthTests-sysctx-\(UUID().uuidString)")!
      ),
      session: session,
      systemContext: FixedGrowthSystemContextProvider(fixed)
    )

    _ = try await analytics.trackAppOpen()

    let captured = await session.firstRequest()
    let request = try XCTUnwrap(captured)
    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    XCTAssertEqual(json["locale"] as? String, "zh-Hans-CN")
    XCTAssertEqual(json["timezone"] as? String, "Asia/Shanghai")

    let props = try XCTUnwrap(json["properties"] as? [String: Any])
    let ctx = try XCTUnwrap(props["_ctx"] as? [String: Any])
    XCTAssertEqual(ctx["locale"] as? String, "zh-Hans-CN")
    XCTAssertEqual(ctx["timezone"] as? String, "Asia/Shanghai")
    XCTAssertEqual(ctx["region"] as? String, "CN")
    XCTAssertEqual(ctx["language"] as? String, "zh")
    XCTAssertEqual(ctx["utc_offset_min"] as? Double, 480)
    XCTAssertEqual(ctx["preferred_languages"] as? [String], ["zh-Hans-CN", "en-US"])
    XCTAssertEqual(ctx["measurement_system"] as? String, "metric")
    XCTAssertEqual(ctx["sdk"] as? String, "gtm-easy-swift")
    XCTAssertEqual(ctx["sdk_version"] as? String, GrowthAnalytics.sdkVersion)
  }

  func testIdentifyAndSurveyUseInjectedLocale() async throws {
    let fixed = GrowthSystemContext(
      locale: "de-DE",
      timezone: "Europe/Berlin",
      region: "DE",
      language: "de",
      utcOffsetMinutes: 120
    )
    let session = MockSession(response: #"{"event":null,"warnings":[],"submissionId":"s1","accepted":0}"#)
    let analytics = GrowthAnalytics(
      configuration: GrowthAnalyticsConfiguration(
        app: "milelog",
        writeKey: "test-write-key",
        endpoint: URL(string: "https://gtmeasy.test")!,
        environment: .development,
        userDefaults: UserDefaults(suiteName: "GTMEasyGrowthTests-sysctx-id-\(UUID().uuidString)")!
      ),
      session: session,
      systemContext: FixedGrowthSystemContextProvider(fixed)
    )

    _ = try await analytics.identify(userId: "u1")
    let identifyCaptured = await session.firstRequest()
    let identifyReq = try XCTUnwrap(identifyCaptured)
    let identifyBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(identifyReq.httpBody)) as? [String: Any])
    XCTAssertEqual(identifyBody["locale"] as? String, "de-DE")
    XCTAssertEqual(identifyBody["timezone"] as? String, "Europe/Berlin")

    _ = try await analytics.submitSurvey(surveyId: "s", responses: [])
    let surveyCaptured = await session.lastRequest()
    let surveyReq = try XCTUnwrap(surveyCaptured)
    let surveyBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(surveyReq.httpBody)) as? [String: Any])
    XCTAssertEqual(surveyBody["locale"] as? String, "de-DE")
  }
}
