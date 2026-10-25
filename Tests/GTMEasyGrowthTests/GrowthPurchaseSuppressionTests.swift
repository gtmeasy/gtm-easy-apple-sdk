import Foundation
import XCTest
@testable import GTMEasyGrowth

#if canImport(StoreKit)
/// A suppressed tracker must not baseline, reserve, mark sent or record consent for any
/// transaction, so the production build still sends each one exactly once.
@available(iOS 15.0, macOS 12.0, *)
final class GrowthPurchaseSuppressionTests: XCTestCase {
  private let okResponse = #"{"event":{"id":"e","eventName":"x"},"warnings":[]}"#

  private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "GrowthPurchaseSuppressionTests-\(UUID().uuidString)")!
  }

  private func analytics(_ defaults: UserDefaults, session: MockSession, suppressed: Bool) -> GrowthAnalytics {
    GrowthAnalytics(
      configuration: GrowthAnalyticsConfiguration(
        app: "milelog", writeKey: "k",
        endpoint: URL(string: "https://gtmeasy.test")!, userDefaults: defaults,
        suppressTestBuilds: true,
        buildChannel: suppressed ? .testflight : .production
      ),
      session: session
    )
  }

  private func tracker(
    _ defaults: UserDefaults,
    session: MockSession,
    suppressed: Bool,
    records: [GrowthPurchaseRecord],
    consentChecks: ConsentCounter? = nil
  ) -> GrowthPurchaseTracker {
    GrowthPurchaseTracker(
      analytics: analytics(defaults, session: session, suppressed: suppressed),
      defaults: defaults,
      isEnabled: { _ in
        await consentChecks?.increment()
        return true
      },
      allRecords: { records }
    )
  }

  /// Purchased after the tracker's start cutoff, so it is pending rather than baselined.
  private func newPurchase(_ id: String) -> GrowthPurchaseRecord {
    GrowthPurchaseRecord(
      transactionId: id, originalTransactionId: id, productId: "pro_yearly",
      price: Decimal(string: "9.99"), currency: "USD",
      purchaseDate: Date().addingTimeInterval(3600)
    )
  }

  /// Every persisted ledger key + value, after any enqueued main-thread write has landed.
  private func ledgerState(_ defaults: UserDefaults) async -> NSDictionary {
    await MainActor.run {}
    return defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("gtm_easy.purchases") } as NSDictionary
  }

  private func sentTransactionIds(_ session: MockSession) async throws -> [String] {
    try await session.requests.map { request in
      let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
      XCTAssertEqual(json?["eventName"] as? String, "purchase.completed")
      let properties = try XCTUnwrap(json?["properties"] as? [String: Any])
      return try XCTUnwrap(properties["transaction_id"] as? String)
    }
  }

  func testSuppressedTrackerNeverBaselinesSoProductionStillSendsOnce() async throws {
    let defaults = freshDefaults()
    let records = [newPurchase("tx-1")]
    let consent = ConsentCounter()

    let suppressedSession = MockSession(response: okResponse)
    let suppressed = tracker(defaults, session: suppressedSession, suppressed: true, records: records, consentChecks: consent)
    await suppressed.start()
    await suppressed.sync()
    await suppressed.stop()
    let suppressedRequests = await suppressedSession.requests
    XCTAssertTrue(suppressedRequests.isEmpty)
    let state = await ledgerState(defaults)
    XCTAssertEqual(state.count, 0)
    let checks = await consent.count
    XCTAssertEqual(checks, 0)

    let session = MockSession(response: okResponse)
    let production = tracker(defaults, session: session, suppressed: false, records: records)
    await production.sync()  // first call baselines (tx-1 is after the cutoff, stays pending)
    await production.sync()
    await production.sync()
    let sent = try await sentTransactionIds(session)
    XCTAssertEqual(sent, ["tx-1"])
  }

  func testSuppressedSyncAfterBaselineLeavesTransactionPendingForProduction() async throws {
    let defaults = freshDefaults()
    // A production run already baselined this device with no history.
    let baselineSession = MockSession(response: okResponse)
    await tracker(defaults, session: baselineSession, suppressed: false, records: []).sync()
    let before = await ledgerState(defaults)
    XCTAssertGreaterThan(before.count, 0)

    let records = [newPurchase("tx-2")]
    let suppressedSession = MockSession(response: okResponse)
    let suppressed = tracker(defaults, session: suppressedSession, suppressed: true, records: records)
    await suppressed.sync()
    let suppressedRequests = await suppressedSession.requests
    XCTAssertTrue(suppressedRequests.isEmpty)
    let after = await ledgerState(defaults)
    XCTAssertEqual(after, before)

    let session = MockSession(response: okResponse)
    let production = tracker(defaults, session: session, suppressed: false, records: records)
    await production.sync()
    await production.sync()
    let sent = try await sentTransactionIds(session)
    XCTAssertEqual(sent, ["tx-2"])
  }
}

actor ConsentCounter {
  private(set) var count = 0
  func increment() { count += 1 }
}
#endif
