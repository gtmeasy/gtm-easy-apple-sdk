import Foundation

public struct GrowthAnalyticsConfiguration {
  // Sendable so `GrowthAnalytics.getEnvironment()` can return it across the actor
  // boundary into `GrowthAutoInstrument` / the install probe without a Swift 6
  // strict-concurrency data-race diagnostic. A raw-value enum is trivially Sendable.
  public enum Environment: String, Sendable {
    case production
    case staging
    case development
  }

  /// Production ingest host. Override `endpoint` only when running against a
  /// self-hosted GTM Easy deployment or a local development server.
  public static let defaultEndpoint = URL(string: "https://www.gtmeasy.com")!

  public let app: String
  public let endpoint: URL
  public let writeKey: String
  public let environment: Environment
  public let userDefaults: UserDefaults
  /// When true, every identify/track is mirrored to `GrowthDebugSink.shared`
  /// before the network call and emitted on `GrowthDebugSink.notificationName`.
  public let debug: Bool
  /// When true, all network calls are suppressed and every method returns an
  /// empty noop response. No durable SDK state is written either (install state,
  /// purchase ledger, identity, click ids). Use to disable tracking in development or CI
  /// environments without removing SDK call sites from your code.
  public let disabled: Bool
  /// When true, builds whose resolved `GrowthBuildChannel` is `.debug`, `.testflight` or
  /// `.internalTest` behave exactly like `disabled`: no network, no durable SDK state.
  /// `.unknown` is never suppressed, so a failed detection cannot drop production data.
  public let suppressTestBuilds: Bool
  /// Overrides build-channel auto-detection. `nil` (the default) detects offline once per
  /// process; pass a value when detection can't see the channel (e.g. Mac TestFlight).
  public let buildChannel: GrowthBuildChannel?

  public init(
    app: String,
    writeKey: String,
    endpoint: URL = GrowthAnalyticsConfiguration.defaultEndpoint,
    environment: Environment = .production,
    userDefaults: UserDefaults = .standard,
    debug: Bool = false,
    disabled: Bool = false,
    suppressTestBuilds: Bool = false,
    buildChannel: GrowthBuildChannel? = nil
  ) {
    self.app = app
    self.endpoint = endpoint
    self.writeKey = writeKey
    self.environment = environment
    self.userDefaults = userDefaults
    self.debug = debug
    self.disabled = disabled
    self.suppressTestBuilds = suppressTestBuilds
    self.buildChannel = buildChannel
  }

  /// Source-compatible initializer for pre-default-endpoint call sites that
  /// passed `endpoint` before `writeKey`. New code should use the primary
  /// initializer and omit `endpoint` to pick up the production default.
  @available(*, deprecated, message: "Use init(app:writeKey:endpoint:environment:userDefaults:) — endpoint defaults to https://www.gtmeasy.com")
  public init(
    app: String,
    endpoint: URL,
    writeKey: String,
    environment: Environment = .production,
    userDefaults: UserDefaults = .standard
  ) {
    self.init(app: app, writeKey: writeKey, endpoint: endpoint, environment: environment, userDefaults: userDefaults)
  }
}
