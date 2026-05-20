import Foundation

#if canImport(StoreKit)
import StoreKit
#endif

/// SKAdNetwork 4.0 helper. Wraps `SKAdNetwork.registerAppForAdNetworkAttribution`
/// (iOS 11.3+) + `updatePostbackConversionValue` (iOS 16.1+).
///
/// CV encoding follows the Adjust pattern documented in the implementation
/// plan: a 6-bit fine value composed of revenue bucket (3 bits), funnel stage
/// (2 bits), and engagement bit (1 bit). Coarse value is computed from the
/// revenue bucket on iOS 16.1+ (SKAN 4.0).
@available(iOS 14.0, *)
public actor GrowthSKAN {
  public static let shared = GrowthSKAN()

  private var registered = false

  /// Mark the install for SKAdNetwork attribution. Call once at app launch
  /// AFTER `Info.plist` lists every ad network identifier you intend to use.
  public func registerForAttribution() {
    guard !registered else { return }
    registered = true
    #if canImport(StoreKit) && os(iOS)
    if #available(iOS 16.1, *) {
      // iOS 16.1+: registration is implicit when you call
      // updatePostbackConversionValue, but Apple still recommends an explicit
      // first call so the first conversion window starts immediately.
      SKAdNetwork.updatePostbackConversionValue(0) { error in
        if let error { print("[GrowthSKAN] initial postback failed: \(error)") }
      }
    } else {
      SKAdNetwork.registerAppForAdNetworkAttribution()
    }
    #endif
  }

  /// Update the postback conversion value. Pick `funnel` based on user
  /// activity; pass `revenue` (USD-equivalent) only for paid conversions.
  ///
  /// `lockWindow=true` ends the current conversion window early so the
  /// postback is sent ASAP — useful for the second/third windows where you've
  /// already captured everything you can learn about this install.
  public func updateConversion(
    funnel: GrowthSKANFunnelStage,
    revenue: Double = 0,
    engagementBit: Bool = false,
    lockWindow: Bool = false
  ) {
    let cv = GrowthSKANConversionValue.encode(funnel: funnel, revenue: revenue, engagementBit: engagementBit)
    #if canImport(StoreKit) && os(iOS)
    if #available(iOS 16.1, *) {
      SKAdNetwork.updatePostbackConversionValue(
        cv.fineValue,
        coarseValue: cv.coarseValue.skanValue,
        lockWindow: lockWindow
      ) { error in
        if let error { print("[GrowthSKAN] postback failed: \(error)") }
      }
    } else if #available(iOS 15.4, *) {
      SKAdNetwork.updatePostbackConversionValue(cv.fineValue) { error in
        if let error { print("[GrowthSKAN] postback failed: \(error)") }
      }
    } else if #available(iOS 14.0, *) {
      SKAdNetwork.updateConversionValue(cv.fineValue)
    }
    #endif
    Task {
      await GrowthDebugSink.shared.record(.init(
        kind: .attribution,
        label: "skan.conversion.\(funnel.rawValue)",
        properties: [
          "fine": .number(Double(cv.fineValue)),
          "coarse": .string(cv.coarseValue.rawValue),
          "revenue": .number(revenue),
          "engagement_bit": .bool(engagementBit),
        ]
      ))
    }
  }
}

public enum GrowthSKANFunnelStage: Int, Sendable {
  case install = 0
  case onboarded = 1
  case trial = 2
  case purchase = 3
}

public enum GrowthSKANCoarseValue: String, Sendable {
  case low
  case medium
  case high

  #if canImport(StoreKit) && os(iOS)
  @available(iOS 16.1, *)
  var skanValue: SKAdNetwork.CoarseConversionValue {
    switch self {
    case .low: return .low
    case .medium: return .medium
    case .high: return .high
    }
  }
  #endif
}

public struct GrowthSKANConversionValue: Sendable {
  public let fineValue: Int
  public let coarseValue: GrowthSKANCoarseValue

  /// 6-bit fine value: `(revenueBucket << 3) | (funnelStage << 1) | engagementBit`.
  ///
  /// Revenue buckets (USD):
  /// 0=$0, 1=$0–1, 2=$1–5, 3=$5–10, 4=$10–25, 5=$25–50, 6=$50–100, 7=$100+
  public static func encode(funnel: GrowthSKANFunnelStage, revenue: Double, engagementBit: Bool) -> GrowthSKANConversionValue {
    let bucket = revenueBucket(revenue)
    let engagement = engagementBit ? 1 : 0
    let funnelBits = funnel.rawValue & 0b11
    let fine = (bucket << 3) | (funnelBits << 1) | engagement
    return GrowthSKANConversionValue(fineValue: fine & 0b111111, coarseValue: coarse(bucket))
  }

  /// Decode a fine value back to its components — useful for server-side
  /// postback interpretation + unit tests.
  public static func decode(fine: Int) -> (funnel: GrowthSKANFunnelStage, revenueBucket: Int, engagementBit: Bool) {
    let f = fine & 0b111111
    let bucket = (f >> 3) & 0b111
    let funnelRaw = (f >> 1) & 0b11
    let engagement = (f & 0b1) == 1
    return (GrowthSKANFunnelStage(rawValue: funnelRaw) ?? .install, bucket, engagement)
  }

  static func revenueBucket(_ revenue: Double) -> Int {
    if revenue <= 0 { return 0 }
    if revenue <= 1 { return 1 }
    if revenue <= 5 { return 2 }
    if revenue <= 10 { return 3 }
    if revenue <= 25 { return 4 }
    if revenue <= 50 { return 5 }
    if revenue <= 100 { return 6 }
    return 7
  }

  static func coarse(_ bucket: Int) -> GrowthSKANCoarseValue {
    switch bucket {
    case 0...2: return .low
    case 3...5: return .medium
    default: return .high
    }
  }
}
