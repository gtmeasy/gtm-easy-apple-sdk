import Foundation

/// Sends pending purchase actions in order, coordinating with the ledger.
enum GrowthPurchaseActionProcessor {
  static func process(
    actions: [GrowthPurchaseAction],
    isEnabled: @Sendable (GrowthPurchaseRecord) async -> Bool = { _ in true },
    shouldContinue: @Sendable () async -> Bool = { true },
    send: (GrowthPurchaseAction) async throws -> Void,
    ledger: GrowthPurchaseLedger
  ) async {
    var failedCompletedIds: Set<String> = []
    for index in actions.indices {
      let action = actions[index]
      guard await shouldContinue() else {
        for remaining in actions[index...] {
          await ledger.releaseInFlight(remaining)
        }
        return
      }
      if case .refunded(let record) = action, failedCompletedIds.contains(record.transactionId) {
        await ledger.releaseInFlight(action)
        continue
      }
      switch action {
      case .completed(let record):
        if !(await isEnabled(record)) {
          await ledger.markSuppressed(record)
          continue
        }
      case .refunded(let record):
        let saleSuppressed = await ledger.isSuppressed(record)
        if saleSuppressed {
          await ledger.markSent(action)
          continue
        }
        if !(await isEnabled(record)) {
          await ledger.markSent(action)
          continue
        }
      }
      do {
        try await send(action)
        await ledger.markSent(action)
      } catch {
        if case .completed(let record) = action {
          failedCompletedIds.insert(record.transactionId)
        }
        // Not marked sent, so the next sync retries it.
        await ledger.releaseInFlight(action)
      }
    }
  }
}
