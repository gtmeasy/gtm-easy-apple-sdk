import Foundation
import XCTest
@testable import GTMEasyGrowth

final class GrowthPurchaseLedgerTests: XCTestCase {
  private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "GrowthPurchaseLedgerTests-\(UUID().uuidString)")!
  }

  private let purchaseDate = Date(timeIntervalSince1970: 1_700_000_000)
  private let revocationDate = Date(timeIntervalSince1970: 1_700_100_000)

  private func record(
    id: String = "tx-1",
    revoked: Bool = false,
    productId: String = "pro_yearly",
    purchaseDate: Date? = nil,
    revocationDate: Date? = nil
  ) -> GrowthPurchaseRecord {
    let resolvedPurchase = purchaseDate ?? self.purchaseDate
    let resolvedRevocation = revoked ? (revocationDate ?? self.revocationDate) : nil
    return GrowthPurchaseRecord(
      transactionId: id,
      originalTransactionId: "orig-\(id)",
      productId: productId,
      productType: "auto_renewable",
      environment: "production",
      price: Decimal(string: "9.99"),
      currency: "USD",
      storefront: "USA",
      purchaseDate: resolvedPurchase,
      revocationDate: resolvedRevocation
    )
  }

  // MARK: - Baseline

  func testFirstRunBaselineSendsNothing() async {
    let ledger = GrowthPurchaseLedger(defaults: freshDefaults())
    await ledger.baseline(with: [record(), record(id: "tx-2")])
    let pending = await ledger.pending([record(), record(id: "tx-2")])
    let baselined = await ledger.isBaselined
    XCTAssertTrue(pending.isEmpty)
    XCTAssertTrue(baselined)
  }

  func testLaterSyncWithSameRecordsSendsNothing() async {
    let defaults = freshDefaults()
    let ledger = GrowthPurchaseLedger(defaults: defaults)
    let records = [record(), record(id: "tx-2")]
    await ledger.baseline(with: records)
    let ledger2 = GrowthPurchaseLedger(defaults: defaults)
    let pending = await ledger2.pending(records)
    XCTAssertTrue(pending.isEmpty)
  }

  // MARK: - Completed

  func testNewRecordAfterBaselineSendsCompleted() async {
    let defaults = freshDefaults()
    let ledger = GrowthPurchaseLedger(defaults: defaults)
    await ledger.baseline(with: [])
    let pending = await ledger.pending([record()])
    XCTAssertEqual(pending, [.completed(record())])
  }

  func testAfterMarkSentCompletedSendsNothing() async {
    let defaults = freshDefaults()
    let ledger = GrowthPurchaseLedger(defaults: defaults)
    await ledger.baseline(with: [])
    let action = GrowthPurchaseAction.completed(record())
    let pending1 = await ledger.pending([record()])
    XCTAssertEqual(pending1.count, 1)
    await ledger.markSent(action)
    let pending2 = await ledger.pending([record()])
    XCTAssertTrue(pending2.isEmpty)
  }

  // MARK: - Refunded

  func testRecordRevokedLaterSendsRefunded() async {
    let defaults = freshDefaults()
    let ledger = GrowthPurchaseLedger(defaults: defaults)
    await ledger.baseline(with: [])
    let completed = GrowthPurchaseAction.completed(record())
    _ = await ledger.pending([record()])
    await ledger.markSent(completed)

    let revoked = record(revoked: true)
    let pending = await ledger.pending([revoked])
    XCTAssertEqual(pending, [.refunded(revoked)])
  }

  func testRepeatedRefundSendsNothing() async {
    let defaults = freshDefaults()
    let ledger = GrowthPurchaseLedger(defaults: defaults)
    await ledger.baseline(with: [])
    _ = await ledger.pending([record(revoked: true)])
    await ledger.markSent(.completed(record(revoked: true)))
    await ledger.markSent(.refunded(record(revoked: true)))
    let pending = await ledger.pending([record(revoked: true)])
    XCTAssertTrue(pending.isEmpty)
  }

  func testRevokedOnFirstSightSendsCompletedThenRefunded() async {
    let defaults = freshDefaults()
    let ledger = GrowthPurchaseLedger(defaults: defaults)
    await ledger.baseline(with: [])
    let revoked = record(revoked: true)
    let pending = await ledger.pending([revoked])
    XCTAssertEqual(pending, [.completed(revoked), .refunded(revoked)])
  }

  // MARK: - Retry

  func testNotMarkedSentReturnsAgainAfterRelease() async {
    let defaults = freshDefaults()
    let ledger = GrowthPurchaseLedger(defaults: defaults)
    await ledger.baseline(with: [])
    let action = GrowthPurchaseAction.completed(record())
    _ = await ledger.pending([record()])
    await ledger.releaseInFlight(action)
    let pending = await ledger.pending([record()])
    XCTAssertEqual(pending, [action])
  }

  // MARK: - Concurrency

  func testConcurrentPendingNeverReturnsSameIdTwice() async {
    let defaults = freshDefaults()
    let ledger = GrowthPurchaseLedger(defaults: defaults)
    await ledger.baseline(with: [])
    let rec = record()

    let results = await withTaskGroup(of: [GrowthPurchaseAction].self) { group in
      for _ in 0..<10 {
        group.addTask { await ledger.pending([rec]) }
      }
      var all: [GrowthPurchaseAction] = []
      for await batch in group { all.append(contentsOf: batch) }
      return all
    }

    let completedIds = results.compactMap { action -> String? in
      if case .completed(let r) = action { return r.transactionId }
      return nil
    }
    XCTAssertEqual(Set(completedIds).count, completedIds.count)
    XCTAssertEqual(completedIds.count, 1)
  }

  // MARK: - Cap trimming + watermarks

  func testBaseline600RecordsNonePending() async {
    let defaults = freshDefaults()
    let ledger = GrowthPurchaseLedger(defaults: defaults)
    let records = (0..<600).map { i in
      record(id: "tx-\(i)", purchaseDate: Date(timeIntervalSince1970: Double(i)))
    }
    await ledger.baseline(with: records)
    let pending = await ledger.pending(records)
    XCTAssertTrue(pending.isEmpty)
  }

  func testTrimDuringMarkSentTrimmedRecordNotReturnedAgain() async {
    let defaults = freshDefaults()
    let ledger = GrowthPurchaseLedger(defaults: defaults)
    await ledger.baseline(with: [])

    for i in 0..<510 {
      let rec = record(id: "tx-\(i)", purchaseDate: Date(timeIntervalSince1970: Double(i)))
      let action = GrowthPurchaseAction.completed(rec)
      _ = await ledger.pending([rec])
      await ledger.markSent(action)
    }

    let trimmed = record(id: "tx-0", purchaseDate: Date(timeIntervalSince1970: 0))
    let pending = await ledger.pending([trimmed])
    XCTAssertTrue(pending.isEmpty)
  }

  // MARK: - Processor ordering

  func testCompletedFailureSkipsRefundInSameBatch() async {
    let defaults = freshDefaults()
    let ledger = GrowthPurchaseLedger(defaults: defaults)
    await ledger.baseline(with: [])
    let revoked = record(revoked: true)
    let actions = await ledger.pending([revoked])
    XCTAssertEqual(actions.count, 2)

    var sent: [GrowthPurchaseAction] = []
    await GrowthPurchaseActionProcessor.process(actions: actions, send: { action in
      sent.append(action)
      if case .completed = action {
        throw NSError(domain: "test", code: 1)
      }
    }, ledger: ledger)

    XCTAssertEqual(sent.count, 1)
    if case .completed = sent[0] {} else {
      XCTFail("expected completed first")
    }

    let retry = await ledger.pending([revoked])
    XCTAssertEqual(retry, actions)
  }

  // MARK: - Properties

  func testCompletedPropertiesKeyNamesAndOmittedNils() {
    let minimal = GrowthPurchaseRecord(
      transactionId: "100",
      originalTransactionId: "50",
      productId: "sku",
      purchaseDate: purchaseDate
    )
    let props = minimal.completedProperties()
    XCTAssertEqual(props["transaction_id"], .string("100"))
    XCTAssertEqual(props["original_transaction_id"], .string("50"))
    XCTAssertEqual(props["product_id"], .string("sku"))
    XCTAssertEqual(props["store"], .string("app_store"))
    XCTAssertEqual(props["source"], .string("storekit2"))
    XCTAssertEqual(props["family_shared"], .bool(false))
    XCTAssertNil(props["price"])
    XCTAssertNil(props["currency"])
    XCTAssertNil(props["product_type"])
  }

  func testCompletedPropertiesPriceAsNumberAndISODate() {
    let props = record().completedProperties()
    XCTAssertEqual(props["price"], .number(9.99))
    XCTAssertEqual(props["currency"], .string("USD"))
    XCTAssertEqual(props["store_environment"], .string("production"))
    XCTAssertEqual(props["product_type"], .string("auto_renewable"))
    XCTAssertEqual(props["storefront"], .string("USA"))
    guard case .string(let dateStr) = props["purchase_date"] else {
      return XCTFail("missing purchase_date")
    }
    XCTAssertTrue(dateStr.contains("2023"))
    guard case .string(let revStr) = record(revoked: true).completedProperties()["revocation_date"] else {
      return XCTFail("missing revocation_date")
    }
    XCTAssertTrue(revStr.contains("2023"))
  }

  func testRefundedPropertiesMatchCompletedShape() {
    let completed = record(revoked: true).completedProperties()
    let refunded = record(revoked: true).refundedProperties()
    XCTAssertEqual(completed, refunded)
  }
}
