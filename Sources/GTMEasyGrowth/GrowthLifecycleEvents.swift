import Foundation

/// Lifecycle + legacy purchase helpers. Thin wrappers over `track()`, so they inherit its
/// suppression (no network, debug-sink mirror only) when `isSuppressed`.
public extension GrowthAnalytics {
  @discardableResult
  func trackFirstOpen(appVersion: String? = nil, buildNumber: String? = nil) async throws -> GrowthIngestResponse {
    // Forward the install-time version (resolved by the caller) so the install row feeds the
    // per-version breakdown. Defaults to the bundle values when omitted.
    try await track("app.first_open", appVersionOverride: appVersion, buildNumberOverride: buildNumber)
  }

  @discardableResult
  func trackAppOpen() async throws -> GrowthIngestResponse {
    try await track("app.opened")
  }

  /// Record that the app was updated (or that the SDK first ran on a pre-existing
  /// install). This is deliberately NOT an install: the server never counts `app.updated`
  /// in the install funnel, never alerts on it, and never forwards it to an ad platform.
  /// `GrowthAutoInstrument` emits this for you — call it directly only for custom lifecycle
  /// wiring.
  @discardableResult
  func trackAppUpdated(
    fromVersion: String?,
    fromBuild: String?,
    toVersion: String?,
    toBuild: String?,
    reason: GrowthUpdateReason,
    isRealUpdate: Bool
  ) async throws -> GrowthIngestResponse {
    var properties: [String: GrowthJSONValue] = [
      "reason": .string(reason.rawValue),
      "is_real_update": .bool(isRealUpdate),
    ]
    if let fromVersion { properties["from_version"] = .string(fromVersion) }
    if let fromBuild { properties["from_build"] = .string(fromBuild) }
    if let toVersion { properties["to_version"] = .string(toVersion) }
    if let toBuild { properties["to_build"] = .string(toBuild) }
    // Send the landed version as the top-level appVersion/buildNumber so the server's
    // per-version breakdown attributes the update to the version it landed on (not Bundle.main,
    // which can differ when GrowthAutoInstrument uses custom version providers).
    return try await track("app.updated", properties: properties, appVersionOverride: toVersion, buildNumberOverride: toBuild)
  }

  @discardableResult
  func trackPurchaseCompleted(amount: Double, currency: String, productId: String? = nil) async throws -> GrowthIngestResponse {
    var properties: [String: GrowthJSONValue] = ["currency": .string(currency)]
    if let productId {
      properties["productId"] = .string(productId)
    }
    return try await track("purchase.completed", properties: properties, metricValue: amount, metricLabel: currency)
  }
}
