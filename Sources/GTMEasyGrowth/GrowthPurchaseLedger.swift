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

  /// First run only: mark every record as completed (and revoked ones as
  /// refunded) without emitting events. Idempotent once `baselined` is set.
  func baseline(with records: [GrowthPurchaseRecord]) async {
    guard !defaults.bool(forKey: Keys.baselined) else { return }
    var completed = loadIds(forKey: Keys.completedIds)
    var refunded = loadIds(forKey: Keys.refundedIds)
    for record in records {
      appendId(record.transactionId, to: &completed)
      if record.revocationDate != nil {
        appendId(record.transactionId, to: &refunded)
      }
    }
    await persist(baselined: true, completed: completed, refunded: refunded)
  }

  /// Diff `records` against the ledger and return actions that still need to be
  /// sent. A record revoked on first sight after baseline yields `.completed`
  /// then `.refunded` so revenue nets out on the server.
  func pending(_ records: [GrowthPurchaseRecord]) -> [GrowthPurchaseAction] {
    let completed = loadIds(forKey: Keys.completedIds)
    let refunded = loadIds(forKey: Keys.refundedIds)
    var actions: [GrowthPurchaseAction] = []

    for record in records {
      let id = record.transactionId
      let completedKey = Self.completedFlightKey(id)
      let refundedKey = Self.refundedFlightKey(id)
      let alreadyCompleted = completed.contains(id) || inFlight.contains(completedKey)
      let alreadyRefunded = refunded.contains(id) || inFlight.contains(refundedKey)

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
    let id: String
    switch action {
    case .completed(let record):
      id = record.transactionId
      inFlight.remove(Self.completedFlightKey(id))
      var completed = loadIds(forKey: Keys.completedIds)
      appendId(id, to: &completed)
      await persist(completed: completed)
    case .refunded(let record):
      id = record.transactionId
      inFlight.remove(Self.refundedFlightKey(id))
      var refunded = loadIds(forKey: Keys.refundedIds)
      appendId(id, to: &refunded)
      await persist(refunded: refunded)
    }
  }

  // MARK: - Persistence

  private func loadIds(forKey key: String) -> [String] {
    defaults.stringArray(forKey: key) ?? []
  }

  private func appendId(_ id: String, to list: inout [String]) {
    if list.contains(id) { return }
    list.append(id)
    if list.count > Self.maxStoredIds {
      list.removeFirst(list.count - Self.maxStoredIds)
    }
  }

  private func persist(
    baselined: Bool? = nil,
    completed: [String]? = nil,
    refunded: [String]? = nil
  ) async {
    let resolvedBaselined = baselined
    let resolvedCompleted = completed
    let resolvedRefunded = refunded
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
    }
  }

  private static func completedFlightKey(_ id: String) -> String { "completed:\(id)" }
  private static func refundedFlightKey(_ id: String) -> String { "refunded:\(id)" }
}
