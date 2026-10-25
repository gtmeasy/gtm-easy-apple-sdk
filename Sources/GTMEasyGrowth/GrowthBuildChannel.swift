import Foundation

/// How the running binary was distributed. Resolved once per process by
/// `GrowthBuildChannelDetector` (or taken from `GrowthAnalyticsConfiguration.buildChannel`)
/// and exposed as `GrowthAnalytics.resolvedBuildChannel`.
public enum GrowthBuildChannel: String, Sendable, CaseIterable {
  /// Simulator, Xcode run, development-signed, unsigned or ad-hoc-signed build.
  case debug
  /// TestFlight (iOS sandbox receipt). Mac TestFlight can't be detected offline — pass it
  /// explicitly via `buildChannel`.
  case testflight
  /// Ad Hoc or Enterprise distribution.
  case internalTest
  /// App Store, Mac App Store or Developer ID build.
  case production
  /// Detection found no decisive evidence. Never suppressed (fail open).
  case unknown

  /// Channels dropped when `suppressTestBuilds` is on. `unknown` is deliberately excluded.
  var isTestBuild: Bool {
    switch self {
    case .debug, .testflight, .internalTest: return true
    case .production, .unknown: return false
    }
  }

  /// The single suppression rule shared by every GTM Easy SDK:
  /// `disabled || (suppressTestBuilds && channel in {debug, testflight, internalTest})`.
  static func isSuppressed(disabled: Bool, suppressTestBuilds: Bool, channel: GrowthBuildChannel) -> Bool {
    disabled || (suppressTestBuilds && channel.isTestBuild)
  }
}

/// Code-signing facts the macOS / Mac Catalyst detector reads from the running process.
struct GrowthCodeSigningInfo: Equatable, Sendable {
  /// False for unsigned and ad-hoc-signed code (no signing certificate chain).
  var hasCertificate: Bool
  /// `com.apple.security.get-task-allow` from the signed entitlements.
  var getTaskAllow: Bool
  /// Subject summary of the leaf signing certificate, e.g. `Developer ID Application: …`.
  var leafCertificateName: String?
}

/// Injectable inputs for `GrowthBuildChannelDetector`. Every probe is offline and
/// synchronous; `live` reads the real process, tests pass fixed values.
struct GrowthBuildChannelProbes: Sendable {
  enum Family: Sendable {
    /// iOS, iPadOS, visionOS, tvOS, watchOS — reads `embedded.mobileprovision`.
    case iOS
    /// macOS and Mac Catalyst — reads the running code's signature.
    case mac
    /// Anything else (e.g. Linux): always `unknown`.
    case other
  }

  var family: Family
  var isSimulator: Bool
  /// Raw (CMS-wrapped) `embedded.mobileprovision` bytes, or nil when not bundled.
  var provisioningProfile: @Sendable () -> Data?
  var receiptURL: @Sendable () -> URL?
  var fileExists: @Sendable (URL) -> Bool
  /// Nil when the signature could not be read at all (→ `unknown`, not `debug`).
  var codeSigning: @Sendable () -> GrowthCodeSigningInfo?
}

/// Offline, synchronous build-channel detection. No `AppTransaction` (it can hit the
/// network or prompt for an App Store sign-in) and no `#if DEBUG` (SPM compiles the package
/// with its own configuration, not the host app's).
enum GrowthBuildChannelDetector {
  /// Live detection, computed lazily on first use and cached for the process.
  static let current: GrowthBuildChannel = detect(.live)

  static func detect(_ probes: GrowthBuildChannelProbes) -> GrowthBuildChannel {
    if probes.isSimulator { return .debug }
    switch probes.family {
    case .iOS: return detectIOS(probes)
    case .mac: return detectMac(probes)
    case .other: return .unknown
    }
  }

  private static func detectIOS(_ probes: GrowthBuildChannelProbes) -> GrowthBuildChannel {
    if let data = probes.provisioningProfile() {
      // A bundled profile means a non-App-Store build. Undecidable content stays unknown.
      guard let profile = provisioningProfilePlist(from: data) else { return .unknown }
      let entitlements = profile["Entitlements"] as? [String: Any]
      if entitlements?["get-task-allow"] as? Bool == true { return .debug }
      if profile["ProvisionsAllDevices"] as? Bool == true { return .internalTest }  // enterprise
      if profile["ProvisionedDevices"] != nil { return .internalTest }               // ad hoc
      return .unknown
    }
    guard let receipt = probes.receiptURL() else { return .unknown }
    if receipt.lastPathComponent == "sandboxReceipt" { return .testflight }
    return probes.fileExists(receipt) ? .production : .unknown
  }

  private static func detectMac(_ probes: GrowthBuildChannelProbes) -> GrowthBuildChannel {
    if let signing = probes.codeSigning() {
      if !signing.hasCertificate { return .debug }  // unsigned / ad-hoc (`swift run`, local builds)
      if signing.getTaskAllow { return .debug }     // Xcode run; notarization rejects it
      if signing.leafCertificateName?.hasPrefix("Developer ID Application") == true { return .production }
    }
    // Mac App Store (and Mac TestFlight, indistinguishable offline) ship a receipt.
    if let receipt = probes.receiptURL(), probes.fileExists(receipt) { return .production }
    return .unknown
  }

  /// `embedded.mobileprovision` is a CMS (PKCS#7) envelope around an XML plist. Instead of
  /// decoding CMS, slice the `<?xml … </plist>` byte range and parse that.
  static func provisioningProfilePlist(from data: Data) -> [String: Any]? {
    guard let start = data.range(of: Data("<?xml".utf8)),
          let end = data.range(of: Data("</plist>".utf8), in: start.upperBound..<data.endIndex)
    else { return nil }
    let plist = data.subdata(in: start.lowerBound..<end.upperBound)
    return (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any]
  }
}
