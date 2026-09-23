import Foundation

public extension GrowthAnalytics {

  /// Emit `purchase.completed` with the full StoreKit 2 property set from a
  /// `GrowthPurchaseRecord`. Prefer this over the legacy `trackPurchaseCompleted(amount:)`
  /// when using `GrowthPurchaseTracker`.
  @discardableResult
  func trackPurchaseCompleted(_ record: GrowthPurchaseRecord) async throws -> GrowthIngestResponse {
    let metricValue = record.price.map { NSDecimalNumber(decimal: $0).doubleValue }
    return try await track(
      "purchase.completed",
      properties: record.completedProperties(),
      metricValue: metricValue,
      metricLabel: record.currency
    )
  }

  /// Emit `purchase.refunded`. Sends a negative `metricValue` so revenue MVs
  /// net out against the original purchase.
  @discardableResult
  func trackPurchaseRefunded(_ record: GrowthPurchaseRecord) async throws -> GrowthIngestResponse {
    let metricValue = record.price.map { -NSDecimalNumber(decimal: $0).doubleValue }
    return try await track(
      "purchase.refunded",
      properties: record.refundedProperties(),
      metricValue: metricValue,
      metricLabel: record.currency
    )
  }
}
