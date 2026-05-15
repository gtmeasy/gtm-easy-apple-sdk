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

  public init(
    app: String,
    writeKey: String,
    endpoint: URL = GrowthAnalyticsConfiguration.defaultEndpoint,
    environment: Environment = .production,
    userDefaults: UserDefaults = .standard
  ) {
    self.app = app
    self.endpoint = endpoint
    self.writeKey = writeKey
    self.environment = environment
    self.userDefaults = userDefaults
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

public struct GrowthIngestResponse: Decodable {
  public let event: GrowthEventRecord?
  public let warnings: [String]?
}

public struct GrowthEventRecord: Decodable {
  public let id: String
  public let eventName: String
}

public struct GrowthAttributionResponse: Decodable {
  public let event: GrowthEventRecord?
  public let attribution: [String: GrowthJSONValue]?
}

public protocol GrowthHTTPSession: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: GrowthHTTPSession {}

public actor GrowthAnalytics {
  private let configuration: GrowthAnalyticsConfiguration
  private let session: GrowthHTTPSession
  private var userId: String?
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(configuration: GrowthAnalyticsConfiguration, session: GrowthHTTPSession = URLSession.shared) {
    self.configuration = configuration
    self.session = session
  }

  @discardableResult
  public func identify(
    userId: String? = nil,
    traits: [String: GrowthJSONValue] = [:]
  ) async throws -> GrowthIngestResponse {
    if let userId {
      self.userId = userId
    }

    let body = IdentifyBody(
      app: configuration.app,
      environment: configuration.environment.rawValue,
      userId: self.userId,
      anonymousId: anonymousId(),
      deviceId: nil,
      platform: platform,
      appVersion: appVersion,
      buildNumber: buildNumber,
      country: nil,
      locale: Locale.current.identifier,
      timezone: TimeZone.current.identifier,
      traits: traits
    )
    return try await post(body, path: "/api/v1/growth/users")
  }

  @discardableResult
  public func track(
    _ eventName: String,
    properties: [String: GrowthJSONValue] = [:],
    metricValue: Double? = nil,
    metricLabel: String? = nil
  ) async throws -> GrowthIngestResponse {
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
      properties: properties,
      metricValue: metricValue,
      metricLabel: metricLabel
    )
    return try await post(body, path: "/api/v1/growth/events")
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
    let key = "gtm_easy_growth_anonymous_id"
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
