import Foundation

/// Sends pending purchase actions in order, coordinating with the ledger.
enum GrowthPurchaseActionProcessor {
  static func process(
    actions: [GrowthPurchaseAction],
    send: (GrowthPurchaseAction) async throws -> Void,
    ledger: GrowthPurchaseLedger
  ) async {
    var failedCompletedIds: Set<String> = []
    for action in actions {
      if case .refunded(let record) = action, failedCompletedIds.contains(record.transactionId) {
        await ledger.releaseInFlight(action)
        continue
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
