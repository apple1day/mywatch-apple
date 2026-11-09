import XCTest
@testable import WatchLink

final class VendorProbeStateTests: XCTestCase {
    func testPreQueryTrafficRetainsItsChannelInsteadOfImplyingAllPacketsAreCommand() {
        var snapshot = VendorProbeSnapshot()
        for _ in 0..<20 { snapshot.recordNotification(channel: .command, byteCount: 20) }
        for _ in 0..<9 { snapshot.recordNotification(channel: .file, byteCount: 16) }
        snapshot.requestSubmitted = true
        snapshot.recordNotification(channel: .command, byteCount: 18)

        XCTAssertEqual(snapshot.notificationCount, 30)
        XCTAssertEqual(snapshot.preQueryNotificationCount, 29)
        XCTAssertEqual(snapshot.commandNotificationCount, 21)
        XCTAssertEqual(snapshot.fileNotificationCount, 9)
        XCTAssertEqual(snapshot.preQueryCommandNotificationCount, 20)
        XCTAssertEqual(snapshot.preQueryFileNotificationCount, 9)
        XCTAssertEqual(snapshot.receivedByteCount, 562)
        XCTAssertEqual(snapshot.commandReceivedByteCount, 418)
        XCTAssertEqual(snapshot.fileReceivedByteCount, 144)
        XCTAssertNil(snapshot.capabilities)
    }

    func testLateSuccessfulATTCallbackDoesNotEraseAnEarlierProtocolFailure() {
        var snapshot = VendorProbeSnapshot()
        snapshot.requestSubmitted = true
        snapshot.status = "FAILED"
        let protocolFailure = VendorGATTTransport.Failure(
            phase: "PROTOCOL_RESPONSE", domain: "WatchLink.ProtocolProbe", code: 1001,
            message: "No complete capability response")
        snapshot.error = protocolFailure
        let observedAt = Date(timeIntervalSince1970: 123)

        XCTAssertTrue(snapshot.recordWriteCompletion(error: nil, at: observedAt))
        XCTAssertTrue(snapshot.attWriteCallbackObserved)
        XCTAssertTrue(snapshot.attWriteAcknowledged)
        XCTAssertEqual(snapshot.attWriteCompletedAt, observedAt)
        XCTAssertEqual(snapshot.status, "FAILED")
        XCTAssertEqual(snapshot.error, protocolFailure)
        XCTAssertEqual(snapshot.accountBinding, "NOT_IMPLEMENTED")
        XCTAssertNil(snapshot.capabilities)

        // A duplicate callback cannot reinterpret the single submitted query.
        XCTAssertFalse(snapshot.recordWriteCompletion(error: protocolFailure,
                                                      at: Date(timeIntervalSince1970: 124)))
        XCTAssertTrue(snapshot.attWriteAcknowledged)
        XCTAssertNil(snapshot.attWriteError)
    }

    func testLateATTErrorRemainsSeparateFromObservedCapabilityState() throws {
        var snapshot = VendorProbeSnapshot()
        snapshot.requestSubmitted = true
        snapshot.status = "CAPABILITIES_RECEIVED_AUTH_PENDING"
        let failure = VendorGATTTransport.Failure(
            phase: "COMMAND_WRITE", domain: "CBATTErrorDomain", code: 5,
            message: "Write failed")

        XCTAssertTrue(snapshot.recordWriteCompletion(error: failure, at: Date(timeIntervalSince1970: 1)))
        XCTAssertTrue(snapshot.attWriteCallbackObserved)
        XCTAssertFalse(snapshot.attWriteAcknowledged)
        XCTAssertEqual(snapshot.attWriteError, failure)
        XCTAssertEqual(snapshot.status, "CAPABILITIES_RECEIVED_AUTH_PENDING")
        XCTAssertNil(snapshot.error)

        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(VendorProbeSnapshot.self, from: data)
        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(restored.vendorAuthentication, "NOT_IMPLEMENTED")
    }

    func testNoATTResultCanBeAssignedBeforeAQueryWasSubmitted() {
        var snapshot = VendorProbeSnapshot()
        XCTAssertFalse(snapshot.recordWriteCompletion(error: nil, at: Date(timeIntervalSince1970: 0)))
        XCTAssertFalse(snapshot.attWriteCallbackObserved)
        XCTAssertFalse(snapshot.attWriteAcknowledged)
        XCTAssertNil(snapshot.attWriteCompletedAt)
        XCTAssertEqual(snapshot.status, "NOT_ATTEMPTED")
    }
}
