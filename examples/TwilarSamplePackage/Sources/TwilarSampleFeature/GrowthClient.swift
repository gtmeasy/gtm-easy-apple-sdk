import Foundation
import GTMEasyGrowth

/// Single-instance Growth client wired up for the Twilar sample.
///
/// In a real host app you'd build this once in your `@main` entry-point and
/// hand it down via `@Environment`. This sample uses a global actor-like
/// accessor for simplicity.
///
/// The endpoint defaults to the LAN staging address used by the GTM Easy
/// monorepo (`http://192.168.3.241:3000`) so the sample is immediately
/// useful from a developer's simulator. Override at compile time by passing
/// `-DGROWTH_ENDPOINT=...` or change the constant for production builds.
public enum GrowthClient {
  /// `app` slug — this is the multi-tenant key the backend uses to scope
  /// events. The sample is wired against the Twilar pilot, but the SDK has
  /// no Twilar-specific code; swap this slug to onboard a different app.
  public static let app = "twilar"

  /// Public write key from `gtmeasy.com → Settings → Write Keys`. The
  /// placeholder below is a dev-stub; replace with a real key before
  /// running the sample against production.
  public static let writeKey = "wk_sample_replace_me"

  /// Production by default — HTTPS so iOS ATS doesn't block the request.
  /// Point at `http://192.168.3.241:3000` (the LAN staging host in
  /// `apps/web/docker-compose.staging.yml`) AND add an
  /// `NSAppTransportSecurity → NSExceptionDomains` entry if you want to
  /// dogfood against staging instead.
  public static let endpoint = URL(string: "https://www.gtmeasy.com")!

  public static let analytics: GrowthAnalytics = {
    let config = GrowthAnalyticsConfiguration(
      app: app,
      writeKey: writeKey,
      endpoint: endpoint,
      environment: .staging,
      debug: true
    )
    return GrowthAnalytics(configuration: config)
  }()

  /// Auto-instrumentation handle. `start()` is the right entry-point for
  /// lifecycle events — it dedupes `app.first_open` via UserDefaults and
  /// emits `app.opened` exactly once on each cold start, so callers shouldn't
  /// fire those events manually.
  public static let autoInstrument: GrowthAutoInstrument = {
    GrowthAutoInstrument(analytics: analytics)
  }()

  /// SKAdNetwork helper — the SDK ships a process-shared actor for this.
  @available(iOS 14.0, *)
  public static var skan: GrowthSKAN { GrowthSKAN.shared }
}
