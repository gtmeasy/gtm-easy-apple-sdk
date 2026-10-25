import Foundation

#if canImport(AdServices) && os(iOS)
import AdServices
#endif

#if canImport(os)
import os
#endif

public actor GrowthAnalytics {
  private enum StorageKeys {
    static let anonymousId = "gtm_easy_growth_anonymous_id"
    static let userId = "gtm_easy_growth_user_id"
    static let username = "gtm_easy_growth_username"
    static let email = "gtm_easy_growth_email"
  }

  private let configuration: GrowthAnalyticsConfiguration
  private let session: GrowthHTTPSession
  private let deviceIdentifiers: GrowthDeviceIdentifiers
  private let clickIdStore: GrowthClickIdStore
  private let systemContext: GrowthSystemContextProviding
  // Identity (userId/username/email) is durable: persisted to UserDefaults so a
  // track() after an app relaunch still attributes to the resolved user, matching
  // DataFast's "re-identify on session change" model.
  private var userId: String?
  private var username: String?
  private var email: String?
  // The generated anonymous id is persisted on the main thread asynchronously
  // (see growthPersistOnMain), so it is mirrored here to keep every read within a
  // session stable — otherwise two events fired back-to-back at launch could each
  // regenerate a different id before the first write lands.
  private var anonymousIdCache: String?
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  /// The build channel this process runs as: `configuration.buildChannel` when set,
  /// otherwise the offline auto-detected channel (cached per process).
  public nonisolated let resolvedBuildChannel: GrowthBuildChannel
  /// True when `disabled`, or `suppressTestBuilds` and the channel is debug / TestFlight /
  /// internal test. Suppressed instances make no network calls and write no durable SDK
  /// state (identity, anonymous id, click ids, install state, purchase ledger), so a later
  /// production build on the same device still reports its install and purchases.
  public nonisolated let isSuppressed: Bool

  public init(
    configuration: GrowthAnalyticsConfiguration,
    session: GrowthHTTPSession = URLSession.shared,
    deviceIdentifiers: GrowthDeviceIdentifiers = .shared,
    clickIdStore: GrowthClickIdStore? = nil,
    systemContext: GrowthSystemContextProviding = LiveGrowthSystemContextProvider.shared
  ) {
    self.init(
      configuration: configuration,
      session: session,
      deviceIdentifiers: deviceIdentifiers,
      clickIdStore: clickIdStore,
      systemContext: systemContext,
      buildChannelProbes: nil
    )
  }

  /// Test seam: `buildChannelProbes` replaces the cached live detection when non-nil.
  init(
    configuration: GrowthAnalyticsConfiguration,
    session: GrowthHTTPSession = URLSession.shared,
    deviceIdentifiers: GrowthDeviceIdentifiers = .shared,
    clickIdStore: GrowthClickIdStore? = nil,
    systemContext: GrowthSystemContextProviding = LiveGrowthSystemContextProvider.shared,
    buildChannelProbes: GrowthBuildChannelProbes?
  ) {
    // A non-nil override always wins and skips detection entirely.
    let channel = configuration.buildChannel
      ?? buildChannelProbes.map(GrowthBuildChannelDetector.detect)
      ?? GrowthBuildChannelDetector.current
    let suppressed = GrowthBuildChannel.isSuppressed(
      disabled: configuration.disabled,
      suppressTestBuilds: configuration.suppressTestBuilds,
      channel: channel
    )
    self.resolvedBuildChannel = channel
    self.isSuppressed = suppressed
    self.configuration = configuration
    self.session = session
    self.deviceIdentifiers = deviceIdentifiers
    // Suppressed: a memory-only store (still hydrates existing click ids) so captured click
    // ids never reach UserDefaults — even when the host injected a persistent store.
    self.clickIdStore = suppressed
      ? GrowthClickIdStore(defaults: configuration.userDefaults, persistent: false)
      : clickIdStore ?? GrowthClickIdStore(defaults: configuration.userDefaults)
    self.systemContext = systemContext
    // Hydrate persisted identity (UserDefaults reads are synchronous).
    self.userId = configuration.userDefaults.string(forKey: StorageKeys.userId)
    self.username = configuration.userDefaults.string(forKey: StorageKeys.username)
    self.email = configuration.userDefaults.string(forKey: StorageKeys.email)
    if suppressed { Self.logSuppressed(configuration: configuration, channel: channel) }
  }

  /// One line per instance; never includes the write key.
  private static func logSuppressed(configuration: GrowthAnalyticsConfiguration, channel: GrowthBuildChannel) {
    let reason = configuration.disabled ? "disabled" : "channel=\(channel.rawValue)"
    #if canImport(os)
    Logger(subsystem: "com.gtmeasy.growth", category: "GrowthAnalytics")
      .info("GTM Easy: suppressing events (\(reason, privacy: .public))")
    #else
    print("GTM Easy: suppressing events (\(reason))")
    #endif
  }

  /// Set the authenticated userId without emitting an identify event. Useful
  /// for app launches where the user is already signed in. Persisted durably (memory-only
  /// when `isSuppressed`).
  public func setUserId(_ id: String?) async {
    self.userId = id
    await persistIdentity()
  }

  public func getUserId() -> String? { userId }

  public func getUsername() -> String? { username }

  public func getEmail() -> String? { email }

  /// Clear the identified user (logout): forget the persisted userId/username/
  /// email and rotate the anonymous id so post-logout events start a fresh
  /// anonymous stream instead of re-stitching onto the previous user.
  public func reset() async {
    userId = nil
    username = nil
    email = nil
    let rotatedAnonymousId = UUID().uuidString.lowercased()
    anonymousIdCache = rotatedAnonymousId
    guard !isSuppressed else { return }
    let defaults = configuration.userDefaults
    await growthPersistOnMainAndWait {
      defaults.removeObject(forKey: StorageKeys.userId)
      defaults.removeObject(forKey: StorageKeys.username)
      defaults.removeObject(forKey: StorageKeys.email)
      defaults.set(rotatedAnonymousId, forKey: StorageKeys.anonymousId)
    }
  }

  public func getAnonymousId() -> String { anonymousId() }

  /// Record a click id captured from a deep link or universal link. The
  /// store dedupes + persists (memory-only when `isSuppressed`); subsequent events
  /// automatically pick it up.
  public func recordClickId(_ provider: GrowthClickProvider, value: String) async {
    await clickIdStore.record(provider, value: value)
  }

  /// Convenience: extract `fbclid` / `gclid` / `ttclid` / `wbraid` / `gbraid` /
  /// `msclkid` / `twclid` / `igshid` from a URL's query string and persist
  /// them. Returns the count of click ids recorded.
  @discardableResult
  public func captureClickIds(from url: URL) async -> Int {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let items = components.queryItems else { return 0 }
    var count = 0
    let now = Date()
    for item in items {
      guard let value = item.value, !value.isEmpty else { continue }
      switch item.name.lowercased() {
      case "fbclid":
        await clickIdStore.record(.fbclid, value: value, at: now)
        _ = await clickIdStore.ensureFbc(from: value, at: now)
        count += 1
      case "gclid":
        await clickIdStore.record(.gclid, value: value, at: now); count += 1
      case "wbraid":
        await clickIdStore.record(.wbraid, value: value, at: now); count += 1
      case "gbraid":
        await clickIdStore.record(.gbraid, value: value, at: now); count += 1
      case "ttclid":
        await clickIdStore.record(.ttclid, value: value, at: now); count += 1
      case "igshid":
        await clickIdStore.record(.igshid, value: value, at: now); count += 1
      case "msclkid":
        await clickIdStore.record(.msclkid, value: value, at: now); count += 1
      case "twclid":
        await clickIdStore.record(.twclid, value: value, at: now); count += 1
      default:
        break
      }
    }
    return count
  }

  /// Identify the current user. `username` and `email` are first-class (not
  /// smuggled in `traits`). Pass `nil` (the default) to leave a field unchanged;
  /// use `reset()` to clear identity entirely. All three are persisted durably (memory-only
  /// when `isSuppressed`, which also skips the network call).
  @discardableResult
  public func identify(
    userId: String? = nil,
    username: String? = nil,
    email: String? = nil,
    traits: [String: GrowthJSONValue] = [:]
  ) async throws -> GrowthIngestResponse {
    if let userId {
      self.userId = userId
    }
    if let username {
      self.username = Self.normalizeIdentity(username)
    }
    if let email {
      self.email = Self.normalizeIdentity(email)
    }
    if isSuppressed {
      // Identity stays in memory only; mirror traits without collecting `_ctx`.
      await mirrorSuppressed(.identify, label: self.userId ?? self.username ?? self.email ?? "<anonymous>", properties: traits)
      return GrowthIngestResponse(event: nil, warnings: [])
    }
    await persistIdentity()

    var enrichedTraits = traits
    enrichedTraits["_ctx"] = .object(await commonContext())
    let sys = systemContext.current()

    let body = IdentifyBody(
      app: configuration.app,
      environment: configuration.environment.rawValue,
      userId: self.userId,
      anonymousId: anonymousId(),
      deviceId: nil,
      username: self.username,
      email: self.email,
      platform: platform,
      appVersion: appVersion,
      buildNumber: buildNumber,
      country: nil,
      locale: sys.locale,
      timezone: sys.timezone,
      traits: enrichedTraits
    )
    if configuration.debug {
      await GrowthDebugSink.shared.record(.init(kind: .identify, label: self.userId ?? self.username ?? self.email ?? "<anonymous>", properties: enrichedTraits))
    }
    return try await post(body, path: "/api/v1/growth/users")
  }

  /// Trim an identity field; collapse empty / whitespace-only input to nil.
  private static func normalizeIdentity(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func persistIdentity() async {
    guard !isSuppressed else { return }
    let defaults = configuration.userDefaults
    let userId = self.userId, username = self.username, email = self.email
    await growthPersistOnMainAndWait {
      if let userId { defaults.set(userId, forKey: StorageKeys.userId) } else { defaults.removeObject(forKey: StorageKeys.userId) }
      if let username { defaults.set(username, forKey: StorageKeys.username) } else { defaults.removeObject(forKey: StorageKeys.username) }
      if let email { defaults.set(email, forKey: StorageKeys.email) } else { defaults.removeObject(forKey: StorageKeys.email) }
    }
  }

  @discardableResult
  public func track(
    _ eventName: String,
    properties: [String: GrowthJSONValue] = [:],
    metricValue: Double? = nil,
    metricLabel: String? = nil,
    appVersionOverride: String? = nil,
    buildNumberOverride: String? = nil
  ) async throws -> GrowthIngestResponse {
    if isSuppressed {
      await mirrorSuppressed(.track, label: eventName, properties: properties)
      return GrowthIngestResponse(event: nil, warnings: [])
    }
    var enrichedProperties = properties
    enrichedProperties["_ctx"] = .object(await commonContext())
    let sys = systemContext.current()

    let body = EventBody(
      app: configuration.app,
      environment: configuration.environment.rawValue,
      userId: userId,
      anonymousId: anonymousId(),
      deviceId: nil,
      eventName: eventName,
      platform: platform,
      // Lifecycle callers (GrowthAutoInstrument) resolve the version via injectable providers
      // that can differ from `Bundle.main`; honour their resolved value so app.first_open /
      // app.updated land in the right first-class version columns. Falls back to the bundle.
      appVersion: appVersionOverride ?? appVersion,
      buildNumber: buildNumberOverride ?? buildNumber,
      source: "native",
      country: nil,
      locale: sys.locale,
      timezone: sys.timezone,
      attributionProvider: nil,
      attributionId: nil,
      occurredAt: iso8601Now(),
      properties: enrichedProperties,
      metricValue: metricValue,
      metricLabel: metricLabel
    )
    if configuration.debug {
      await GrowthDebugSink.shared.record(.init(kind: .track, label: eventName, properties: enrichedProperties))
    }
    return try await post(body, path: "/api/v1/growth/events")
  }

  /// Common context attached to every event under `properties._ctx`. Includes
  /// the first-party device identifier (IDFV), raw hardware model + OS + RAM,
  /// click ids (fbc/fbp/gclid/ttclid/etc), and device locale/timezone so
  /// server-side CAPI forwarders can dedupe + match and dashboards can
  /// JSONExtract. Marketing device names are mapped server-side from
  /// `_ctx.device_model` (raw `utsname.machine`); clients never ship that table.
  private func commonContext() async -> [String: GrowthJSONValue] {
    var ctx: [String: GrowthJSONValue] = [:]
    let device = await deviceIdentifiers.snapshot()
    for (k, v) in device.asProperties { ctx[k] = v }
    let clicks = await clickIdStore.snapshot()
    for (k, v) in clicks { ctx[k] = v }
    for (k, v) in systemContext.current().asContextProperties { ctx[k] = v }
    ctx["sdk"] = .string("gtm-easy-swift")
    ctx["sdk_version"] = .string(GrowthAnalytics.sdkVersion)
    return ctx
  }

  /// Debug-sink mirror for a suppressed call. Built from the caller's name + properties only:
  /// `commonContext()` is skipped because it can persist synthesized click ids (`fbp`).
  private func mirrorSuppressed(_ kind: GrowthDebugEvent.Kind, label: String, properties: [String: GrowthJSONValue]) async {
    guard configuration.debug else { return }
    var marked = properties
    marked["_suppressed"] = .bool(true)
    await GrowthDebugSink.shared.record(.init(kind: kind, label: label, properties: marked, suppressed: true))
  }

  public static let sdkVersion = "0.11.0"

  /// The configured environment. Read by `GrowthAutoInstrument` so its install probe can
  /// gate StoreKit checks to production.
  public func getEnvironment() -> GrowthAnalyticsConfiguration.Environment { configuration.environment }

  /// Submit a flexible onboarding-survey response. Answers are persisted to the
  /// dedicated survey store (no 240-char truncation) and a
  /// `survey.completed`/`survey.dismissed` lifecycle event is recorded for the
  /// journey timeline + connector fan-out. `partial` submissions store answers
  /// without a lifecycle event. Pass `submissionId` to make retries idempotent
  /// (one is generated client-side when omitted, so a transparent retry reuses
  /// the SAME key). Build answers with the `GrowthSurveyAnswer` factories
  /// (`.singleChoice`, `.rating`, `.nps`, `.text`, …).
  @discardableResult
  public func submitSurvey(
    surveyId: String,
    responses: [GrowthSurveyAnswer],
    surveyName: String? = nil,
    surveyVersion: String? = nil,
    status: GrowthSurveyStatus = .completed,
    submissionId: String? = nil,
    properties: [String: GrowthJSONValue] = [:],
    metadata: [String: GrowthJSONValue] = [:]
  ) async throws -> GrowthSurveyResponse {
    if isSuppressed {
      await mirrorSuppressed(.track, label: "survey:\(surveyId)", properties: ["status": .string(status.rawValue)])
      return GrowthSurveyResponse(submissionId: submissionId ?? UUID().uuidString.lowercased(), accepted: 0, warnings: [])
    }
    // Generate the idempotency key on-device so a transparent retry reuses it
    // and the server dedups, instead of minting a fresh UUID per attempt.
    let resolvedSubmissionId = submissionId ?? UUID().uuidString.lowercased()
    var enrichedProperties = properties
    enrichedProperties["_ctx"] = .object(await commonContext())
    let sys = systemContext.current()
    let body = SurveyBody(
      app: configuration.app,
      environment: configuration.environment.rawValue,
      userId: userId,
      anonymousId: anonymousId(),
      deviceId: nil,
      surveyId: surveyId,
      surveyName: surveyName,
      surveyVersion: surveyVersion,
      submissionId: resolvedSubmissionId,
      status: status.rawValue,
      platform: platform,
      appVersion: appVersion,
      locale: sys.locale,
      occurredAt: iso8601Now(),
      responses: responses,
      properties: enrichedProperties,
      // Submission-level extensibility payload echoed onto every answer row.
      metadata: metadata
    )
    if configuration.debug {
      await GrowthDebugSink.shared.record(.init(kind: .track, label: "survey:\(surveyId)", properties: ["status": .string(status.rawValue)]))
    }
    return try await post(body, path: "/api/v1/growth/surveys")
  }

  @discardableResult
  public func collectAppleSearchAdsAttribution() async throws -> GrowthAttributionResponse? {
    if isSuppressed { return nil }
    #if canImport(AdServices) && os(iOS)
    let token = try AAAttribution.attributionToken()
    let sys = systemContext.current()
    let body = AppleAttributionBody(
      app: configuration.app,
      environment: configuration.environment.rawValue,
      userId: userId,
      anonymousId: anonymousId(),
      deviceId: nil,
      platform: platform,
      appVersion: appVersion,
      buildNumber: buildNumber,
      source: "native",
      country: nil,
      locale: sys.locale,
      timezone: sys.timezone,
      occurredAt: iso8601Now(),
      properties: [:],
      appleAttributionToken: token
    )
    return try await post(body, path: "/api/v1/growth/attribution/apple-search-ads")
    #else
    return nil
    #endif
  }

  private func post<Response: Decodable, Body: Encodable>(_ body: Body, path: String) async throws -> Response {
    var request = URLRequest(url: configuration.endpoint.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue(configuration.writeKey, forHTTPHeaderField: "x-gtm-growth-key")
    request.httpBody = try encoder.encode(body)

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
      throw GrowthAnalyticsError.ingestRejected(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, body: String(data: data, encoding: .utf8))
    }
    return try decoder.decode(Response.self, from: data)
  }

  private func anonymousId() -> String {
    if let anonymousIdCache { return anonymousIdCache }
    let key = StorageKeys.anonymousId
    if let existing = configuration.userDefaults.string(forKey: key) {
      anonymousIdCache = existing
      return existing
    }
    let generated = UUID().uuidString.lowercased()
    anonymousIdCache = generated
    // Suppressed: in-memory only, so a later production build mints and persists its own id.
    guard !isSuppressed else { return generated }
    let defaults = configuration.userDefaults
    growthPersistOnMain { defaults.set(generated, forKey: key) }
    return generated
  }

  private var platform: String {
    #if os(iOS)
    return "ios"
    #elseif os(macOS)
    return "macos"
    #else
    return "web"
    #endif
  }

  private var appVersion: String? {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
  }

  private var buildNumber: String? {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String
  }

  private func iso8601Now() -> String {
    ISO8601DateFormatter().string(from: Date())
  }
}
