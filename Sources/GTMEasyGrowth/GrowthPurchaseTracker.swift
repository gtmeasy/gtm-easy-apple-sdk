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
/// Refunds send a negative `metricValue` so revenue metrics net out. Pass
/// `isEnabled` to gate sends per record — the closure should reflect whether
/// tracking was allowed at the transaction time (and for refunds at revocation
/// time) and is still allowed now. When it returns `false` for a completion, the
/// sale is permanently suppressed and its refund is never sent either. Prefer
/// toggling consent through `isEnabled` over `stop()`/`start()`; use `stop()`
/// only to cancel the `Transaction.updates` listener.
@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
public actor GrowthPurchaseTracker {
  private let analytics: GrowthAnalytics
  private let ledger: GrowthPurchaseLedger
  private let isEnabled: @Sendable (GrowthPurchaseRecord) async -> Bool
  private let startedAt: Date
  private var updatesTask: Task<Void, Never>?
  private var startTask: Task<Void, Never>?
  private var stopped = false

  public init(
    analytics: GrowthAnalytics,
    defaults: UserDefaults = .standard,
    isEnabled: @escaping @Sendable (GrowthPurchaseRecord) async -> Bool = { _ in true }
  ) {
    self.analytics = analytics
    self.ledger = GrowthPurchaseLedger(defaults: defaults)
    self.isEnabled = isEnabled
    self.startedAt = Date()
  }

  public init(
    analytics: GrowthAnalytics,
    defaults: UserDefaults = .standard,
    isEnabled: @escaping @Sendable () async -> Bool
  ) {
    self.init(analytics: analytics, defaults: defaults, isEnabled: { _ in await isEnabled() })
  }

  /// Baselines on first run, starts the `Transaction.updates` listener, then
  /// runs one `sync()`. Overlapping calls share one listener and one baseline.
  public func start() async {
    stopped = false
    if let task = startTask {
      await task.value
      await sync()
      return
    }
    let task = Task { await self.performStart() }
    startTask = task
    await task.value
  }

  /// Cancel the `Transaction.updates` listener. In-flight `start()`/`sync()`
  /// stop sending; `sync()` remains callable after `stop()`.
  public func stop() {
    stopped = true
    updatesTask?.cancel()
    updatesTask = nil
    startTask?.cancel()
    startTask = nil
  }

  /// Diff `Transaction.all` against the ledger and send what is missing. Call on
  /// launch, on foreground, and after any purchase/restore (including purchases
  /// made by another SDK such as RevenueCat).
  public func sync() async {
    let records = await Self.allRecords()
    guard await ensureBaselined(with: records) else { return }
    await processRecords(records)
  }

  /// Report one verified transaction immediately (e.g. the value returned by
  /// `Product.purchase()`). Unverified results are ignored.
  public func track(_ transaction: Transaction) async {
    guard await ensureBaselined(with: await Self.allRecords()) else { return }
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

  /// A host that calls `sync()` or `track(_:)` before `start()` must not report history as new
  /// sales, so the first call baselines instead of sending. Returns `true` when already baselined.
  private func ensureBaselined(with records: [GrowthPurchaseRecord]) async -> Bool {
    if await ledger.isBaselined { return true }
    await ledger.baseline(with: records, cutoff: startedAt)
    return false
  }

  private func performStart() async {
    let records = await Self.allRecords()
    await ledger.baseline(with: records, cutoff: startedAt)
    if updatesTask == nil, !stopped {
      updatesTask = Task { [weak self] in
        for await result in Transaction.updates {
          guard case .verified(let transaction) = result else { continue }
          await self?.processRecords([Self.record(from: transaction)])
        }
      }
    }
    await sync()
  }

  private func shouldContinueProcessing() -> Bool { !stopped }

  private func processRecords(_ records: [GrowthPurchaseRecord]) async {
    guard !stopped else { return }
    let actions = await ledger.pending(records)
    guard !stopped else {
      for action in actions {
        await ledger.releaseInFlight(action)
      }
      return
    }
    await GrowthPurchaseActionProcessor.process(
      actions: actions,
      isEnabled: isEnabled,
      shouldContinue: { await self.shouldContinueProcessing() },
      send: { action in
        switch action {
        case .completed(let record):
          _ = try await analytics.trackPurchaseCompleted(record)
        case .refunded(let record):
          _ = try await analytics.trackPurchaseRefunded(record)
        }
      },
      ledger: ledger
    )
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
