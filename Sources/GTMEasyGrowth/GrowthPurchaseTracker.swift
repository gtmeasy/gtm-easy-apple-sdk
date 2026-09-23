import Foundation

#if canImport(StoreKit)
import StoreKit

/// Opt-in StoreKit 2 purchase tracker. Baselines existing transactions on first
/// run (no historical backfill), then sends `purchase.completed` and
/// `purchase.refunded` exactly once per transaction through `GrowthAnalytics`.
///
/// **The host app owns finishing transactions.** This tracker never calls
/// `transaction.finish()` — call it from your purchase flow after entitlement
/// is granted.
///
/// Refunds send a negative `metricValue` so revenue metrics net out. When
/// analytics is disabled (`configuration.disabled`), events are not sent but
/// actions are still marked sent so the ledger does not retry forever.
@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
public actor GrowthPurchaseTracker {
  private let analytics: GrowthAnalytics
  private let ledger: GrowthPurchaseLedger
  private var updatesTask: Task<Void, Never>?
  private var started = false

  public init(analytics: GrowthAnalytics, defaults: UserDefaults = .standard) {
    self.analytics = analytics
    self.ledger = GrowthPurchaseLedger(defaults: defaults)
  }

  /// Baselines on first run, starts the `Transaction.updates` listener, then
  /// runs one `sync()`. Idempotent — calling twice does not start two listeners.
  public func start() async {
    guard !started else {
      await sync()
      return
    }
    started = true
    let records = await Self.allRecords()
    await ledger.baseline(with: records)
    updatesTask = Task { [weak self] in
      for await result in Transaction.updates {
        guard case .verified(let transaction) = result else { continue }
        await self?.processRecords([Self.record(from: transaction)])
      }
    }
    await sync()
  }

  /// Cancel the `Transaction.updates` listener. `sync()` remains callable.
  public func stop() {
    updatesTask?.cancel()
    updatesTask = nil
    started = false
  }

  /// Diff `Transaction.all` against the ledger and send what is missing. Call on
  /// launch, on foreground, and after any purchase/restore (including purchases
  /// made by another SDK such as RevenueCat).
  public func sync() async {
    let records = await Self.allRecords()
    await processRecords(records)
  }

  /// Report one verified transaction immediately (e.g. the value returned by
  /// `Product.purchase()`). Unverified results are ignored.
  public func track(_ transaction: Transaction) async {
    await processRecords([Self.record(from: transaction)])
  }

  /// Convenience for `Product.PurchaseResult`: tracks `.success(.verified)`,
  /// ignores pending, user-cancelled, and unverified outcomes.
  public func track(_ result: Product.PurchaseResult) async {
    switch result {
    case .success(.verified(let transaction)):
      await track(transaction)
    case .success(.unverified), .pending, .userCancelled:
      break
    @unknown default:
      break
    }
  }

  // MARK: - Internal

  private func processRecords(_ records: [GrowthPurchaseRecord]) async {
    let actions = await ledger.pending(records)
    for action in actions {
      do {
        switch action {
        case .completed(let record):
          _ = try await analytics.trackPurchaseCompleted(record)
        case .refunded(let record):
          _ = try await analytics.trackPurchaseRefunded(record)
        }
        // Mark sent even when analytics is disabled (noop response) so we do
        // not retry the same transaction on every sync.
        await ledger.markSent(action)
      } catch {
        // Network failure — leave in-flight cleared only for un-sent actions.
        // `markSent` was not called, so the in-flight guard is still held and
        // the next `pending` will not double-send; however we must release
        // in-flight for retry. Re-queue by not having called markSent — but
        // inFlight blocks retry. Fix: on failure, release in-flight.
        await ledger.releaseInFlight(action)
      }
    }
  }

  // MARK: - StoreKit mapping

  private static func allRecords() async -> [GrowthPurchaseRecord] {
    var records: [GrowthPurchaseRecord] = []
    for await result in Transaction.all {
      guard case .verified(let transaction) = result else { continue }
      records.append(record(from: transaction))
    }
    return records
  }

  static func record(from transaction: Transaction) -> GrowthPurchaseRecord {
    GrowthPurchaseRecord(
      transactionId: String(transaction.id),
      originalTransactionId: String(transaction.originalID),
      productId: transaction.productID,
      productType: productTypeString(transaction.productType),
      environment: environmentString(transaction),
      price: transaction.price,
      currency: currencyString(transaction),
      storefront: storefrontString(transaction),
      appAccountToken: transaction.appAccountToken?.uuidString.lowercased(),
      purchaseDate: transaction.purchaseDate,
      revocationDate: transaction.revocationDate,
      isFamilyShared: transaction.ownershipType == .familyShared,
      offerType: offerTypeString(transaction),
      offerId: offerIdString(transaction)
    )
  }

  private static func productTypeString(_ type: Product.ProductType) -> String {
    switch type {
    case .nonConsumable: return "non_consumable"
    case .consumable: return "consumable"
    case .autoRenewable: return "auto_renewable"
    case .nonRenewable: return "non_renewing"
    default: return String(describing: type)
    }
  }

  private static func environmentString(_ transaction: Transaction) -> String? {
    if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
      switch transaction.environment {
      case .production: return "production"
      case .sandbox: return "sandbox"
      case .xcode: return "xcode"
      default: return nil
      }
    }
    return nil
  }

  private static func currencyString(_ transaction: Transaction) -> String? {
    if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
      return transaction.currency?.identifier.uppercased()
    }
    return nil
  }

  private static func storefrontString(_ transaction: Transaction) -> String? {
    if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
      return transaction.storefront.countryCode
    }
    if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
      return transaction.storefrontCountryCode
    }
    return nil
  }

  private static func offerTypeString(_ transaction: Transaction) -> String? {
    if #available(iOS 17.2, macOS 14.2, tvOS 17.2, watchOS 10.2, *) {
      guard let offer = transaction.offer else { return nil }
      switch offer.type {
      case .introductory: return "introductory"
      case .promotional: return "promotional"
      case .winBack: return "win_back"
      case .code: return "code"
      default: return String(describing: offer.type)
      }
    }
    switch transaction.offerType {
    case .introductory: return "introductory"
    case .promotional: return "promotional"
    case .none: return nil
    default: return String(describing: transaction.offerType)
    }
  }

  private static func offerIdString(_ transaction: Transaction) -> String? {
    if #available(iOS 17.2, macOS 14.2, tvOS 17.2, watchOS 10.2, *) {
      return transaction.offer?.id
    }
    return transaction.offerID
  }
}
#endif
