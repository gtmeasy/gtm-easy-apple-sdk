import Foundation

/// What the tracker should send for one transaction.
public enum GrowthPurchaseAction: Equatable, Sendable {
  case completed(GrowthPurchaseRecord)
  case refunded(GrowthPurchaseRecord)
}

/// Durable, once-per-transaction bookkeeping for StoreKit purchase events.
///
/// On first run the tracker calls `baseline(with:)` to mark every existing
/// transaction as already seen — no historical backfill. Subsequent `pending`
/// calls diff new transactions against the ledger. `markSent` is called only
/// after a successful `track`, so a network failure retries on the next sync.
actor GrowthPurchaseLedger {
  private enum Keys {
    static let baselined = "gtm_easy.purchases.baselined"
    static let completedIds = "gtm_easy.purchases.completed_ids"
    static let refundedIds = "gtm_easy.purchases.refunded_ids"
    static let completedDates = "gtm_easy.purchases.completed_dates"
    static let refundedDates = "gtm_easy.purchases.refunded_dates"
    static let completedWatermark = "gtm_easy.purchases.completed_watermark"
    static let refundedWatermark = "gtm_easy.purchases.refunded_watermark"
  }

  private static let maxStoredIds = 500

  private let defaults: UserDefaults
  /// In-flight guard: prevents two concurrent `pending` calls from returning the
  /// same action before `markSent` lands.
  private var inFlight: Set<String> = []

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var isBaselined: Bool {
    defaults.bool(forKey: Keys.baselined)
  }

  /// First run only: mark records before `cutoff` as completed (and revoked ones
  /// with `revocationDate < cutoff` as refunded) without emitting events.
  /// Records at/after the cutoff stay pending. Idempotent once `baselined` is set.
  func baseline(with records: [GrowthPurchaseRecord], cutoff: Date = .distantFuture) async {
    guard !defaults.bool(forKey: Keys.baselined) else { return }
    var completed = loadIds(forKey: Keys.completedIds)
    var refunded = loadIds(forKey: Keys.refundedIds)
    var completedDates = loadDates(forKey: Keys.completedDates)
    var refundedDates = loadDates(forKey: Keys.refundedDates)
    var completedWatermark = loadWatermark(forKey: Keys.completedWatermark)
    var refundedWatermark = loadWatermark(forKey: Keys.refundedWatermark)
    for record in records {
      if record.purchaseDate < cutoff {
        appendCompleted(
          record,
          ids: &completed,
          dates: &completedDates,
          watermark: &completedWatermark
        )
      }
      if let revocationDate = record.revocationDate, revocationDate < cutoff {
        appendRefunded(
          record,
          ids: &refunded,
          dates: &refundedDates,
          watermark: &refundedWatermark
        )
      }
    }
    await persist(
      baselined: true,
      completed: completed,
      refunded: refunded,
      completedDates: completedDates,
      refundedDates: refundedDates,
      completedWatermark: completedWatermark,
      refundedWatermark: refundedWatermark
    )
  }

  /// Diff `records` against the ledger and return actions that still need to be
  /// sent. A record revoked on first sight after baseline yields `.completed`
  /// then `.refunded` so revenue nets out on the server.
  func pending(_ records: [GrowthPurchaseRecord]) -> [GrowthPurchaseAction] {
    let completed = loadIds(forKey: Keys.completedIds)
    let refunded = loadIds(forKey: Keys.refundedIds)
    let completedWatermark = loadWatermark(forKey: Keys.completedWatermark)
    let refundedWatermark = loadWatermark(forKey: Keys.refundedWatermark)
    var actions: [GrowthPurchaseAction] = []

    for record in records {
      let id = record.transactionId
      let completedKey = Self.completedFlightKey(id)
      let refundedKey = Self.refundedFlightKey(id)
      let purchaseEpoch = record.purchaseDate.timeIntervalSince1970
      let alreadyCompleted = completed.contains(id)
        || inFlight.contains(completedKey)
        || (completedWatermark.map { purchaseEpoch <= $0 } ?? false)
      let alreadyRefunded = refunded.contains(id)
        || inFlight.contains(refundedKey)
        || (record.revocationDate.map { $0.timeIntervalSince1970 <= (refundedWatermark ?? -.infinity) } ?? false)

      if !alreadyCompleted {
        actions.append(.completed(record))
        inFlight.insert(completedKey)
        if record.revocationDate != nil, !alreadyRefunded {
          actions.append(.refunded(record))
          inFlight.insert(refundedKey)
        }
      } else if record.revocationDate != nil, !alreadyRefunded {
        actions.append(.refunded(record))
        inFlight.insert(refundedKey)
      }
    }
    return actions
  }

  /// Release an in-flight guard after a failed send so the next sync can retry.
  func releaseInFlight(_ action: GrowthPurchaseAction) {
    switch action {
    case .completed(let record):
      inFlight.remove(Self.completedFlightKey(record.transactionId))
    case .refunded(let record):
      inFlight.remove(Self.refundedFlightKey(record.transactionId))
    }
  }

  /// Record that an action was successfully sent (or intentionally skipped when
  /// analytics is disabled — see tracker docs). Clears the in-flight guard.
  func markSent(_ action: GrowthPurchaseAction) async {
    switch action {
    case .completed(let record):
      let id = record.transactionId
      inFlight.remove(Self.completedFlightKey(id))
      var completed = loadIds(forKey: Keys.completedIds)
      var completedDates = loadDates(forKey: Keys.completedDates)
      var completedWatermark = loadWatermark(forKey: Keys.completedWatermark)
      appendCompleted(
        record,
        ids: &completed,
        dates: &completedDates,
        watermark: &completedWatermark
      )
      await persist(
        completed: completed,
        completedDates: completedDates,
        completedWatermark: completedWatermark
      )
    case .refunded(let record):
      let id = record.transactionId
      inFlight.remove(Self.refundedFlightKey(id))
      var refunded = loadIds(forKey: Keys.refundedIds)
      var refundedDates = loadDates(forKey: Keys.refundedDates)
      var refundedWatermark = loadWatermark(forKey: Keys.refundedWatermark)
      appendRefunded(
        record,
        ids: &refunded,
        dates: &refundedDates,
        watermark: &refundedWatermark
      )
      await persist(
        refunded: refunded,
        refundedDates: refundedDates,
        refundedWatermark: refundedWatermark
      )
    }
  }

  // MARK: - Persistence

  private func loadIds(forKey key: String) -> [String] {
    defaults.stringArray(forKey: key) ?? []
  }

  private func loadDates(forKey key: String) -> [String: Double] {
    defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
  }

  private func loadWatermark(forKey key: String) -> Double? {
    let value = defaults.double(forKey: key)
    return value > 0 ? value : nil
  }

  private func appendCompleted(
    _ record: GrowthPurchaseRecord,
    ids: inout [String],
    dates: inout [String: Double],
    watermark: inout Double?
  ) {
    let id = record.transactionId
    if ids.contains(id) { return }
    let epoch = record.purchaseDate.timeIntervalSince1970
    ids.append(id)
    dates[id] = epoch
    trimIds(&ids, dates: &dates, watermark: &watermark)
  }

  private func appendRefunded(
    _ record: GrowthPurchaseRecord,
    ids: inout [String],
    dates: inout [String: Double],
    watermark: inout Double?
  ) {
    guard let revocationDate = record.revocationDate else { return }
    let id = record.transactionId
    if ids.contains(id) { return }
    let epoch = revocationDate.timeIntervalSince1970
    ids.append(id)
    dates[id] = epoch
    trimIds(&ids, dates: &dates, watermark: &watermark)
  }

  private func trimIds(
    _ ids: inout [String],
    dates: inout [String: Double],
    watermark: inout Double?
  ) {
    guard ids.count > Self.maxStoredIds else { return }
    let trimCount = ids.count - Self.maxStoredIds
    // Drop the oldest dates, not the oldest inserts: `Transaction.all` is unordered, and the
    // watermark must never pass a transaction that is still unsent.
    ids.sort { (dates[$0] ?? 0) < (dates[$1] ?? 0) }
    for trimmedId in ids.prefix(trimCount) {
      if let trimmedEpoch = dates.removeValue(forKey: trimmedId) {
        watermark = max(watermark ?? trimmedEpoch, trimmedEpoch)
      }
    }
    ids.removeFirst(trimCount)
  }

  private func persist(
    baselined: Bool? = nil,
    completed: [String]? = nil,
    refunded: [String]? = nil,
    completedDates: [String: Double]? = nil,
    refundedDates: [String: Double]? = nil,
    completedWatermark: Double? = nil,
    refundedWatermark: Double? = nil
  ) async {
    let resolvedBaselined = baselined
    let resolvedCompleted = completed
    let resolvedRefunded = refunded
    let resolvedCompletedDates = completedDates
    let resolvedRefundedDates = refundedDates
    let resolvedCompletedWatermark = completedWatermark
    let resolvedRefundedWatermark = refundedWatermark
    await growthPersistOnMainAndWait { [defaults] in
      if let resolvedBaselined {
        defaults.set(resolvedBaselined, forKey: Keys.baselined)
      }
      if let resolvedCompleted {
        defaults.set(resolvedCompleted, forKey: Keys.completedIds)
      }
      if let resolvedRefunded {
        defaults.set(resolvedRefunded, forKey: Keys.refundedIds)
      }
      if let resolvedCompletedDates {
        defaults.set(resolvedCompletedDates, forKey: Keys.completedDates)
      }
      if let resolvedRefundedDates {
        defaults.set(resolvedRefundedDates, forKey: Keys.refundedDates)
      }
      if let resolvedCompletedWatermark {
        defaults.set(resolvedCompletedWatermark, forKey: Keys.completedWatermark)
      }
      if let resolvedRefundedWatermark {
        defaults.set(resolvedRefundedWatermark, forKey: Keys.refundedWatermark)
      }
    }
  }

  private static func completedFlightKey(_ id: String) -> String { "completed:\(id)" }
  private static func refundedFlightKey(_ id: String) -> String { "refunded:\(id)" }
}
