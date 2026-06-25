import Foundation
import XCTest
@testable import GTMEasyGrowth

final class GrowthInstallStateTests: XCTestCase {
  private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "GrowthInstallStateTests-\(UUID().uuidString)")!
  }

  private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

  // MARK: - First SDK run

  func testFreshInstallWhenSignalFresh() async {
    let state = GrowthInstallState(defaults: freshDefaults())
    let launch = await state.resolveLaunch(
      currentVersion: "1.0.0", currentBuild: "10", signal: .fresh,
      environment: .production, trackBuildChanges: false, now: epoch
    )
    XCTAssertEqual(launch, .freshInstall)
    XCTAssertTrue(state.firstOpenFired)
    XCTAssertEqual(state.installAt, epoch)
  }

  func testUnknownSignalBiasesToFreshInstall() async {
    // Goal #4: never under-count a genuine acquisition.
    let state = GrowthInstallState(defaults: freshDefaults())
    let launch = await state.resolveLaunch(
      currentVersion: "2.3.0", currentBuild: "200", signal: .unknown,
      environment: .production, trackBuildChanges: false, now: epoch
    )
    XCTAssertEqual(launch, .freshInstall)
    XCTAssertTrue(state.firstOpenFired)
  }

  func testExistedSignalSuppressesFirstOpen() async {
    let state = GrowthInstallState(defaults: freshDefaults())
    let launch = await state.resolveLaunch(
      currentVersion: "2.3.0", currentBuild: "200", signal: .existed,
      environment: .production, trackBuildChanges: false, now: epoch
    )
    XCTAssertEqual(launch, .update(reason: .preExistingInstall, fromVersion: nil, fromBuild: nil))
    XCTAssertTrue(state.firstOpenFired)        // marked known so it never re-fires
    XCTAssertNil(state.installAt)              // we don't know the real install date
  }

  // MARK: - Subsequent runs

  func testRelaunchSameVersionIsLaunch() async {
    let defaults = freshDefaults()
    var state = GrowthInstallState(defaults: defaults)
    _ = await state.resolveLaunch(currentVersion: "1.0.0", currentBuild: "10", signal: .fresh, environment: .production, trackBuildChanges: false, now: epoch)
    state = GrowthInstallState(defaults: defaults)
    let launch = await state.resolveLaunch(currentVersion: "1.0.0", currentBuild: "10", signal: .unknown, environment: .production, trackBuildChanges: false, now: epoch)
    XCTAssertEqual(launch, .launch)
  }

  func testFirstOpenFiredWithNoBaselineIsLaunchNotSpuriousUpdate() async {
    // Pre-tracking upgrade / marked pre-existing without a version: `first_open_fired` is
    // set but no version keys exist. The first version we observe must be adopted silently,
    // NOT reported as a version change with fromVersion=nil across the installed base.
    let defaults = freshDefaults()
    defaults.set(true, forKey: GrowthInstallState.Keys.firstOpenFired)
    let state = GrowthInstallState(defaults: defaults)
    let launch = await state.resolveLaunch(currentVersion: "2.0.0", currentBuild: "100", signal: .unknown, environment: .production, trackBuildChanges: false, now: epoch)
    XCTAssertEqual(launch, .launch)

    // The silent launch adopts 2.0.0 as the baseline, so a later real bump fires a
    // correctly-attributed update (proves the baseline was persisted).
    let next = GrowthInstallState(defaults: defaults)
    let bump = await next.resolveLaunch(currentVersion: "3.0.0", currentBuild: "200", signal: .unknown, environment: .production, trackBuildChanges: false, now: epoch)
    XCTAssertEqual(bump, .update(reason: .versionChange, fromVersion: "2.0.0", fromBuild: "100"))
  }

  func testVersionChangeFiresVersionUpdate() async {
    let defaults = freshDefaults()
    var state = GrowthInstallState(defaults: defaults)
    _ = await state.resolveLaunch(currentVersion: "1.0.0", currentBuild: "10", signal: .fresh, environment: .production, trackBuildChanges: false, now: epoch)
    state = GrowthInstallState(defaults: defaults)
    let launch = await state.resolveLaunch(currentVersion: "1.1.0", currentBuild: "11", signal: .unknown, environment: .production, trackBuildChanges: false, now: epoch)
    XCTAssertEqual(launch, .update(reason: .versionChange, fromVersion: "1.0.0", fromBuild: "10"))
  }

  func testNilCurrentAgainstBaselineIsLaunchAndKeepsBaseline() async {
    let defaults = freshDefaults()
    var state = GrowthInstallState(defaults: defaults)
    _ = await state.resolveLaunch(currentVersion: "1.0.0", currentBuild: "10", signal: .fresh, environment: .production, trackBuildChanges: false, now: epoch)
    // Bundle lookup failed this launch (nil version/build): must NOT fabricate an update…
    state = GrowthInstallState(defaults: defaults)
    let launch = await state.resolveLaunch(currentVersion: nil, currentBuild: nil, signal: .unknown, environment: .production, trackBuildChanges: false, now: epoch)
    XCTAssertEqual(launch, .launch)
    // …and the stored baseline must survive so a later real bump is attributed correctly.
    state = GrowthInstallState(defaults: defaults)
    let bump = await state.resolveLaunch(currentVersion: "1.1.0", currentBuild: "11", signal: .unknown, environment: .production, trackBuildChanges: false, now: epoch)
    XCTAssertEqual(bump, .update(reason: .versionChange, fromVersion: "1.0.0", fromBuild: "10"))
  }

  func testRealUpdateDefersBaselineUntilCallerPersists() async {
    let defaults = freshDefaults()
    var state = GrowthInstallState(defaults: defaults)
    _ = await state.resolveLaunch(currentVersion: "1.0.0", currentBuild: "10", signal: .fresh, environment: .production, trackBuildChanges: false, now: epoch)

    // A real update does NOT advance the baseline (so a failed send can retry): resolving the
    // same launch again still reports the update from 1.0.0.
    state = GrowthInstallState(defaults: defaults)
    let first = await state.resolveLaunch(currentVersion: "1.1.0", currentBuild: "11", signal: .unknown, environment: .production, trackBuildChanges: false, now: epoch)
    XCTAssertEqual(first, .update(reason: .versionChange, fromVersion: "1.0.0", fromBuild: "10"))
    state = GrowthInstallState(defaults: defaults)
    let retry = await state.resolveLaunch(currentVersion: "1.1.0", currentBuild: "11", signal: .unknown, environment: .production, trackBuildChanges: false, now: epoch)
    XCTAssertEqual(retry, .update(reason: .versionChange, fromVersion: "1.0.0", fromBuild: "10"))

    // Once the caller persists the baseline (post-send), the next launch is silent.
    await state.persistBaseline("1.1.0", "11")
    state = GrowthInstallState(defaults: defaults)
    let settled = await state.resolveLaunch(currentVersion: "1.1.0", currentBuild: "11", signal: .unknown, environment: .production, trackBuildChanges: false, now: epoch)
    XCTAssertEqual(settled, .launch)
  }

  func testBuildOnlyChangeFiresBuildUpdateInProduction() async {
    let defaults = freshDefaults()
    var state = GrowthInstallState(defaults: defaults)
    _ = await state.resolveLaunch(currentVersion: "1.0.0", currentBuild: "10", signal: .fresh, environment: .production, trackBuildChanges: false, now: epoch)
    state = GrowthInstallState(defaults: defaults)
    let launch = await state.resolveLaunch(currentVersion: "1.0.0", currentBuild: "11", signal: .unknown, environment: .production, trackBuildChanges: false, now: epoch)
    XCTAssertEqual(launch, .update(reason: .buildChange, fromVersion: "1.0.0", fromBuild: "10"))
  }

  func testBuildOnlyChangeSuppressedOutsideProduction() async {
    let defaults = freshDefaults()
    var state = GrowthInstallState(defaults: defaults)
    _ = await state.resolveLaunch(currentVersion: "1.0.0", currentBuild: "10", signal: .fresh, environment: .development, trackBuildChanges: false, now: epoch)
    state = GrowthInstallState(defaults: defaults)
    let launch = await state.resolveLaunch(currentVersion: "1.0.0", currentBuild: "11", signal: .unknown, environment: .development, trackBuildChanges: false, now: epoch)
    XCTAssertEqual(launch, .launch)
  }

  func testBuildOnlyChangeOutsideProductionWithOptIn() async {
    let defaults = freshDefaults()
    var state = GrowthInstallState(defaults: defaults)
    _ = await state.resolveLaunch(currentVersion: "1.0.0", currentBuild: "10", signal: .fresh, environment: .staging, trackBuildChanges: true, now: epoch)
    state = GrowthInstallState(defaults: defaults)
    let launch = await state.resolveLaunch(currentVersion: "1.0.0", currentBuild: "11", signal: .unknown, environment: .staging, trackBuildChanges: true, now: epoch)
    XCTAssertEqual(launch, .update(reason: .buildChange, fromVersion: "1.0.0", fromBuild: "10"))
  }

  // MARK: - Reinstall

  func testReinstallWithWipedStorageCountsAsFreshAgain() async {
    // Delete + reinstall wipes UserDefaults → fresh suite → fresh install again.
    let state = GrowthInstallState(defaults: freshDefaults())
    let launch = await state.resolveLaunch(currentVersion: "1.1.0", currentBuild: "11", signal: .unknown, environment: .production, trackBuildChanges: false, now: epoch)
    XCTAssertEqual(launch, .freshInstall)
    XCTAssertEqual(state.installAt, epoch)
  }

  // MARK: - Manual hook

  func testMarkInstalledBeforeTrackingSuppressesAndPersists() async {
    let defaults = freshDefaults()
    let state = GrowthInstallState(defaults: defaults)
    await state.markInstalledBeforeTracking(currentVersion: "1.0.0", currentBuild: "10")
    XCTAssertTrue(state.firstOpenFired)
    XCTAssertNil(state.installAt)

    // A later run at the same version is a plain launch — no first_open, no update.
    let launch = await state.resolveLaunch(currentVersion: "1.0.0", currentBuild: "10", signal: .unknown, environment: .production, trackBuildChanges: false, now: epoch)
    XCTAssertEqual(launch, .launch)
  }

  func testMarkInstalledBeforeTrackingIsIdempotent() async {
    let defaults = freshDefaults()
    let state = GrowthInstallState(defaults: defaults)
    _ = await state.resolveLaunch(currentVersion: "1.0.0", currentBuild: "10", signal: .fresh, environment: .production, trackBuildChanges: false, now: epoch)
    let installedAt = state.installAt
    await state.markInstalledBeforeTracking(currentVersion: "1.0.0", currentBuild: "10")  // no-op
    XCTAssertEqual(state.installAt, installedAt)
  }

  // MARK: - reset() must not clear install state

  func testResetDoesNotClearInstallState() async throws {
    let defaults = freshDefaults()
    let config = GrowthAnalyticsConfiguration(
      app: "milelog", writeKey: "k",
      endpoint: URL(string: "https://gtmeasy.test")!, environment: .development, userDefaults: defaults
    )
    let state = GrowthInstallState(defaults: defaults)
    _ = await state.resolveLaunch(currentVersion: "1.0.0", currentBuild: "10", signal: .fresh, environment: .production, trackBuildChanges: false, now: epoch)
    XCTAssertTrue(state.firstOpenFired)

    let analytics = GrowthAnalytics(configuration: config, session: MockSession(response: #"{"event":null,"warnings":[]}"#))
    _ = try await analytics.identify(userId: "u1", email: "u1@example.com")
    await analytics.reset()

    XCTAssertTrue(state.firstOpenFired, "logout/reset must never clear install bookkeeping")
    XCTAssertEqual(state.installAt, epoch)
  }

  // MARK: - Version comparison

  func testVersionCompare() {
    XCTAssertEqual(GrowthVersion.compare("1.0", "1.0.0"), .orderedSame)
    XCTAssertEqual(GrowthVersion.compare("1.2.0", "1.10"), .orderedAscending)
    XCTAssertEqual(GrowthVersion.compare("2.0", "1.9"), .orderedDescending)
    XCTAssertEqual(GrowthVersion.compare("100", "99"), .orderedDescending)
    XCTAssertNil(GrowthVersion.compare("1.0", "abc"))
    XCTAssertNil(GrowthVersion.compare("", "1.0"))
  }
}
