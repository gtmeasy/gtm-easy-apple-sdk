import XCTest
@testable import GTMEasyGrowth

final class GrowthDeviceIdentifiersTests: XCTestCase {
  func testAsPropertiesIncludesHardwareFields() {
    let snap = GrowthDeviceSnapshot(
      idfv: "00000000-0000-0000-0000-000000000001",
      deviceModel: "iPhone17,1",
      deviceManufacturer: "Apple",
      osVersion: "18.5",
      physicalMemoryBytes: 8_589_934_592
    )
    let props = snap.asProperties
    XCTAssertEqual(props["idfv"], .string("00000000-0000-0000-0000-000000000001"))
    XCTAssertEqual(props["device_model"], .string("iPhone17,1"))
    XCTAssertEqual(props["device_manufacturer"], .string("Apple"))
    XCTAssertEqual(props["os_version"], .string("18.5"))
    XCTAssertEqual(props["physical_memory_bytes"], .number(8_589_934_592))
  }

  func testAsPropertiesOmitsNilFields() {
    let snap = GrowthDeviceSnapshot(idfv: nil)
    XCTAssertTrue(snap.asProperties.isEmpty)
  }

  func testLiveSnapshotHasModelOsAndMemory() async {
    let snap = await GrowthDeviceIdentifiers.shared.snapshot()
    // Simulator reports arm64/x86_64; devices report iPhone*/iPad*/Mac*.
    XCTAssertNotNil(snap.deviceModel)
    XCTAssertFalse(snap.deviceModel?.isEmpty ?? true)
    XCTAssertEqual(snap.deviceManufacturer, "Apple")
    XCTAssertNotNil(snap.osVersion)
    XCTAssertFalse(snap.osVersion?.isEmpty ?? true)
    XCTAssertNotNil(snap.physicalMemoryBytes)
    XCTAssertGreaterThan(snap.physicalMemoryBytes ?? 0, 0)
  }

  #if os(macOS)
  func testMacSnapshotReportsHardwareModelNotArch() async {
    let snap = await GrowthDeviceIdentifiers.shared.snapshot()
    let model = snap.deviceModel ?? ""
    XCTAssertNotEqual(model, "arm64")
    XCTAssertNotEqual(model, "x86_64")
    XCTAssertTrue(model.contains("Mac"), "expected hw.model like Mac15,3, got \(model)")
  }
  #endif
}
