import Foundation
import XCTest
@testable import GTMEasyGrowth

private struct StubInstallProbe: GrowthInstallProbe {
  let signal: GrowthInstallSignal
  func priorInstallSignal(environment: GrowthAnalyticsConfiguration.Environment, currentVersion: String?) async -> GrowthInstallSignal {
    signal
  }
}

final class GrowthAutoInstrumentTests: XCTestCase {
  private func makeAnalytics(_ defaults: UserDefaults, session: MockSession) -> GrowthAnalytics {
    GrowthAnalytics(
      configuration: GrowthAnalyticsConfiguration(
        app: "milelog", writeKey: "k",
        endpoint: URL(string: "https://gtmeasy.test")!, environment: .production, userDefaults: defaults
      ),
      session: session
    )
  }

  private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "GrowthAutoInstrumentTests-\(UUID().uuidString)")!
  }

  private func eventNames(_ session: MockSession) async throws -> [String] {
    let requests = await session.requests
    return try requests.map { request in
      let body = try XCTUnwrap(request.httpBody)
      let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
      return try XCTUnwrap(json?["eventName"] as? String)
    }
  }

  private func properties(_ session: MockSession, at index: Int) async throws -> [String: Any] {
    let requests = await session.requests
    let body = try XCTUnwrap(requests[index].httpBody)
    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    return try XCTUnwrap(json?["properties"] as? [String: Any])
  }

  func testFreshInstallFiresFirstOpenThenAppOpen() async throws {
    let defaults = freshDefaults()
    let session = MockSession(response: #"{"event":{"id":"e","eventName":"x"},"warnings":[]}"#)
    let instrument = GrowthAutoInstrument(
      analytics: makeAnalytics(defaults, session: session),
      defaults: defaults,
      installProbe: NoopInstallProbe(),
      appVersion: { "1.0.0" }, buildNumber: { "10" }
    )
    await instrument.start()
    let names = try await eventNames(session)
    XCTAssertEqual(names, ["app.first_open", "app.opened"])
  }

  func testExistedSignalFiresAppUpdatedNotFirstOpen() async throws {
    let defaults = freshDefaults()
    let session = MockSession(response: #"{"event":{"id":"e","eventName":"x"},"warnings":[]}"#)
    let instrument = GrowthAutoInstrument(
      analytics: makeAnalytics(defaults, session: session),
      defaults: defaults,
      installProbe: StubInstallProbe(signal: .existed),
      appVersion: { "2.3.0" }, buildNumber: { "200" }
    )
    await instrument.start()
    let names = try await eventNames(session)
    XCTAssertEqual(names, ["app.updated", "app.opened"])
    let props = try await properties(session, at: 0)
    XCTAssertEqual(props["reason"] as? String, "pre_existing_install")
    XCTAssertEqual(props["is_real_update"] as? Bool, false)
    XCTAssertNil(props["from_version"])     // unknown for a pre-existing install
  }

  func testRelaunchSameVersionFiresOnlyAppOpen() async throws {
    let defaults = freshDefaults()
    // Seed a prior run at the same version.
    let seed = GrowthInstallState(defaults: defaults)
    _ = seed.resolveLaunch(currentVersion: "1.0.0", currentBuild: "10", signal: .fresh, environment: .production, trackBuildChanges: false, now: Date(timeIntervalSince1970: 1))

    let session = MockSession(response: #"{"event":{"id":"e","eventName":"x"},"warnings":[]}"#)
    let instrument = GrowthAutoInstrument(
      analytics: makeAnalytics(defaults, session: session),
      defaults: defaults,
      appVersion: { "1.0.0" }, buildNumber: { "10" }
    )
    await instrument.start()
    let names = try await eventNames(session)
    XCTAssertEqual(names, ["app.opened"])
  }

  func testVersionChangeFiresAppUpdated() async throws {
    let defaults = freshDefaults()
    let seed = GrowthInstallState(defaults: defaults)
    _ = seed.resolveLaunch(currentVersion: "0.9.0", currentBuild: "9", signal: .fresh, environment: .production, trackBuildChanges: false, now: Date(timeIntervalSince1970: 1))

    let session = MockSession(response: #"{"event":{"id":"e","eventName":"x"},"warnings":[]}"#)
    let instrument = GrowthAutoInstrument(
      analytics: makeAnalytics(defaults, session: session),
      defaults: defaults,
      appVersion: { "1.0.0" }, buildNumber: { "10" }
    )
    await instrument.start()
    let names = try await eventNames(session)
    XCTAssertEqual(names, ["app.updated", "app.opened"])
    let props = try await properties(session, at: 0)
    XCTAssertEqual(props["reason"] as? String, "version_change")
    XCTAssertEqual(props["is_real_update"] as? Bool, true)
    XCTAssertEqual(props["from_version"] as? String, "0.9.0")
    XCTAssertEqual(props["to_version"] as? String, "1.0.0")
  }

  func testMarkInstalledBeforeTrackingSuppressesFirstOpen() async throws {
    let defaults = freshDefaults()
    let session = MockSession(response: #"{"event":{"id":"e","eventName":"x"},"warnings":[]}"#)
    let instrument = GrowthAutoInstrument(
      analytics: makeAnalytics(defaults, session: session),
      defaults: defaults,
      appVersion: { "1.0.0" }, buildNumber: { "10" }
    )
    await instrument.markInstalledBeforeTracking()
    await instrument.start()
    // No app.first_open — just the open. The pre-marked version matches current → launch.
    let names = try await eventNames(session)
    XCTAssertEqual(names, ["app.opened"])
  }
}
