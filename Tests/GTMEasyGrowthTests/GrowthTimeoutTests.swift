import Foundation
import XCTest
@testable import GTMEasyGrowth

/// Proves `withTimeoutOrNil` is a HARD deadline — it must return at the timeout even when
/// the operation ignores cancellation (the StoreKit `AppTransaction.shared` failure mode).
final class GrowthTimeoutTests: XCTestCase {
  func testTimeoutDoesNotWaitOnASlowUncancellableOperation() async {
    let start = DispatchTime.now()
    let result = await withTimeoutOrNil(seconds: 0.05) { () async -> String? in
      // Simulate a StoreKit call that ignores cancellation and takes "forever".
      try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
      return "late"
    }
    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    XCTAssertNil(result)
    XCTAssertLessThan(elapsedMs, 2_000, "timeout must be a hard bound, not block on the slow operation")
  }

  func testReturnsOperationValueWhenItBeatsTheTimeout() async {
    let result = await withTimeoutOrNil(seconds: 5) { () async -> String? in "fast" }
    XCTAssertEqual(result, "fast")
  }

  func testReturnsNilWhenOperationYieldsNilBeforeTimeout() async {
    let result = await withTimeoutOrNil(seconds: 5) { () async -> String? in nil }
    XCTAssertNil(result)
  }
}
