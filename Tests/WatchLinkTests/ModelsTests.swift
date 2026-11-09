import XCTest
@testable import WatchLink

final class ModelsTests: XCTestCase {
    func testCandidateNamesAreOnlyHints() {
        XCTAssertTrue(WatchProfile.isNameCandidate("OnePlus Watch A1B2"))
        XCTAssertTrue(WatchProfile.isNameCandidate("oneplus watch-abcd"))
        XCTAssertTrue(WatchProfile.isNameCandidate("W301CN"))
        XCTAssertTrue(WatchProfile.isNameCandidate("W501CN-Demo"))
        XCTAssertFalse(WatchProfile.isNameCandidate(nil))
        XCTAssertFalse(WatchProfile.isNameCandidate("OPPO Watch"))
        XCTAssertFalse(WatchProfile.isNameCandidate("OnePlus Watch XYZ"))
        XCTAssertFalse(WatchProfile.isNameCandidate("OnePlus Watch 2R"))
    }

    func testMalformedBatteryIsNeverInventedAsAValidPercentage() {
        XCTAssertEqual(WatchProfile.standardValue(uuid: "2A19", data: Data([0])).value, "0%")
        XCTAssertEqual(WatchProfile.standardValue(uuid: "2A19", data: Data([100])).value, "100%")
        XCTAssertEqual(WatchProfile.standardValue(uuid: "2A19", data: nil).status, "EMPTY")
        XCTAssertEqual(WatchProfile.standardValue(uuid: "2A19", data: Data()).status, "EMPTY")
        XCTAssertEqual(WatchProfile.standardValue(uuid: "2A19", data: Data([255])).status, "INVALID")
        XCTAssertEqual(WatchProfile.standardValue(uuid: "2A19", data: Data([50, 1])).status, "INVALID")
    }

    func testDeviceInformationUsesUTF8AndAReadWhitelist() {
        XCTAssertEqual(WatchProfile.standardValue(uuid: "2A26", data: Data("A.45\0".utf8)).value, "A.45")
        XCTAssertEqual(WatchProfile.standardValue(uuid: "2A26", data: Data([0xff, 0xfe])).status, "INVALID")
        XCTAssertEqual(WatchProfile.standardValue(uuid: "2A25", data: Data("serial".utf8)).status, "NOT_READ")
        XCTAssertTrue(WatchProfile.canReadStandard(characteristic: "2a19", service: "180f"))
        XCTAssertTrue(WatchProfile.canReadStandard(characteristic: "00002A26-0000-1000-8000-00805F9B34FB", service: "180A"))
        XCTAssertFalse(WatchProfile.canReadStandard(characteristic: "2A19", service: WatchProfile.commandRFCOMM))
        XCTAssertFalse(WatchProfile.canReadStandard(characteristic: "2A25", service: "180A"))
    }

    func testSessionIdentifiersAreStableOnlyWithTheSameSalt() {
        let id = UUID(uuidString: "12345678-1234-5678-1234-567812345678")!
        XCTAssertEqual(WatchProfile.anonymousID(id, salt: "a"), WatchProfile.anonymousID(id, salt: "a"))
        XCTAssertNotEqual(WatchProfile.anonymousID(id, salt: "a"), WatchProfile.anonymousID(id, salt: "b"))
        XCTAssertEqual(WatchProfile.anonymousID(id, salt: "a").count, 12)
        XCTAssertFalse(WatchProfile.anonymousID(id, salt: "a").contains(id.uuidString))
    }

    func testReportDoesNotTurnGATTIntoVendorBindingOrExposeIdentifier() throws {
        let identifier = UUID(uuidString: "12345678-1234-5678-1234-567812345678")!
        let device = DiscoveredDevice(id: identifier, name: "OnePlus Watch A1B2", rssi: -45,
                                      isCandidate: true, advertisedServices: ["180F"], isConnectable: true)
        let report = ProbeReport(schemaVersion: 5, generatedAt: Date(timeIntervalSince1970: 0),
                                 platform: PlatformSnapshot(system: "iOS", systemVersion: "16.0", deviceType: "iPhone", appVersion: "0.4.0", appBuild: "5"),
                                 capabilities: CapabilitySnapshot(), selectedDevice: DeviceSnapshot(device: device, salt: "session"),
                                 observations: ObservationSnapshot(stateText: "GATT 检测完成", bluetoothState: "蓝牙已开启", scanningAtExport: false, connectingAtExport: false,
                                                                   gattConnectedAtExport: true, gattConnectionObservedThisAttempt: true, result: "GATT_DIAGNOSTICS_COMPLETE"),
                                 services: [], standardReadings: [], events: [], privacy: "脱敏")
        let data = report.encoded()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains(identifier.uuidString))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let capabilities = try XCTUnwrap(object["capabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["classicRFCOMM"] as? String, WatchProfile.classicUnavailable)
        XCTAssertEqual(capabilities["vendorAuthentication"] as? String, "EXPERIMENTAL_PROTOCOL_3_TO_5")
        XCTAssertEqual(capabilities["initialSetup"] as? String, "EXPERIMENTAL_START_AND_STATE_OBSERVATION")
        XCTAssertEqual(capabilities["accountBinding"] as? String, WatchProfile.notImplemented)
        XCTAssertEqual(capabilities["healthSync"] as? String, WatchProfile.notImplemented)
        let observation = try XCTUnwrap(object["observations"] as? [String: Any])
        XCTAssertEqual(observation["gattConnectedAtExport"] as? Bool, true)
    }

    func testNamesAndStandardTextAreBoundedWithoutControlCharacters() {
        XCTAssertEqual(WatchProfile.safeText(" a\nb\t "), "a b")
        XCTAssertEqual(WatchProfile.safeText(String(repeating: "表", count: 100), limit: 3), "表表表…")
        XCTAssertEqual(WatchProfile.normalizeUUID("0000180f-0000-1000-8000-00805f9b34fb"), "180F")
        XCTAssertEqual(WatchProfile.normalizeUUID(WatchProfile.commandRFCOMM), WatchProfile.commandRFCOMM.uppercased())
    }
}
