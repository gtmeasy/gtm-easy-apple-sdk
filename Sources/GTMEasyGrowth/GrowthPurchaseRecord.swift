import Foundation

/// A normalized, StoreKit-free snapshot of one App Store transaction. The tracker
/// maps `Transaction` values into this struct so the ledger and analytics helpers
/// stay fully unit-testable without StoreKit.
public struct GrowthPurchaseRecord: Sendable, Equatable {
  public var transactionId: String
  public var originalTransactionId: String
  public var productId: String
  public var productType: String?
  public var environment: String?
  public var price: Decimal?
  public var currency: String?
  public var storefront: String?
  public var appAccountToken: String?
  public var purchaseDate: Date
  public var revocationDate: Date?
  public var isFamilyShared: Bool
  public var offerType: String?
  public var offerId: String?

  public init(
    transactionId: String,
    originalTransactionId: String,
    productId: String,
    productType: String? = nil,
    environment: String? = nil,
    price: Decimal? = nil,
    currency: String? = nil,
    storefront: String? = nil,
    appAccountToken: String? = nil,
    purchaseDate: Date,
    revocationDate: Date? = nil,
    isFamilyShared: Bool = false,
    offerType: String? = nil,
    offerId: String? = nil
  ) {
    self.transactionId = transactionId
    self.originalTransactionId = originalTransactionId
    self.productId = productId
    self.productType = productType
    self.environment = environment
    self.price = price
    self.currency = currency
    self.storefront = storefront
    self.appAccountToken = appAccountToken
    self.purchaseDate = purchaseDate
    self.revocationDate = revocationDate
    self.isFamilyShared = isFamilyShared
    self.offerType = offerType
    self.offerId = offerId
  }

  /// Properties for a `purchase.completed` event. Nil fields are omitted so the
  /// server only sees values StoreKit actually provided.
  public func completedProperties() -> [String: GrowthJSONValue] {
    baseProperties()
  }

  /// Properties for a `purchase.refunded` event.
  public func refundedProperties() -> [String: GrowthJSONValue] {
    baseProperties()
  }

  private func baseProperties() -> [String: GrowthJSONValue] {
    var props: [String: GrowthJSONValue] = [
      "transaction_id": .string(transactionId),
      "original_transaction_id": .string(originalTransactionId),
      "product_id": .string(productId),
      "purchase_date": .string(Self.iso8601UTC(purchaseDate)),
      "family_shared": .bool(isFamilyShared),
      "store": .string("app_store"),
      "source": .string("storekit2"),
    ]
    if let productType { props["product_type"] = .string(productType) }
    if let environment { props["store_environment"] = .string(environment) }
    if let price { props["price"] = .number(NSDecimalNumber(decimal: price).doubleValue) }
    if let currency { props["currency"] = .string(currency) }
    if let storefront { props["storefront"] = .string(storefront) }
    if let appAccountToken { props["app_account_token"] = .string(appAccountToken) }
    if let revocationDate { props["revocation_date"] = .string(Self.iso8601UTC(revocationDate)) }
    if let offerType { props["offer_type"] = .string(offerType) }
    if let offerId { props["offer_id"] = .string(offerId) }
    return props
  }

  private static let utcFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }()

  private static func iso8601UTC(_ date: Date) -> String {
    utcFormatter.string(from: date)
  }
}
