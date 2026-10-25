import Foundation

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

public enum GrowthAnalyticsError: Error, Equatable, Sendable {
  case ingestRejected(statusCode: Int, body: String?)
}

// Request bodies POSTed by `GrowthAnalytics`. Internal so the actor file stays focused on
// behaviour; never part of the public API.

struct EventBody: Encodable {
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

struct IdentifyBody: Encodable {
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

struct AppleAttributionBody: Encodable {
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
