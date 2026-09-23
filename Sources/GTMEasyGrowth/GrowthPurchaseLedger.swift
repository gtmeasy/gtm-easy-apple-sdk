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
///
/// State is held in memory and snapshotted to `UserDefaults` after each mutation.
/// Two `GrowthPurchaseLedger` instances on the same `UserDefaults` must not be used
/// concurrently — create a fresh instance after the previous one has finished.
actor GrowthPurchaseLedger {
  private enum Keys {
    static let baselined = "gtm_easy.purchases.baselined"
    static let completedIds = "gtm_easy.purchases.completed_ids"
    static let refundedIds = "gtm_easy.purchases.refunded_ids"
    static let suppressedIds = "gtm_easy.purchases.suppressed_ids"
    static let completedDates = "gtm_easy.purchases.completed_dates"
    static let refundedDates = "gtm_easy.purchases.refunded_dates"
    static let suppressedDates = "gtm_easy.purchases.suppressed_dates"
    static let completedWatermark = "gtm_easy.purchases.completed_watermark"
    static let refundedWatermark = "gtm_easy.purchases.refunded_watermark"
    static let suppressedWatermark = "gtm_easy.purchases.suppressed_watermark"
  }

  private static let maxStoredIds = 500

  private let defaults: UserDefaults
  private var baselined: Bool
  private var completedIds: [String]
  private var refundedIds: [String]
  private var suppressedIds: [String]
  private var completedDates: [String: Double]
  private var refundedDates: [String: Double]
  private var suppressedDates: [String: Double]
  private var completedWatermark: Double?
  private var refundedWatermark: Double?
  private var suppressedWatermark: Double?
  /// In-flight guard: prevents two concurrent `pending` calls from returning the
  /// same action before `markSent` / `markSuppressed` lands.
  private var inFlight: Set<String> = []

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.baselined = defaults.bool(forKey: Keys.baselined)
    self.completedIds = defaults.stringArray(forKey: Keys.completedIds) ?? []
    self.refundedIds = defaults.stringArray(forKey: Keys.refundedIds) ?? []
    self.suppressedIds = defaults.stringArray(forKey: Keys.suppressedIds) ?? []
    self.completedDates = defaults.dictionary(forKey: Keys.completedDates) as? [String: Double] ?? [:]
    self.refundedDates = defaults.dictionary(forKey: Keys.refundedDates) as? [String: Double] ?? [:]
    self.suppressedDates = defaults.dictionary(forKey: Keys.suppressedDates) as? [String: Double] ?? [:]
    self.completedWatermark = Self.loadWatermark(from: defaults, key: Keys.completedWatermark)
    self.refundedWatermark = Self.loadWatermark(from: defaults, key: Keys.refundedWatermark)
    self.suppressedWatermark = Self.loadWatermark(from: defaults, key: Keys.suppressedWatermark)
  }

  var isBaselined: Bool { baselined }

  /// First run only: mark records before `cutoff` as completed (and revoked ones
  /// with `revocationDate < cutoff` as refunded) without emitting events.
  /// Records at/after the cutoff stay pending. Idempotent once `baselined` is set.
  func baseline(with records: [GrowthPurchaseRecord], cutoff: Date = .distantFuture) async {
    guard !baselined else { return }
    for record in records {
      if record.purchaseDate < cutoff {
        appendCompleted(record)
      }
      if let revocationDate = record.revocationDate, revocationDate < cutoff {
        appendRefunded(record)
      }
    }
    baselined = true
    await persistSnapshot()
  }

  /// Diff `records` against the ledger and return actions that still need to be
  /// sent. A record revoked on first sight after baseline yields `.completed`
  /// then `.refunded` so revenue nets out on the server.
  func pending(_ records: [GrowthPurchaseRecord]) -> [GrowthPurchaseAction] {
    var actions: [GrowthPurchaseAction] = []

    for record in records {
      let id = record.transactionId
      let completedKey = Self.completedFlightKey(id)
      let refundedKey = Self.refundedFlightKey(id)
      let purchaseEpoch = record.purchaseDate.timeIntervalSince1970
      let isSuppressed = suppressedIds.contains(id)
        || (suppressedWatermark.map { purchaseEpoch <= $0 } ?? false)
      let alreadyCompleted = completedIds.contains(id)
        || isSuppressed
        || inFlight.contains(completedKey)
        || (completedWatermark.map { purchaseEpoch <= $0 } ?? false)
      let alreadyRefunded = refundedIds.contains(id)
        || inFlight.contains(refundedKey)
        || (record.revocationDate.map { $0.timeIntervalSince1970 <= (refundedWatermark ?? -.infinity) } ?? false)

      if isSuppressed {
        if record.revocationDate != nil, !alreadyRefunded {
          appendRefunded(record)
        }
        continue
      }

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

  /// Record that consent suppressed a completion — treated as completed so it is
  /// never sent as a sale; refunds for suppressed sales are also suppressed.
  /// The sale was suppressed, so its refund must be suppressed too, even when it was queued in the same batch.
  func isSuppressed(_ record: GrowthPurchaseRecord) -> Bool {
    suppressedIds.contains(record.transactionId)
      || (suppressedWatermark.map { record.purchaseDate.timeIntervalSince1970 <= $0 } ?? false)
  }

  func markSuppressed(_ record: GrowthPurchaseRecord) async {
    let id = record.transactionId
    appendSuppressed(record)
    appendCompleted(record)
    inFlight.remove(Self.completedFlightKey(id))
    await persistSnapshot()
  }

  /// Record that an action was successfully sent. Clears the in-flight guard only
  /// after the in-memory state includes the id.
  func markSent(_ action: GrowthPurchaseAction) async {
    switch action {
    case .completed(let record):
      let id = record.transactionId
      appendCompleted(record)
      inFlight.remove(Self.completedFlightKey(id))
    case .refunded(let record):
      let id = record.transactionId
      appendRefunded(record)
      inFlight.remove(Self.refundedFlightKey(id))
    }
    await persistSnapshot()
  }

  // MARK: - In-memory mutations

  private func appendCompleted(_ record: GrowthPurchaseRecord) {
    let id = record.transactionId
    if completedIds.contains(id) { return }
    let epoch = record.purchaseDate.timeIntervalSince1970
    completedIds.append(id)
    completedDates[id] = epoch
    trimIds(
      ids: &completedIds,
      dates: &completedDates,
      watermark: &completedWatermark
    )
  }

  private func appendRefunded(_ record: GrowthPurchaseRecord) {
    guard let revocationDate = record.revocationDate else { return }
    let id = record.transactionId
    if refundedIds.contains(id) { return }
    let epoch = revocationDate.timeIntervalSince1970
    refundedIds.append(id)
    refundedDates[id] = epoch
    trimIds(
      ids: &refundedIds,
      dates: &refundedDates,
      watermark: &refundedWatermark
    )
  }

  private func appendSuppressed(_ record: GrowthPurchaseRecord) {
    let id = record.transactionId
    if suppressedIds.contains(id) { return }
    let epoch = record.purchaseDate.timeIntervalSince1970
    suppressedIds.append(id)
    suppressedDates[id] = epoch
    trimIds(
      ids: &suppressedIds,
      dates: &suppressedDates,
      watermark: &suppressedWatermark
    )
  }

  private func trimIds(
    ids: inout [String],
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

  // MARK: - Persistence

  private static func loadWatermark(from defaults: UserDefaults, key: String) -> Double? {
    let value = defaults.double(forKey: key)
    return value > 0 ? value : nil
  }

  private func persistSnapshot() async {
    let snapshotBaselined = baselined
    let snapshotCompleted = completedIds
    let snapshotRefunded = refundedIds
    let snapshotSuppressed = suppressedIds
    let snapshotCompletedDates = completedDates
    let snapshotRefundedDates = refundedDates
    let snapshotSuppressedDates = suppressedDates
    let snapshotCompletedWatermark = completedWatermark
    let snapshotRefundedWatermark = refundedWatermark
    let snapshotSuppressedWatermark = suppressedWatermark
    await growthPersistOnMainAndWait { [defaults] in
      defaults.set(snapshotBaselined, forKey: Keys.baselined)
      defaults.set(snapshotCompleted, forKey: Keys.completedIds)
      defaults.set(snapshotRefunded, forKey: Keys.refundedIds)
      defaults.set(snapshotSuppressed, forKey: Keys.suppressedIds)
      defaults.set(snapshotCompletedDates, forKey: Keys.completedDates)
      defaults.set(snapshotRefundedDates, forKey: Keys.refundedDates)
      defaults.set(snapshotSuppressedDates, forKey: Keys.suppressedDates)
      if let snapshotCompletedWatermark {
        defaults.set(snapshotCompletedWatermark, forKey: Keys.completedWatermark)
      }
      if let snapshotRefundedWatermark {
        defaults.set(snapshotRefundedWatermark, forKey: Keys.refundedWatermark)
      }
      if let snapshotSuppressedWatermark {
        defaults.set(snapshotSuppressedWatermark, forKey: Keys.suppressedWatermark)
      }
    }
  }

  private static func completedFlightKey(_ id: String) -> String { "completed:\(id)" }
  private static func refundedFlightKey(_ id: String) -> String { "refunded:\(id)" }
}
