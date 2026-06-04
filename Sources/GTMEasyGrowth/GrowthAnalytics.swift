import Foundation

#if canImport(AdServices) && os(iOS)
import AdServices
#endif

public struct GrowthAnalyticsConfiguration {
  public enum Environment: String {
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

  public init(
    app: String,
    writeKey: String,
    endpoint: URL = GrowthAnalyticsConfiguration.defaultEndpoint,
    environment: Environment = .production,
    userDefaults: UserDefaults = .standard,
    debug: Bool = false
  ) {
    self.app = app
    self.endpoint = endpoint
    self.writeKey = writeKey
    self.environment = environment
    self.userDefaults = userDefaults
    self.debug = debug
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

public struct GrowthIngestResponse: Decodable, Sendable {
  public let event: GrowthEventRecord?
  public let warnings: [String]?
}

public struct GrowthEventRecord: Decodable, Sendable {
  public let id: String
  public let eventName: String
}

public struct GrowthAttributionResponse: Decodable, Sendable {
  public let event: GrowthEventRecord?
  public let attribution: [String: GrowthJSONValue]?
}

public protocol GrowthHTTPSession: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: GrowthHTTPSession {}

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
  // Identity (userId/username/email) is durable: persisted to UserDefaults so a
  // track() after an app relaunch still attributes to the resolved user, matching
  // DataFast's "re-identify on session change" model.
  private var userId: String?
  private var username: String?
  private var email: String?
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(
    configuration: GrowthAnalyticsConfiguration,
    session: GrowthHTTPSession = URLSession.shared,
    deviceIdentifiers: GrowthDeviceIdentifiers = .shared,
    clickIdStore: GrowthClickIdStore? = nil
  ) {
    self.configuration = configuration
    self.session = session
    self.deviceIdentifiers = deviceIdentifiers
    self.clickIdStore = clickIdStore ?? GrowthClickIdStore(defaults: configuration.userDefaults)
    // Hydrate persisted identity (UserDefaults reads are synchronous).
    self.userId = configuration.userDefaults.string(forKey: StorageKeys.userId)
    self.username = configuration.userDefaults.string(forKey: StorageKeys.username)
    self.email = configuration.userDefaults.string(forKey: StorageKeys.email)
  }

  /// Set the authenticated userId without emitting an identify event. Useful
  /// for app launches where the user is already signed in. Persisted durably.
  public func setUserId(_ id: String?) {
    self.userId = id
    persistIdentity()
  }

  public func getUserId() -> String? { userId }

  public func getUsername() -> String? { username }

  public func getEmail() -> String? { email }

  /// Clear the identified user (logout): forget the persisted userId/username/
  /// email and rotate the anonymous id so post-logout events start a fresh
  /// anonymous stream instead of re-stitching onto the previous user.
  public func reset() {
    userId = nil
    username = nil
    email = nil
    let defaults = configuration.userDefaults
    defaults.removeObject(forKey: StorageKeys.userId)
    defaults.removeObject(forKey: StorageKeys.username)
    defaults.removeObject(forKey: StorageKeys.email)
    defaults.set(UUID().uuidString.lowercased(), forKey: StorageKeys.anonymousId)
  }

  public func getAnonymousId() -> String { anonymousId() }

  /// Record a click id captured from a deep link or universal link. The
  /// store dedupes + persists; subsequent events automatically pick it up.
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
  /// use `reset()` to clear identity entirely. All three are persisted durably.
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
    persistIdentity()

    var enrichedTraits = traits
    enrichedTraits["_ctx"] = .object(await commonContext())

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
      locale: Locale.current.identifier,
      timezone: TimeZone.current.identifier,
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

  private func persistIdentity() {
    let defaults = configuration.userDefaults
    if let userId { defaults.set(userId, forKey: StorageKeys.userId) } else { defaults.removeObject(forKey: StorageKeys.userId) }
    if let username { defaults.set(username, forKey: StorageKeys.username) } else { defaults.removeObject(forKey: StorageKeys.username) }
    if let email { defaults.set(email, forKey: StorageKeys.email) } else { defaults.removeObject(forKey: StorageKeys.email) }
  }

  @discardableResult
  public func track(
    _ eventName: String,
    properties: [String: GrowthJSONValue] = [:],
    metricValue: Double? = nil,
    metricLabel: String? = nil
  ) async throws -> GrowthIngestResponse {
    var enrichedProperties = properties
    enrichedProperties["_ctx"] = .object(await commonContext())

    let body = EventBody(
      app: configuration.app,
      environment: configuration.environment.rawValue,
      userId: userId,
      anonymousId: anonymousId(),
      deviceId: nil,
      eventName: eventName,
      platform: platform,
      appVersion: appVersion,
      buildNumber: buildNumber,
      source: "native",
      country: nil,
      locale: Locale.current.identifier,
      timezone: TimeZone.current.identifier,
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
  /// the first-party device identifier (IDFV) + click ids (fbc/fbp/gclid/
  /// ttclid/etc) so server-side CAPI forwarders can dedupe + match.
  private func commonContext() async -> [String: GrowthJSONValue] {
    var ctx: [String: GrowthJSONValue] = [:]
    let device = await deviceIdentifiers.snapshot()
    for (k, v) in device.asProperties { ctx[k] = v }
    let clicks = await clickIdStore.snapshot()
    for (k, v) in clicks { ctx[k] = v }
    ctx["sdk"] = .string("gtm-easy-swift")
    ctx["sdk_version"] = .string(GrowthAnalytics.sdkVersion)
    return ctx
  }

  public static let sdkVersion = "0.4.1"

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
    // Generate the idempotency key on-device so a transparent retry reuses it
    // and the server dedups, instead of minting a fresh UUID per attempt.
    let resolvedSubmissionId = submissionId ?? UUID().uuidString.lowercased()
    var enrichedProperties = properties
    enrichedProperties["_ctx"] = .object(await commonContext())
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
      locale: Locale.current.identifier,
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
  public func trackFirstOpen() async throws -> GrowthIngestResponse {
    try await track("app.first_open")
  }

  @discardableResult
  public func trackAppOpen() async throws -> GrowthIngestResponse {
    try await track("app.opened")
  }

  @discardableResult
  public func trackPurchaseCompleted(amount: Double, currency: String, productId: String? = nil) async throws -> GrowthIngestResponse {
    var properties: [String: GrowthJSONValue] = ["currency": .string(currency)]
    if let productId {
      properties["productId"] = .string(productId)
    }
    return try await track("purchase.completed", properties: properties, metricValue: amount, metricLabel: currency)
  }

  @discardableResult
  public func collectAppleSearchAdsAttribution() async throws -> GrowthAttributionResponse? {
    #if canImport(AdServices) && os(iOS)
    let token = try AAAttribution.attributionToken()
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
      locale: Locale.current.identifier,
      timezone: TimeZone.current.identifier,
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
    let key = StorageKeys.anonymousId
    if let existing = configuration.userDefaults.string(forKey: key) {
      return existing
    }
    let generated = UUID().uuidString.lowercased()
    configuration.userDefaults.set(generated, forKey: key)
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

public enum GrowthAnalyticsError: Error, Equatable, Sendable {
  case ingestRejected(statusCode: Int, body: String?)
}

private struct EventBody: Encodable {
  let app: String
  let environment: String
  let userId: String?
  let anonymousId: String
  let deviceId: String?
  let eventName: String
  let platform: String
  let appVersion: String?
  let buildNumber: String?
  let source: String
  let country: String?
  let locale: String?
  let timezone: String?
  let attributionProvider: String?
  let attributionId: String?
  let occurredAt: String
  let properties: [String: GrowthJSONValue]
  let metricValue: Double?
  let metricLabel: String?
}

private struct IdentifyBody: Encodable {
  let app: String
  let environment: String
  let userId: String?
  let anonymousId: String
  let deviceId: String?
  let username: String?
  let email: String?
  let platform: String
  let appVersion: String?
  let buildNumber: String?
  let country: String?
  let locale: String?
  let timezone: String?
  let traits: [String: GrowthJSONValue]
}

private struct AppleAttributionBody: Encodable {
  let app: String
  let environment: String
  let userId: String?
  let anonymousId: String
  let deviceId: String?
  let platform: String
  let appVersion: String?
  let buildNumber: String?
  let source: String
  let country: String?
  let locale: String?
  let timezone: String?
  let occurredAt: String
  let properties: [String: GrowthJSONValue]
  let appleAttributionToken: String
}
