import Foundation
import XCTest
@testable import GTMEasyGrowth

/// Suppressed instances (test build + `suppressTestBuilds`, or plain `disabled`) must make
/// zero HTTP calls and leave no durable SDK state that would change what a later production
/// build on the same device sends.
final class GrowthSuppressionTests: XCTestCase {
  private let okResponse = #"{"event":{"id":"e","eventName":"x"},"warnings":[]}"#

  private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "GrowthSuppressionTests-\(UUID().uuidString)")!
  }

  private func makeAnalytics(
    _ defaults: UserDefaults,
    session: MockSession,
    suppressed: Bool,
    disabled: Bool = false,
    debug: Bool = false
  ) -> GrowthAnalytics {
    GrowthAnalytics(
      configuration: GrowthAnalyticsConfiguration(
        app: "milelog", writeKey: "k",
        endpoint: URL(string: "https://gtmeasy.test")!, environment: .production, userDefaults: defaults,
        debug: debug,
        disabled: disabled,
        suppressTestBuilds: true
      ),
      session: session,
      // A TestFlight build vs. an App Store build, both detected through injected probes.
      buildChannelProbes: suppressed
        ? stubProbes(receiptURL: URL(fileURLWithPath: "/r/sandboxReceipt"))
        : stubProbes(receiptURL: URL(fileURLWithPath: "/r/receipt"), receiptExists: true)
    )
  }

  /// Wait for any off-main `growthPersistOnMain` write already enqueued, so "nothing was
  /// written" assertions can't pass just because a write hasn't landed yet.
  private func flushMainQueue() async {
    await MainActor.run {}
  }

  private func sdkKeys(_ defaults: UserDefaults) async -> [String] {
    await flushMainQueue()
    return defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("gtm_easy") }.sorted()
  }

  private func eventNames(_ session: MockSession) async throws -> [String] {
    try await session.requests.map { request in
      let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
      return try XCTUnwrap(json?["eventName"] as? String)
    }
  }

  // MARK: - No network, no durable writes

  func testSuppressedMakesNoHTTPCallsAndWritesNoState() async throws {
    let defaults = freshDefaults()
    let session = MockSession(response: okResponse)
    let analytics = makeAnalytics(defaults, session: session, suppressed: true)
    XCTAssertEqual(analytics.resolvedBuildChannel, .testflight)
    XCTAssertTrue(analytics.isSuppressed)

    await analytics.setUserId("user_1")
    let identify = try await analytics.identify(userId: "user_2", username: "jw", email: "jw@example.com")
    let track = try await analytics.track("custom.event", properties: ["a": .number(1)])
    _ = try await analytics.trackAppOpen()
    _ = try await analytics.trackFirstOpen()
    _ = try await analytics.trackAppUpdated(fromVersion: "1", fromBuild: "1", toVersion: "2", toBuild: "2", reason: .versionChange, isRealUpdate: true)
    _ = try await analytics.trackPaywallOpened(placement: "onboarding")
    _ = try await analytics.trackPurchaseCompleted(amount: 9.99, currency: "USD")
    let survey = try await analytics.submitSurvey(surveyId: "s1", responses: [.rating("r", 5)])
    _ = try await analytics.trackSurveyShown(surveyId: "s1")
    let attribution = try await analytics.collectAppleSearchAdsAttribution()
    await analytics.recordClickId(.gclid, value: "g-1")
    let captured = await analytics.captureClickIds(from: URL(string: "https://x.test/?fbclid=f-1&ttclid=t-1")!)
    _ = await analytics.getAnonymousId()
    await analytics.reset()
    _ = await analytics.getAnonymousId()

    let requests = await session.requests
    XCTAssertTrue(requests.isEmpty)
    XCTAssertNil(identify.event)
    XCTAssertNil(track.event)
    XCTAssertEqual(survey.accepted, 0)
    XCTAssertNil(attribution)
    XCTAssertEqual(captured, 2)
    let keys = await sdkKeys(defaults)
    XCTAssertEqual(keys, [])
  }

  func testSuppressedIdentityLivesInMemoryOnly() async throws {
    let defaults = freshDefaults()
    let suppressed = makeAnalytics(defaults, session: MockSession(response: okResponse), suppressed: true)
    _ = try await suppressed.identify(userId: "user_1", email: " a@b.test ")
    let userId = await suppressed.getUserId()
    let email = await suppressed.getEmail()
    XCTAssertEqual(userId, "user_1")
    XCTAssertEqual(email, "a@b.test")

    await flushMainQueue()
    let production = makeAnalytics(defaults, session: MockSession(response: okResponse), suppressed: false)
    let restored = await production.getUserId()
    XCTAssertNil(restored)
  }

  func testSuppressedReusesExistingAnonymousId() async {
    let defaults = freshDefaults()
    defaults.set("existing-anon", forKey: "gtm_easy_growth_anonymous_id")
    let analytics = makeAnalytics(defaults, session: MockSession(response: okResponse), suppressed: true)
    let anonymousId = await analytics.getAnonymousId()
    XCTAssertEqual(anonymousId, "existing-anon")
  }

  func testSuppressedGeneratesInMemoryAnonymousIdWithoutPersisting() async {
    let defaults = freshDefaults()
    let analytics = makeAnalytics(defaults, session: MockSession(response: okResponse), suppressed: true)
    let first = await analytics.getAnonymousId()
    let second = await analytics.getAnonymousId()
    XCTAssertEqual(first, second)
    let keys = await sdkKeys(defaults)
    XCTAssertEqual(keys, [])
  }

  // MARK: - Install state

  func testSuppressedLaunchThenProductionRelaunchFiresFirstOpenOnce() async throws {
    // Both the new flag and plain `disabled` must leave install state untouched.
    for disabled in [false, true] {
      let defaults = freshDefaults()
      let suppressedSession = MockSession(response: okResponse)
      let suppressed = GrowthAutoInstrument(
        analytics: makeAnalytics(defaults, session: suppressedSession, suppressed: !disabled, disabled: disabled),
        defaults: defaults,
        appVersion: { "1.0.0" }, buildNumber: { "10" }
      )
      await suppressed.start()
      await suppressed.stop()
      let suppressedRequests = await suppressedSession.requests
      XCTAssertTrue(suppressedRequests.isEmpty)
      let keys = await sdkKeys(defaults)
      XCTAssertEqual(keys, [], "disabled=\(disabled)")
      XCTAssertFalse(GrowthInstallState(defaults: defaults).firstOpenFired)

      // App Store build replaces the test build; the data container (defaults) is kept.
      let productionSession = MockSession(response: okResponse)
      let production = GrowthAutoInstrument(
        analytics: makeAnalytics(defaults, session: productionSession, suppressed: false),
        defaults: defaults,
        appVersion: { "1.0.0" }, buildNumber: { "11" }
      )
      await production.start()
      await production.stop()
      let names = try await eventNames(productionSession)
      XCTAssertEqual(names, ["app.first_open", "app.opened"], "disabled=\(disabled)")

      let relaunchSession = MockSession(response: okResponse)
      let relaunch = GrowthAutoInstrument(
        analytics: makeAnalytics(defaults, session: relaunchSession, suppressed: false),
        defaults: defaults,
        appVersion: { "1.0.0" }, buildNumber: { "11" }
      )
      await relaunch.start()
      await relaunch.stop()
      let relaunchNames = try await eventNames(relaunchSession)
      XCTAssertEqual(relaunchNames, ["app.opened"], "disabled=\(disabled)")
    }
  }

  func testSuppressedMarkInstalledBeforeTrackingIsNoop() async throws {
    let defaults = freshDefaults()
    let suppressed = GrowthAutoInstrument(
      analytics: makeAnalytics(defaults, session: MockSession(response: okResponse), suppressed: true),
      defaults: defaults,
      appVersion: { "1.0.0" }, buildNumber: { "10" }
    )
    await suppressed.markInstalledBeforeTracking()
    let keys = await sdkKeys(defaults)
    XCTAssertEqual(keys, [])

    let session = MockSession(response: okResponse)
    let production = GrowthAutoInstrument(
      analytics: makeAnalytics(defaults, session: session, suppressed: false),
      defaults: defaults,
      appVersion: { "1.0.0" }, buildNumber: { "10" }
    )
    await production.start()
    await production.stop()
    let names = try await eventNames(session)
    XCTAssertEqual(names, ["app.first_open", "app.opened"])
  }

  // MARK: - Debug sink

  func testDebugSinkMirrorsSuppressedEventsWithMarker() async throws {
    let analytics = makeAnalytics(freshDefaults(), session: MockSession(response: okResponse), suppressed: true, debug: true)
    let label = "suppressed.mirror.\(UUID().uuidString)"
    _ = try await analytics.track(label, properties: ["plan": .string("pro")])

    let recent = await GrowthDebugSink.shared.recent(limit: 200)
    let event = try XCTUnwrap(recent.last { $0.label == label })
    XCTAssertEqual(event.kind, .track)
    XCTAssertTrue(event.suppressed)
    XCTAssertEqual(event.properties["_suppressed"], .bool(true))
    XCTAssertEqual(event.properties["plan"], .string("pro"))
    XCTAssertNil(event.properties["_ctx"])  // no context collection when suppressed
  }

  func testSuppressedWithoutDebugDoesNotMirror() async throws {
    let analytics = makeAnalytics(freshDefaults(), session: MockSession(response: okResponse), suppressed: true, debug: false)
    let label = "suppressed.silent.\(UUID().uuidString)"
    _ = try await analytics.track(label)
    let recent = await GrowthDebugSink.shared.recent(limit: 200)
    XCTAssertFalse(recent.contains { $0.label == label })
  }
}
