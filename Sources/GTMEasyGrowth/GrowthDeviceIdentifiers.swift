import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Device-level common context attached to every event. Lightweight and safe
/// to read on every `track()` — the system call below is cheap once cached by
/// the OS.
///
/// Only the vendor identifier (IDFV) is collected. IDFV is first-party — scoped
/// to this vendor's own apps — so it is **not** cross-app advertising tracking
/// and requires no App Tracking Transparency prompt, no IDFA access, and no
/// `NSUserTrackingUsageDescription`. The SDK deliberately does not touch the
/// advertising identifier (IDFA) or the AppTrackingTransparency framework.
public actor GrowthDeviceIdentifiers {
  public static let shared = GrowthDeviceIdentifiers()

  public init() {}

  /// Returns the current device snapshot.
  public func snapshot() -> GrowthDeviceSnapshot {
    GrowthDeviceSnapshot(idfv: readIDFV())
  }

  private func readIDFV() -> String? {
    #if canImport(UIKit) && os(iOS)
    return UIDevice.current.identifierForVendor?.uuidString
    #else
    return nil
    #endif
  }
}

public struct GrowthDeviceSnapshot: Sendable {
  public let idfv: String?

  public init(idfv: String?) {
    self.idfv = idfv
  }

  public var asProperties: [String: GrowthJSONValue] {
    var out: [String: GrowthJSONValue] = [:]
    if let idfv { out["idfv"] = .string(idfv) }
    return out
  }
}
