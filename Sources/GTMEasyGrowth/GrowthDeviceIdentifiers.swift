import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

#if canImport(AdSupport)
import AdSupport
#endif

/// ATT authorization snapshot. `authorized` is the only state that yields a
/// non-zero IDFA on iOS 14.5+; everything else returns the zero UUID.
public enum GrowthATTStatus: String, Sendable {
  case notDetermined = "not_determined"
  case restricted
  case denied
  case authorized
  case unavailable
}

/// Device-level common context attached to every event. Lightweight and safe
/// to read on every `track()` — system calls below are cheap once cached by
/// the OS. The host app is responsible for prompting ATT at a UX-appropriate
/// moment via `requestTrackingAuthorization()`.
public actor GrowthDeviceIdentifiers {
  public static let shared = GrowthDeviceIdentifiers()

  private var cachedSnapshot: GrowthDeviceSnapshot?

  public init() {}

  /// Returns the current device snapshot, refreshed each call so ATT changes
  /// after prompt-and-allow are picked up without restart.
  public func snapshot() -> GrowthDeviceSnapshot {
    let status = currentATTStatus()
    let idfa = readIDFA(for: status)
    let idfv = readIDFV()
    let snap = GrowthDeviceSnapshot(idfa: idfa, idfv: idfv, attStatus: status)
    cachedSnapshot = snap
    return snap
  }

  /// Prompt ATT. Host app picks the moment — Apple's review guidelines (4.5.4)
  /// require user-visible context. Returns the resulting status.
  @discardableResult
  public func requestTrackingAuthorization() async -> GrowthATTStatus {
    #if canImport(AppTrackingTransparency) && os(iOS)
    if #available(iOS 14.5, *) {
      let raw = await ATTrackingManager.requestTrackingAuthorization()
      return mapATT(raw)
    } else {
      return .unavailable
    }
    #else
    return .unavailable
    #endif
  }

  private func currentATTStatus() -> GrowthATTStatus {
    #if canImport(AppTrackingTransparency) && os(iOS)
    if #available(iOS 14.5, *) {
      return mapATT(ATTrackingManager.trackingAuthorizationStatus)
    }
    #endif
    return .unavailable
  }

  private func readIDFA(for status: GrowthATTStatus) -> String? {
    #if canImport(AdSupport) && os(iOS)
    guard status == .authorized else { return nil }
    let raw = ASIdentifierManager.shared().advertisingIdentifier.uuidString
    // Apple returns 00000000-0000-0000-0000-000000000000 when limit ad
    // tracking is on. Treat that as nil so connectors can branch cleanly.
    if raw == "00000000-0000-0000-0000-000000000000" { return nil }
    return raw
    #else
    return nil
    #endif
  }

  private func readIDFV() -> String? {
    #if canImport(UIKit) && os(iOS)
    return UIDevice.current.identifierForVendor?.uuidString
    #else
    return nil
    #endif
  }

  #if canImport(AppTrackingTransparency) && os(iOS)
  @available(iOS 14.0, *)
  private func mapATT(_ status: ATTrackingManager.AuthorizationStatus) -> GrowthATTStatus {
    switch status {
    case .notDetermined: return .notDetermined
    case .restricted: return .restricted
    case .denied: return .denied
    case .authorized: return .authorized
    @unknown default: return .unavailable
    }
  }
  #endif
}

public struct GrowthDeviceSnapshot: Sendable {
  public let idfa: String?
  public let idfv: String?
  public let attStatus: GrowthATTStatus

  public var asProperties: [String: GrowthJSONValue] {
    var out: [String: GrowthJSONValue] = [
      "att_status": .string(attStatus.rawValue),
    ]
    if let idfa { out["idfa"] = .string(idfa) }
    if let idfv { out["idfv"] = .string(idfv) }
    return out
  }
}
