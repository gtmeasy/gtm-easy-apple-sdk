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

  /// LAN staging in `apps/web/docker-compose.staging.yml`. The simulator
  /// can reach the host machine via its LAN IP; localhost would loop back
  /// to the simulator itself.
  public static let endpoint = URL(string: "http://192.168.3.241:3000")!

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

  /// SKAdNetwork helper — the SDK ships a process-shared actor for this.
  @available(iOS 14.0, *)
  public static var skan: GrowthSKAN { GrowthSKAN.shared }
}
