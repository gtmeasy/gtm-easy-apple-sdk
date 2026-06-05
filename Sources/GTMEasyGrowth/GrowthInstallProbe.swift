import Foundation

#if canImport(StoreKit)
import StoreKit
#endif

/// Decides whether the app pre-existed install tracking on this device. Injected into
/// `GrowthAutoInstrument` so the host app can opt into automatic adoption-spike
/// suppression. Implementations MUST be fail-safe: return `.unknown` (→ fresh install)
/// whenever uncertain, and keep latency bounded — the probe runs once at launch.
public protocol GrowthInstallProbe: Sendable {
  /// - Parameter currentVersion: the app's current version expressed in the *same key space*
  ///   that `AppTransaction.originalAppVersion` uses on this platform — the build number
  ///   (`CFBundleVersion`) on iOS/tvOS/watchOS/visionOS and the marketing version
  ///   (`CFBundleShortVersionString`) on macOS. A probe may use it to tell a genuine fresh
  ///   install (`original == current`) from a real upgrade.
  func priorInstallSignal(
    environment: GrowthAnalyticsConfiguration.Environment,
    currentVersion: String?
  ) async -> GrowthInstallSignal
}

/// Default probe: never claims prior knowledge, so `app.first_open` always fires for a
/// fresh SDK run. With this probe the adoption spike is handled by the deterministic
/// `markInstalledBeforeTracking()` hook instead.
public struct NoopInstallProbe: GrowthInstallProbe {
  public init() {}
  public func priorInstallSignal(
    environment: GrowthAnalyticsConfiguration.Environment,
    currentVersion: String?
  ) async -> GrowthInstallSignal {
    .unknown
  }
}

#if canImport(StoreKit)
/// Opt-in StoreKit 2 probe that suppresses the adoption spike automatically.
///
/// Follows Apple's sanctioned "supporting business model changes" pattern: it compares
/// `AppTransaction.originalAppVersion` (the version the customer *first* downloaded)
/// against `firstTrackedAppVersion` (the version in which you first shipped this SDK).
/// If the first download predates the floor, the customer is a pre-existing user and we
/// return `.existed`.
///
/// It is fail-safe by construction — it returns `.existed` ONLY when every condition
/// holds, and `.unknown` (→ fresh install) otherwise:
/// - the SDK environment is `.production` (a fast path that skips StoreKit in dev/QA),
/// - `AppTransaction.shared` resolves `.verified` within the timeout,
/// - the receipt's own `environment` is `.production` — sandbox/TestFlight/Xcode receipts
///   report `originalAppVersion == "1.0"`, so trusting them would skew detection. Gating on
///   the *receipt* environment (rather than a blanket `"1.0"` string check) means genuine
///   production customers whose first version really was `"1.0"` are still detected as
///   pre-existing — the largest adoption cohort, which a `"1.0"` sentinel would have missed,
/// - `originalAppVersion` is strictly less than the version the customer is running now (so a
///   brand-new install on an app that resets its build number per marketing version is never
///   mistaken for an old one), and
/// - `originalAppVersion` parses as a version and is strictly less than the floor.
///
/// > Important: `firstTrackedAppVersion` must be expressed in the key space
/// > `originalAppVersion` reports for the platform — the **build number**
/// > (`CFBundleVersion`) on iOS / tvOS / watchOS / visionOS, and the **marketing
/// > version** (`CFBundleShortVersionString`) on macOS.
///
/// Requires iOS 16+/macOS 13+/tvOS 16+/watchOS 9+; older OSes return `.unknown`.
public struct StoreKitInstallProbe: GrowthInstallProbe {
  public let firstTrackedAppVersion: String
  public let timeoutSeconds: TimeInterval

  public init(firstTrackedAppVersion: String, timeoutSeconds: TimeInterval = 3) {
    self.firstTrackedAppVersion = firstTrackedAppVersion
    self.timeoutSeconds = timeoutSeconds
  }

  public func priorInstallSignal(
    environment: GrowthAnalyticsConfiguration.Environment,
    currentVersion: String?
  ) async -> GrowthInstallSignal {
    guard environment == .production else { return .unknown }
    guard #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) else { return .unknown }

    let info = await Self.originalAppInfo(timeoutSeconds: timeoutSeconds)
    // Trust the receipt ONLY when StoreKit itself confirms a production environment. Sandbox/
    // TestFlight/Xcode receipts all report originalAppVersion "1.0", so a non-production receipt
    // is never trustworthy — but a genuine production "1.0" (the most common original version)
    // IS, so we no longer discard that cohort via a blanket string check.
    guard let info, info.isProduction else { return .unknown }

    // Fail-safe corroboration: only suppress when the customer has DEMONSTRABLY upgraded since
    // first install — i.e. their first version is strictly older than the one they're running
    // now (compared in originalAppVersion's own key space; see `currentVersion`). A genuine
    // fresh install always has `original == current`, so this rejects the case where an app
    // resets its build number per marketing version (common on iOS) and a brand-new low-build
    // install would otherwise sort below the floor and be wrongly suppressed. When `current`
    // is missing or unparseable, fall through to fresh — never under-count a real install.
    if let current = currentVersion {
      guard GrowthVersion.compare(info.version, current) == .orderedAscending else { return .unknown }
    } else {
      return .unknown
    }

    switch GrowthVersion.compare(info.version, firstTrackedAppVersion) {
    case .orderedAscending:
      return .existed                       // first download predates the first SDK version
    case .orderedSame, .orderedDescending, .none:
      return .unknown                       // first download is at/after the floor → fresh
    }
  }

  @available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
  private static func originalAppInfo(timeoutSeconds: TimeInterval) async -> (version: String, isProduction: Bool)? {
    await withTimeoutOrNil(seconds: timeoutSeconds) {
      do {
        let result = try await AppTransaction.shared
        guard case .verified(let transaction) = result else { return nil }
        return (transaction.originalAppVersion, transaction.environment == .production)
      } catch {
        // Offline first call / StoreKit error → can't tell → fresh.
        return nil
      }
    }
  }
}
#endif

/// Race a `Sendable` async operation against a timeout. Returns the operation's value, or
/// `nil` if the operation yielded `nil` or the timeout elapsed first.
///
/// This is a **hard** bound: it returns as soon as either side resolves, WITHOUT awaiting
/// the other. A `withTaskGroup` would implicitly await all child tasks at scope exit, so a
/// `cancelAll()` + `return` could still block on an operation that ignores cancellation —
/// e.g. `AppTransaction.shared` doing a synchronous receipt refresh — defeating the
/// deadline and delaying lifecycle emission. The continuation + single-resume gate lets the
/// abandoned operation finish in the background while the caller proceeds on time.
func withTimeoutOrNil<T: Sendable>(
  seconds: TimeInterval,
  _ operation: @escaping @Sendable () async -> T?
) async -> T? {
  let gate = ResumeGate()
  return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
    Task {
      let value = await operation()
      if await gate.claim() { continuation.resume(returning: value) }
    }
    Task {
      try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
      if await gate.claim() { continuation.resume(returning: nil) }
    }
  }
}

/// Guarantees a `CheckedContinuation` is resumed exactly once across racing tasks — the
/// first caller to `claim()` wins, every later caller is a no-op (so the loser's resume is
/// skipped instead of crashing on a double-resume).
private actor ResumeGate {
  private var claimed = false
  func claim() -> Bool {
    if claimed { return false }
    claimed = true
    return true
  }
}
