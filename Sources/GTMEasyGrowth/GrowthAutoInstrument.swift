import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

/// Fires the right install/lifecycle events with no per-event integration:
/// - `app.first_open` exactly once, only for a genuine fresh install,
/// - `app.updated` when the version/build changes between launches, or when the SDK first
///   runs on a device that pre-existed install tracking (never counted as an install),
/// - `app.opened` on every foreground transition.
///
/// The host app calls `start()` once from
/// `application(_:didFinishLaunchingWithOptions:)` (or `App.init`); everything else is
/// notification-driven. The classification is delegated to `GrowthInstallState`, which
/// reads/writes `UserDefaults`, so updates never re-fire an install.
///
/// To suppress the one-time adoption spike when an app with an existing user base first
/// ships the SDK, either pass a `StoreKitInstallProbe(firstTrackedAppVersion:)` or call
/// `markInstalledBeforeTracking()` for users you already know are existing.
public actor GrowthAutoInstrument {
  private let analytics: GrowthAnalytics
  private let defaults: UserDefaults
  private let installState: GrowthInstallState
  private let probe: GrowthInstallProbe
  private let trackBuildChanges: Bool
  private let now: @Sendable () -> Date
  private let appVersionProvider: @Sendable () -> String?
  private let buildNumberProvider: @Sendable () -> String?
  private var observers: [NSObjectProtocol] = []

  #if os(macOS)
  // macOS posts `didBecomeActive` at launch and on every re-activation (e.g. cmd-tab).
  // `start()` already fires the launch `app.opened`, so we only fire again on a genuine
  // inactive→active transition, tracked here.
  private var isActive = false
  #endif

  public init(
    analytics: GrowthAnalytics,
    defaults: UserDefaults = .standard,
    installProbe: GrowthInstallProbe = NoopInstallProbe(),
    trackBuildChanges: Bool = false,
    now: @escaping @Sendable () -> Date = { Date() },
    appVersion: @escaping @Sendable () -> String? = { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String },
    buildNumber: @escaping @Sendable () -> String? = { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
  ) {
    self.analytics = analytics
    self.defaults = defaults
    self.installState = GrowthInstallState(defaults: defaults)
    self.probe = installProbe
    self.trackBuildChanges = trackBuildChanges
    self.now = now
    self.appVersionProvider = appVersion
    self.buildNumberProvider = buildNumber
  }

  public func start() async {
    let environment = await analytics.getEnvironment()
    // Emit the install/update classification BEFORE `app.opened` so the inaugural event
    // for an install is `app.first_open`, not a bare open.
    await resolveAndFireLaunch(environment: environment)
    await fireAppOpen()
    #if os(macOS)
    isActive = true
    #endif
    observeForegroundTransitions()
  }

  public func stop() {
    for token in observers { NotificationCenter.default.removeObserver(token) }
    observers.removeAll()
  }

  /// Mark this install as pre-existing without firing `app.first_open`. Idempotent.
  /// Call this in the release that first adds the SDK, for users you already know are
  /// existing (signed-in, has local data), to avoid counting them as new installs.
  public func markInstalledBeforeTracking() async {
    await installState.markInstalledBeforeTracking(
      currentVersion: appVersionProvider(),
      currentBuild: buildNumberProvider()
    )
  }

  private func resolveAndFireLaunch(environment: GrowthAnalyticsConfiguration.Environment) async {
    let version = appVersionProvider()
    let build = buildNumberProvider()
    // Pass the current value in `AppTransaction.originalAppVersion`'s key space so the probe can
    // tell a genuine fresh install (original == current) from a real upgrade: macOS reports the
    // marketing version, every other platform reports the build number (CFBundleVersion).
    #if os(macOS)
    let originalKeySpaceCurrent = version
    #else
    let originalKeySpaceCurrent = build
    #endif
    // The OS signal is only relevant on the first SDK run; skip the probe (and any
    // network it may do) once we've already classified this install.
    let signal: GrowthInstallSignal = installState.firstOpenFired
      ? .unknown
      : await probe.priorInstallSignal(environment: environment, currentVersion: originalKeySpaceCurrent)

    let launch = await installState.resolveLaunch(
      currentVersion: version,
      currentBuild: build,
      signal: signal,
      environment: environment,
      trackBuildChanges: trackBuildChanges,
      now: now()
    )

    switch launch {
    case .freshInstall:
      do { _ = try await analytics.trackFirstOpen(appVersion: version, buildNumber: build) } catch { /* never crash the host app */ }
    case let .update(reason, fromVersion, fromBuild):
      do {
        _ = try await analytics.trackAppUpdated(
          fromVersion: fromVersion,
          fromBuild: fromBuild,
          toVersion: version,
          toBuild: build,
          reason: reason,
          isRealUpdate: reason != .preExistingInstall
        )
        // Advance the baseline only after a REAL update posts (at-least-once): if the send
        // above threw, the baseline is untouched so the next launch retries this update.
        // pre-existing already adopted its baseline in resolveLaunch (at-most-once, by design).
        if reason != .preExistingInstall {
          await installState.persistBaseline(version, build)
        }
      } catch { /* swallow — baseline unchanged on failure, so the update retries next launch */ }
    case .launch:
      break
    }
  }

  private func fireAppOpen() async {
    do {
      _ = try await analytics.trackAppOpen()
    } catch {
      // Swallow.
    }
  }

  private func observeForegroundTransitions() {
    #if canImport(UIKit) && os(iOS)
    let token = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      Task { await self.fireAppOpen() }
    }
    observers.append(token)
    #elseif canImport(AppKit) && os(macOS)
    let active = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      Task { await self.fireAppOpenOnReactivation() }
    }
    let resign = NotificationCenter.default.addObserver(
      forName: NSApplication.willResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      Task { await self.markInactive() }
    }
    observers.append(active)
    observers.append(resign)
    #endif
  }

  #if os(macOS)
  private func markInactive() { isActive = false }

  private func fireAppOpenOnReactivation() async {
    // The launch activation arrives while we're already active (set in `start()`), so it
    // is skipped — only inactive→active transitions count as a new open.
    if isActive { return }
    isActive = true
    await fireAppOpen()
  }
  #endif

  /// Timestamp of the first launch we observed for this install. Useful for SKAN
  /// engagement windows and retention math without server roundtrips.
  public var installAt: Date? { installState.installAt }
}
