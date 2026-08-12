import Darwin
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Device-level common context attached to every event. Lightweight and safe
/// to read on every `track()` — the system calls below are cheap once cached by
/// the OS.
///
/// Collects:
/// - **IDFV** — first-party vendor identifier (not IDFA; no ATT required)
/// - **Raw hardware model** — `utsname.machine` (e.g. `iPhone17,1`). The server
///   maps this to a marketing name (`iPhone 16 Pro`) for Discord / dashboards;
///   clients must not maintain that table.
/// - **OS version**, **manufacturer** (`Apple`), **physical memory bytes**
///
/// The SDK deliberately does not touch the advertising identifier (IDFA) or
/// AppTrackingTransparency.
public actor GrowthDeviceIdentifiers {
  public static let shared = GrowthDeviceIdentifiers()

  public init() {}

  /// Returns the current device snapshot.
  public func snapshot() -> GrowthDeviceSnapshot {
    GrowthDeviceSnapshot(
      idfv: readIDFV(),
      deviceModel: readMachineIdentifier(),
      deviceManufacturer: "Apple",
      osVersion: readOSVersion(),
      physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
    )
  }

  private func readIDFV() -> String? {
    #if canImport(UIKit) && os(iOS)
    return UIDevice.current.identifierForVendor?.uuidString
    #else
    return nil
    #endif
  }

  /// Raw hardware identifier from `uname` (e.g. `iPhone17,1`, `iPad14,1`).
  /// Simulators typically report `arm64` / `x86_64`.
  private func readMachineIdentifier() -> String? {
    var systemInfo = utsname()
    guard uname(&systemInfo) == 0 else { return nil }
    return withUnsafePointer(to: &systemInfo.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 1) {
        let raw = String(cString: $0)
        return raw.isEmpty ? nil : raw
      }
    }
  }

  private func readOSVersion() -> String {
    #if canImport(UIKit) && (os(iOS) || os(tvOS) || os(visionOS))
    return UIDevice.current.systemVersion
    #else
    let v = ProcessInfo.processInfo.operatingSystemVersion
    if v.patchVersion > 0 {
      return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
    return "\(v.majorVersion).\(v.minorVersion)"
    #endif
  }
}

public struct GrowthDeviceSnapshot: Sendable {
  public let idfv: String?
  /// Raw machine id from `utsname` (`iPhone17,1`). Not a marketing name.
  public let deviceModel: String?
  public let deviceManufacturer: String?
  public let osVersion: String?
  /// `ProcessInfo.processInfo.physicalMemory` (bytes).
  public let physicalMemoryBytes: UInt64?

  public init(
    idfv: String?,
    deviceModel: String? = nil,
    deviceManufacturer: String? = nil,
    osVersion: String? = nil,
    physicalMemoryBytes: UInt64? = nil
  ) {
    self.idfv = idfv
    self.deviceModel = deviceModel
    self.deviceManufacturer = deviceManufacturer
    self.osVersion = osVersion
    self.physicalMemoryBytes = physicalMemoryBytes
  }

  public var asProperties: [String: GrowthJSONValue] {
    var out: [String: GrowthJSONValue] = [:]
    if let idfv { out["idfv"] = .string(idfv) }
    if let deviceModel { out["device_model"] = .string(deviceModel) }
    if let deviceManufacturer { out["device_manufacturer"] = .string(deviceManufacturer) }
    if let osVersion { out["os_version"] = .string(osVersion) }
    if let physicalMemoryBytes {
      out["physical_memory_bytes"] = .number(Double(physicalMemoryBytes))
    }
    return out
  }
}
