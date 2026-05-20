import Foundation

/// Typed helpers for the paywall + checkout funnel. These wrap `track()`
/// with the canonical event names (matching the server-side whitelist in
/// `apps/web/src/lib/growth-analytics/types.ts`) and required properties so
/// connectors (Meta CAPI / TikTok / Google Ads) get consistent shapes.
public extension GrowthAnalytics {

  /// Paywall surfaced to the user. `placement` is the screen / trigger
  /// (e.g. `onboarding_final`, `feature_gate`, `settings_upgrade`).
  @discardableResult
  func trackPaywallOpened(
    placement: String,
    variant: String? = nil,
    productIds: [String] = [],
    properties: [String: GrowthJSONValue] = [:]
  ) async throws -> GrowthIngestResponse {
    var props = properties
    props["placement"] = .string(placement)
    if let variant { props["variant"] = .string(variant) }
    if !productIds.isEmpty {
      props["product_ids"] = .array(productIds.map { .string($0) })
    }
    return try await track("paywall.opened", properties: props)
  }

  /// User selected a plan but has not initiated the StoreKit transaction yet.
  @discardableResult
  func trackPaywallPlanSelected(
    placement: String,
    productId: String,
    price: Double? = nil,
    currency: String? = nil,
    variant: String? = nil
  ) async throws -> GrowthIngestResponse {
    var props: [String: GrowthJSONValue] = [
      "placement": .string(placement),
      "product_id": .string(productId),
    ]
    if let price { props["price"] = .number(price) }
    if let currency { props["currency"] = .string(currency) }
    if let variant { props["variant"] = .string(variant) }
    return try await track("paywall.plan_selected", properties: props)
  }

  /// `Purchase` button tapped — StoreKit transaction about to start.
  @discardableResult
  func trackPaywallUpgradeClicked(
    placement: String,
    productId: String,
    price: Double? = nil,
    currency: String? = nil
  ) async throws -> GrowthIngestResponse {
    var props: [String: GrowthJSONValue] = [
      "placement": .string(placement),
      "product_id": .string(productId),
    ]
    if let price { props["price"] = .number(price) }
    if let currency { props["currency"] = .string(currency) }
    return try await track("paywall.upgrade_clicked", properties: props)
  }

  /// User cancelled the StoreKit sheet (no purchase).
  @discardableResult
  func trackPaywallUpgradeCancelled(
    placement: String,
    productId: String? = nil,
    reason: String? = nil
  ) async throws -> GrowthIngestResponse {
    var props: [String: GrowthJSONValue] = [
      "placement": .string(placement),
    ]
    if let productId { props["product_id"] = .string(productId) }
    if let reason { props["reason"] = .string(reason) }
    return try await track("paywall.upgrade_cancelled", properties: props)
  }

  /// User dismissed the paywall without engaging. Distinct from
  /// `upgrade_cancelled` (which means they hit the system sheet first).
  @discardableResult
  func trackPaywallClosed(
    placement: String,
    reason: String? = nil
  ) async throws -> GrowthIngestResponse {
    var props: [String: GrowthJSONValue] = [
      "placement": .string(placement),
    ]
    if let reason { props["reason"] = .string(reason) }
    return try await track("paywall.closed", properties: props)
  }

  /// Trial began on-device. Server will replace this with a verified version
  /// once the App Store Server API confirms.
  @discardableResult
  func trackTrialStarted(
    productId: String,
    trialDurationDays: Int? = nil,
    transactionId: String? = nil
  ) async throws -> GrowthIngestResponse {
    var props: [String: GrowthJSONValue] = [
      "product_id": .string(productId),
    ]
    if let trialDurationDays { props["trial_duration_days"] = .number(Double(trialDurationDays)) }
    if let transactionId { props["transaction_id"] = .string(transactionId) }
    return try await track("trial.started", properties: props)
  }

  /// Restore-purchases flow finished (either populated or empty).
  @discardableResult
  func trackRestoreCompleted(restored: Bool, productIds: [String] = []) async throws -> GrowthIngestResponse {
    var props: [String: GrowthJSONValue] = [
      "restored": .bool(restored),
    ]
    if !productIds.isEmpty { props["product_ids"] = .array(productIds.map { .string($0) }) }
    return try await track("paywall.restore_completed", properties: props)
  }
}
