import Foundation

/// Whether the OS believes a build of this app existed on the device *before* the SDK
/// first ran. `unknown` is the safe default: it resolves to a fresh install so a genuine
/// acquisition is never under-counted. A probe should only return `.existed` when it is
/// confident, and `.fresh` when it is confident the install is brand new.
public enum GrowthInstallSignal: Sendable {
  case fresh
  case existed
  case unknown
}

/// Why an `app.updated` event fired. Mirrors the `reason` property the server stores.
public enum GrowthUpdateReason: String, Sendable {
  /// The marketing version (`CFBundleShortVersionString`) changed since the last run.
  case versionChange = "version_change"
  /// Only the build number (`CFBundleVersion`) changed — same marketing version.
  case buildChange = "build_change"
  /// First SDK run on a device that pre-existed install tracking (adoption / upgrade
  /// from a pre-tracking version). Not a real version bump — `is_real_update` is false.
  case preExistingInstall = "pre_existing_install"
}

/// The classification of a single SDK launch, decided exactly once at lifecycle start.
enum GrowthLaunchType: Equatable, Sendable {
  /// Genuine fresh install → fire `app.first_open`.
  case freshInstall
  /// App version/build changed, or a pre-existing install adopted the SDK → fire
  /// `app.updated`. Never an install.
  case update(reason: GrowthUpdateReason, fromVersion: String?, fromBuild: String?)
  /// Normal relaunch with no version change → nothing extra (just `app.opened`).
  case launch
}

/// Owns the durable install/update bookkeeping in `UserDefaults` and the pure decision
/// that turns (persisted state + current version + OS signal) into a `GrowthLaunchType`.
///
/// All persistence goes through an injected `UserDefaults`, so the decision is fully
/// testable with a throwaway suite — no UIKit / StoreKit / Bundle required. Keys are
/// non-PII (app-binary identifiers) and clear on uninstall like the rest of the SDK's
/// local state. `reset()` (logout) deliberately does NOT touch these keys.
struct GrowthInstallState {
  enum Keys {
    static let firstOpenFired = "gtm_easy_growth_first_open_fired"
    static let installAt = "gtm_easy_growth_install_at"
    static let lastAppVersion = "gtm_easy_growth_last_app_version"
    static let lastBuildNumber = "gtm_easy_growth_last_build_number"
  }

  let defaults: UserDefaults

  /// Whether `app.first_open` has already been accounted for on this install.
  var firstOpenFired: Bool { defaults.bool(forKey: Keys.firstOpenFired) }

  /// Timestamp of the first launch we observed for this install.
  var installAt: Date? {
    let ts = defaults.double(forKey: Keys.installAt)
    return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
  }

  /// Read persisted state, classify this launch, and atomically persist the new state
  /// (first-open flag, install timestamp, last seen version/build). `signal` is only
  /// consulted on the first SDK run; pass `.unknown` once `firstOpenFired` is true.
  func resolveLaunch(
    currentVersion: String?,
    currentBuild: String?,
    signal: GrowthInstallSignal,
    environment: GrowthAnalyticsConfiguration.Environment,
    trackBuildChanges: Bool,
    now: Date
  ) -> GrowthLaunchType {
    let alreadyFired = defaults.bool(forKey: Keys.firstOpenFired)
    let lastVersion = defaults.string(forKey: Keys.lastAppVersion)
    let lastBuild = defaults.string(forKey: Keys.lastBuildNumber)

    if alreadyFired {
      // No recorded baseline: an install marked pre-existing without a version, or a
      // pre-tracking install that set `first_open_fired` before version bookkeeping. With
      // nothing to diff against, adopt this launch's version as the baseline silently —
      // never fabricate an `app.updated(versionChange, fromVersion: nil)`.
      if lastVersion == nil, lastBuild == nil { persistBaseline(currentVersion, currentBuild); return .launch }
      // Only a *present* current value that differs is a real change; a nil current carries
      // no information and must not fabricate an app.updated (and must not wipe the baseline).
      let versionChanged = currentVersion != nil && lastVersion != currentVersion
      let buildChanged = currentBuild != nil && lastBuild != currentBuild
      guard versionChanged || buildChanged else { persistBaseline(currentVersion, currentBuild); return .launch }
      let reason: GrowthUpdateReason = versionChanged ? .versionChange : .buildChange
      // Build numbers churn on every CI build; outside production a build-only bump is
      // noise unless explicitly opted in.
      if reason == .buildChange, environment != .production, !trackBuildChanges {
        persistBaseline(currentVersion, currentBuild); return .launch
      }
      // REAL update: do NOT advance the baseline here. The caller persists it via
      // `persistBaseline` only AFTER the `app.updated` event posts, so a transient send
      // failure leaves the old baseline in place and the next launch retries (at-least-once)
      // instead of silently dropping the update.
      return .update(reason: reason, fromVersion: lastVersion, fromBuild: lastBuild)
    }

    // First SDK run on this install.
    defaults.set(true, forKey: Keys.firstOpenFired)
    if signal == .existed {
      // Pre-existing install adopting the SDK: record it, but never count it as an install.
      // No `install_at` — we don't know the real install date. We mark first-open + adopt the
      // baseline BEFORE sending (at-most-once): if this one adoption event fails to send it is
      // lost, which is the safe tradeoff — retrying would re-run the probe and a flaky probe
      // could then misclassify a pre-existing user as a brand-new install.
      persistBaseline(currentVersion, currentBuild)
      return .update(reason: .preExistingInstall, fromVersion: nil, fromBuild: nil)
    }
    // `.fresh` or `.unknown` → treat as a genuine fresh install (never under-count). At-most-once:
    // baseline persisted before send so a failed install is never re-counted.
    defaults.set(now.timeIntervalSince1970, forKey: Keys.installAt)
    persistBaseline(currentVersion, currentBuild)
    return .freshInstall
  }

  /// Advance the stored version/build baseline. Called by `resolveLaunch` for non-real-update
  /// outcomes, and by the lifecycle caller AFTER a real `app.updated` posts (at-least-once).
  /// Only writes present values, so a nil current never erases a good baseline.
  func persistBaseline(_ currentVersion: String?, _ currentBuild: String?) {
    if let currentVersion { defaults.set(currentVersion, forKey: Keys.lastAppVersion) }
    if let currentBuild { defaults.set(currentBuild, forKey: Keys.lastBuildNumber) }
  }

  /// Mark this install as pre-existing without firing `app.first_open`. Idempotent — a
  /// no-op once the first-open flag is set. The deterministic, offline mitigation an
  /// integrator calls in the release that first adds the SDK, for users it already knows
  /// are existing (e.g. signed-in, has local data).
  func markInstalledBeforeTracking(currentVersion: String?, currentBuild: String?) {
    guard !defaults.bool(forKey: Keys.firstOpenFired) else { return }
    defaults.set(true, forKey: Keys.firstOpenFired)
    setOrRemove(Keys.lastAppVersion, currentVersion)
    setOrRemove(Keys.lastBuildNumber, currentBuild)
  }

  private func setOrRemove(_ key: String, _ value: String?) {
    if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
  }
}

/// Component-wise comparison of dotted integer version strings ("1.2.0" < "1.10").
enum GrowthVersion {
  /// Returns the ordering of `a` relative to `b`, or `nil` if either side contains a
  /// non-integer component (callers treat `nil` as "can't tell" → fail safe).
  static func compare(_ a: String, _ b: String) -> ComparisonResult? {
    guard let lhs = parse(a), let rhs = parse(b) else { return nil }
    let count = max(lhs.count, rhs.count)
    for i in 0..<count {
      let x = i < lhs.count ? lhs[i] : 0
      let y = i < rhs.count ? rhs[i] : 0
      if x < y { return .orderedAscending }
      if x > y { return .orderedDescending }
    }
    return .orderedSame
  }

  private static func parse(_ value: String) -> [Int]? {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    var out: [Int] = []
    out.reserveCapacity(parts.count)
    for part in parts {
      guard let n = Int(part) else { return nil }
      out.append(n)
    }
    return out.isEmpty ? nil : out
  }
}
