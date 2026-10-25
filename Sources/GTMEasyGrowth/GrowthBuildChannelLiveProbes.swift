import Foundation

#if os(macOS) || targetEnvironment(macCatalyst)
import Security
#endif

extension GrowthBuildChannelProbes {
  /// Probes backed by the running process: `Bundle.main`, the file system and (on the Mac)
  /// the code signature of the running binary.
  static var live: GrowthBuildChannelProbes {
    GrowthBuildChannelProbes(
      family: liveFamily,
      isSimulator: liveIsSimulator,
      provisioningProfile: {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else { return nil }
        return try? Data(contentsOf: url)
      },
      receiptURL: { Bundle.main.appStoreReceiptURL },
      fileExists: { FileManager.default.fileExists(atPath: $0.path) },
      codeSigning: { liveCodeSigning() }
    )
  }

  private static var liveFamily: Family {
    #if os(macOS) || targetEnvironment(macCatalyst)
    return .mac
    #elseif os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    return .iOS
    #else
    return .other
    #endif
  }

  private static var liveIsSimulator: Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }

  private static func liveCodeSigning() -> GrowthCodeSigningInfo? {
    #if os(macOS) || targetEnvironment(macCatalyst)
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    let status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
    if status == errSecCSUnsigned {
      return GrowthCodeSigningInfo(hasCertificate: false, getTaskAllow: false, leafCertificateName: nil)
    }
    guard status == errSecSuccess, let dict = info as? [String: Any] else { return nil }
    // Unsigned code yields no certificates; ad-hoc signatures carry none by definition.
    let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
    let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
    let isAdHoc = flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
    return GrowthCodeSigningInfo(
      hasCertificate: !certificates.isEmpty && !isAdHoc,
      getTaskAllow: entitlements?["com.apple.security.get-task-allow"] as? Bool ?? false,
      leafCertificateName: certificates.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
    )
    #else
    return nil
    #endif
  }
}
