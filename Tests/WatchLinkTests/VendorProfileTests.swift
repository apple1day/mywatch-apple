import XCTest
@testable import WatchLink

final class VendorProfileTests: XCTestCase {
    func testObservedCommandProfileRequiresCorrectDirectionAndProperties() {
        // Only the public service/property shape is retained from the real report;
        // no device name, session identifier, timestamp, or private data is used.
        let write = row("write", service: OppoGATTProfile.commandService,
                        characteristic: OppoGATTProfile.commandWrite,
                        properties: ["read", "write", "writeWithoutResponse", "notify"])
        let notify = row("notify", service: OppoGATTProfile.commandService,
                         characteristic: OppoGATTProfile.commandNotify,
                         properties: ["read", "write", "writeWithoutResponse", "notify"])
        XCTAssertTrue(OppoGATTProfile.isAvailable(in: [write, notify]))
        XCTAssertTrue(OppoGATTProfile.isAvailable(in: [
            row("a", service: OppoGATTProfile.commandService.lowercased(),
                characteristic: OppoGATTProfile.commandWrite.lowercased(), properties: ["write"]), notify]))
        XCTAssertFalse(OppoGATTProfile.isAvailable(in: [write]))
        XCTAssertFalse(OppoGATTProfile.isAvailable(in: [notify]))
        XCTAssertFalse(OppoGATTProfile.isAvailable(in: [
            row("a", service: OppoGATTProfile.fileService,
                characteristic: OppoGATTProfile.commandWrite, properties: ["write"]), notify]))
        XCTAssertFalse(OppoGATTProfile.isAvailable(in: [
            row("a", service: OppoGATTProfile.commandService,
                characteristic: OppoGATTProfile.commandWrite, properties: ["writeWithoutResponse"]), notify]))
        XCTAssertFalse(OppoGATTProfile.isAvailable(in: [write,
            row("b", service: OppoGATTProfile.commandService,
                characteristic: OppoGATTProfile.commandNotify, properties: ["read"])]))
    }

    func testDuplicateEndpointsNeverEnableAQueryOnAnAmbiguousService() {
        let write = row("a", service: OppoGATTProfile.commandService,
                        characteristic: OppoGATTProfile.commandWrite, properties: ["write"])
        let notify = row("b", service: OppoGATTProfile.commandService,
                         characteristic: OppoGATTProfile.commandNotify, properties: ["notify"])
        XCTAssertFalse(OppoGATTProfile.isAvailable(in: [write, write, notify]))
        XCTAssertFalse(OppoGATTProfile.isAvailable(in: [write, notify, notify]))
        XCTAssertFalse(OppoGATTProfile.isAvailable(in: [
            row("standard", service: "180A", characteristic: "2A29", properties: ["read"]),
            row("other", service: "FEE9", characteristic: "D44BC439-ABFD-45A2-B575-925416129600",
                properties: ["read", "write", "notify"])]))
    }

    private func row(_ id: String, service: String, characteristic: String, properties: [String]) -> ServiceRow {
        ServiceRow(id: id, serviceUUID: service, characteristicUUID: characteristic, properties: properties)
    }
}
