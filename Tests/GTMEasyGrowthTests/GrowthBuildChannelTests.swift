import Foundation
import XCTest
@testable import GTMEasyGrowth

/// Fixed probes for `GrowthBuildChannelDetector`. Defaults describe a device with no
/// evidence at all (→ `unknown`).
func stubProbes(
  family: GrowthBuildChannelProbes.Family = .iOS,
  isSimulator: Bool = false,
  profile: Data? = nil,
  receiptURL: URL? = nil,
  receiptExists: Bool = false,
  codeSigning: GrowthCodeSigningInfo? = nil
) -> GrowthBuildChannelProbes {
  GrowthBuildChannelProbes(
    family: family,
    isSimulator: isSimulator,
    provisioningProfile: { profile },
    receiptURL: { receiptURL },
    fileExists: { _ in receiptExists },
    codeSigning: { codeSigning }
  )
}

final class GrowthBuildChannelTests: XCTestCase {
  private let sandboxReceipt = URL(fileURLWithPath: "/app/StoreKit/sandboxReceipt")
  private let storeReceipt = URL(fileURLWithPath: "/app/StoreKit/receipt")
  private let macReceipt = URL(fileURLWithPath: "/Applications/App.app/Contents/_MASReceipt/receipt")

  /// A provisioning profile as shipped: the XML plist wrapped in (fake) CMS bytes.
  private func profile(_ plist: [String: Any]) throws -> Data {
    let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    var data = Data([0x30, 0x82, 0x2F, 0x1A, 0x06, 0x09, 0x2A, 0x86, 0x48])  // DER header noise
    data.append(xml)
    data.append(Data([0xA0, 0x82, 0x0D, 0x3C, 0x30, 0x82, 0x04]))           // signer noise
    return data
  }

  // MARK: - Detection (iOS family)

  func testSimulatorIsDebug() {
    XCTAssertEqual(GrowthBuildChannelDetector.detect(stubProbes(isSimulator: true, receiptURL: storeReceipt, receiptExists: true)), .debug)
    XCTAssertEqual(GrowthBuildChannelDetector.detect(stubProbes(family: .mac, isSimulator: true)), .debug)
  }

  func testDevelopmentProfileWithGetTaskAllowIsDebug() throws {
    let data = try profile(["Entitlements": ["get-task-allow": true], "ProvisionedDevices": ["00008110-0001"]])
    XCTAssertEqual(GrowthBuildChannelDetector.detect(stubProbes(profile: data)), .debug)
  }

  func testEnterpriseProfileIsInternalTest() throws {
    let data = try profile(["Entitlements": ["get-task-allow": false], "ProvisionsAllDevices": true])
    XCTAssertEqual(GrowthBuildChannelDetector.detect(stubProbes(profile: data)), .internalTest)
  }

  func testAdHocProfileIsInternalTest() throws {
    let data = try profile(["Entitlements": ["get-task-allow": false], "ProvisionedDevices": ["00008110-0001"]])
    XCTAssertEqual(GrowthBuildChannelDetector.detect(stubProbes(profile: data)), .internalTest)
  }

  func testUndecidableOrCorruptProfileIsUnknown() throws {
    let noKeys = try profile(["Entitlements": ["get-task-allow": false]])
    XCTAssertEqual(GrowthBuildChannelDetector.detect(stubProbes(profile: noKeys, receiptURL: storeReceipt, receiptExists: true)), .unknown)
    XCTAssertEqual(GrowthBuildChannelDetector.detect(stubProbes(profile: Data([0x30, 0x82, 0x00]))), .unknown)
  }

  func testCMSWrappedPlistIsExtracted() throws {
    let data = try profile(["Name": "Fixture", "Entitlements": ["get-task-allow": true]])
    let plist = try XCTUnwrap(GrowthBuildChannelDetector.provisioningProfilePlist(from: data))
    XCTAssertEqual(plist["Name"] as? String, "Fixture")
  }

  func testSandboxReceiptWithoutProfileIsTestFlight() {
    // The sandbox receipt file may not exist yet on a fresh TestFlight install; the name decides.
    XCTAssertEqual(GrowthBuildChannelDetector.detect(stubProbes(receiptURL: sandboxReceipt, receiptExists: false)), .testflight)
  }

  func testStoreReceiptPresentIsProduction() {
    XCTAssertEqual(GrowthBuildChannelDetector.detect(stubProbes(receiptURL: storeReceipt, receiptExists: true)), .production)
  }

  func testNoProfileNoReceiptIsUnknown() {
    XCTAssertEqual(GrowthBuildChannelDetector.detect(stubProbes(receiptURL: storeReceipt, receiptExists: false)), .unknown)
    XCTAssertEqual(GrowthBuildChannelDetector.detect(stubProbes()), .unknown)
  }

  // MARK: - Detection (macOS / Catalyst)

  func testMacUnsignedOrAdHocIsDebug() {
    let unsigned = GrowthCodeSigningInfo(hasCertificate: false, getTaskAllow: false, leafCertificateName: nil)
    XCTAssertEqual(GrowthBuildChannelDetector.detect(stubProbes(family: .mac, codeSigning: unsigned)), .debug)
  }

  func testMacGetTaskAllowIsDebug() {
    let dev = GrowthCodeSigningInfo(hasCertificate: true, getTaskAllow: true, leafCertificateName: "Apple Development: Jane (ABC123)")
    XCTAssertEqual(GrowthBuildChannelDetector.detect(stubProbes(family: .mac, receiptURL: macReceipt, receiptExists: true, codeSigning: dev)), .debug)
  }

  func testMacDeveloperIDIsProduction() {
    let devID = GrowthCodeSigningInfo(hasCertificate: true, getTaskAllow: false, leafCertificateName: "Developer ID Application: RockieStar Inc (ABC123)")
    XCTAssertEqual(GrowthBuildChannelDetector.detect(stubProbes(family: .mac, codeSigning: devID)), .production)
  }

  func testMacAppStoreReceiptIsProduction() {
    let mas = GrowthCodeSigningInfo(hasCertificate: true, getTaskAllow: false, leafCertificateName: "Apple Mac OS Application Signing")
    XCTAssertEqual(GrowthBuildChannelDetector.detect(stubProbes(family: .mac, receiptURL: macReceipt, receiptExists: true, codeSigning: mas)), .production)
  }

  func testMacWithoutEvidenceIsUnknown() {
    let other = GrowthCodeSigningInfo(hasCertificate: true, getTaskAllow: false, leafCertificateName: "Apple Distribution: Jane (ABC123)")
    XCTAssertEqual(GrowthBuildChannelDetector.detect(stubProbes(family: .mac, receiptURL: macReceipt, codeSigning: other)), .unknown)
    // Unreadable signature is no evidence of a debug build.
    XCTAssertEqual(GrowthBuildChannelDetector.detect(stubProbes(family: .mac, codeSigning: nil)), .unknown)
  }

  func testOtherPlatformsAreUnknown() {
    XCTAssertEqual(GrowthBuildChannelDetector.detect(stubProbes(family: .other, receiptURL: storeReceipt, receiptExists: true)), .unknown)
  }

  // MARK: - Suppression rule

  func testSuppressionRule() {
    for channel in GrowthBuildChannel.allCases {
      let expected = [.debug, .testflight, .internalTest].contains(channel)
      XCTAssertEqual(GrowthBuildChannel.isSuppressed(disabled: false, suppressTestBuilds: true, channel: channel), expected, "\(channel)")
      XCTAssertFalse(GrowthBuildChannel.isSuppressed(disabled: false, suppressTestBuilds: false, channel: channel), "\(channel)")
      XCTAssertTrue(GrowthBuildChannel.isSuppressed(disabled: true, suppressTestBuilds: false, channel: channel), "\(channel)")
    }
  }

  func testUnknownIsNeverSuppressed() {
    let analytics = makeAnalytics(suppressTestBuilds: true, probes: stubProbes())
    XCTAssertEqual(analytics.resolvedBuildChannel, .unknown)
    XCTAssertFalse(analytics.isSuppressed)
  }

  func testDetectedTestBuildIsSuppressedOnlyWhenOptedIn() {
    let debugProbes = stubProbes(isSimulator: true)
    let optedIn = makeAnalytics(suppressTestBuilds: true, probes: debugProbes)
    XCTAssertEqual(optedIn.resolvedBuildChannel, .debug)
    XCTAssertTrue(optedIn.isSuppressed)

    let defaultOff = makeAnalytics(suppressTestBuilds: false, probes: debugProbes)
    XCTAssertEqual(defaultOff.resolvedBuildChannel, .debug)
    XCTAssertFalse(defaultOff.isSuppressed)
  }

  func testOverrideWinsOverDetection() {
    let overriddenToProduction = makeAnalytics(suppressTestBuilds: true, buildChannel: .production, probes: stubProbes(isSimulator: true))
    XCTAssertEqual(overriddenToProduction.resolvedBuildChannel, .production)
    XCTAssertFalse(overriddenToProduction.isSuppressed)

    // e.g. Mac TestFlight, which detection reports as production.
    let macTestFlight = makeAnalytics(
      suppressTestBuilds: true, buildChannel: .testflight,
      probes: stubProbes(family: .mac, receiptURL: macReceipt, receiptExists: true)
    )
    XCTAssertEqual(macTestFlight.resolvedBuildChannel, .testflight)
    XCTAssertTrue(macTestFlight.isSuppressed)
  }

  func testDisabledIsSuppressedOnAnyChannel() {
    let analytics = makeAnalytics(disabled: true, buildChannel: .production, probes: nil)
    XCTAssertTrue(analytics.isSuppressed)
  }

  private func makeAnalytics(
    disabled: Bool = false,
    suppressTestBuilds: Bool = false,
    buildChannel: GrowthBuildChannel? = nil,
    probes: GrowthBuildChannelProbes?
  ) -> GrowthAnalytics {
    GrowthAnalytics(
      configuration: GrowthAnalyticsConfiguration(
        app: "milelog", writeKey: "k",
        endpoint: URL(string: "https://gtmeasy.test")!,
        userDefaults: UserDefaults(suiteName: "GrowthBuildChannelTests-\(UUID().uuidString)")!,
        disabled: disabled,
        suppressTestBuilds: suppressTestBuilds,
        buildChannel: buildChannel
      ),
      session: MockSession(response: "{}"),
      buildChannelProbes: probes
    )
  }
}
