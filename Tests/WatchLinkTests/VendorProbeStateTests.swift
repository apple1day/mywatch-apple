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
        XCTAssertEqual(restored.vendorAuthentication, "NOT_ATTEMPTED")
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

final class VendorCommandAndCapabilityTests: XCTestCase {
    func testPartialOrDuplicateATTReceiptCannotCompleteLogicalCommand() {
        var write = VendorCommandWriteSnapshot(commandID: 25, stage: "IDENTITY_CHECK", frameCount: 3,
                                                queuedAt: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(write.recordCallback(error: nil, at: Date()))
        XCTAssertTrue(write.recordSubmission(index: 0, at: Date()))
        XCTAssertFalse(write.recordSubmission(index: 1, at: Date()))
        XCTAssertTrue(write.recordCallback(error: nil, at: Date()))
        XCTAssertFalse(write.recordCallback(error: nil, at: Date()))
        XCTAssertFalse(write.fullyAcknowledged)
        for index in 1..<3 {
            XCTAssertTrue(write.recordSubmission(index: index, at: Date()))
            XCTAssertTrue(write.recordCallback(error: nil, at: Date()))
        }
        XCTAssertTrue(write.fullyAcknowledged)
        XCTAssertFalse(write.recordSubmission(index: 3, at: Date()))
    }

    func testATTFailurePreventsFurtherSubmissionAndLateSuccess() throws {
        var write = VendorCommandWriteSnapshot(commandID: 36, stage: "SESSION_KEY_EXCHANGE", frameCount: 3,
                                                queuedAt: Date(timeIntervalSince1970: 0))
        let failure = VendorGATTTransport.Failure(phase: "COMMAND_WRITE", domain: "CBATTErrorDomain",
                                                 code: 5, message: "write failed")
        XCTAssertTrue(write.recordSubmission(index: 0, at: Date()))
        XCTAssertTrue(write.recordCallback(error: failure, at: Date()))
        XCTAssertFalse(write.recordCallback(error: nil, at: Date()))
        XCTAssertFalse(write.recordSubmission(index: 1, at: Date()))
        XCTAssertFalse(write.fullyAcknowledged)
        XCTAssertEqual(write.acknowledgedFragments, 0)
        XCTAssertEqual(write.callbackCount, 1)
        XCTAssertEqual(try JSONDecoder().decode(VendorCommandWriteSnapshot.self,
                                                from: JSONEncoder().encode(write)), write)
    }

    func testActiveCapabilitiesRetainObservationSourceAndNeverInventAResponse() throws {
        let early = capability()
        let choice = try XCTUnwrap(VendorCapabilitySelection.choose(response: nil, unsolicited: early))
        XCTAssertEqual(choice.source, "PRE_QUERY_OBSERVATION")
        XCTAssertEqual(choice.capabilities, early)
        XCTAssertNil(try VendorCapabilitySelection.choose(response: nil, unsolicited: nil))
        let later = try XCTUnwrap(VendorCapabilitySelection.choose(response: early, unsolicited: early))
        XCTAssertEqual(later.source, "POST_QUERY_MESSAGE_NO_TRANSACTION_ID")
    }

    func testConflictingBeforeAndAfterQueryCapabilitiesCannotSelectAProtocol() {
        XCTAssertThrowsError(try VendorCapabilitySelection.choose(response: capability(version: 4),
                                                                  unsolicited: capability(version: 3)))
        XCTAssertThrowsError(try VendorCapabilitySelection.choose(response: capability(support: 0),
                                                                  unsolicited: capability(support: 3)))
    }

    func testLatePreQueryAndCoalescedCapabilitiesParticipateBeforeCompletion() throws {
        let selected = capability()
        XCTAssertThrowsError(try VendorCapabilitySelection.validate(selected: selected, response: nil,
            unsolicited: capability(version: 3), incoming: []))
        XCTAssertThrowsError(try VendorCapabilitySelection.validate(selected: selected, response: selected,
            unsolicited: nil, incoming: [selected, capability(support: 0)]))
        XCTAssertThrowsError(try VendorCapabilitySelection.validate(selected: nil, response: nil,
            unsolicited: nil, incoming: [selected, capability(version: 4)]))
        XCTAssertNoThrow(try VendorCapabilitySelection.validate(selected: selected, response: selected,
            unsolicited: selected, incoming: [selected, selected]))
    }

    func testAuthenticationFactsDoNotUpgradeBusinessBindingOrExposeProofs() throws {
        var snapshot = VendorProbeSnapshot()
        snapshot.status = "INITIAL_SETUP_OBSERVED"
        snapshot.vendorAuthentication = "PASSED"
        snapshot.authentication.phase = .completed
        snapshot.authentication.status = "PASSED"
        snapshot.authentication.identityVerified = true
        snapshot.authentication.keyExchangeVerified = true
        snapshot.authentication.transportAuthenticated = true
        snapshot.businessSessionState = "ENDED"
        snapshot.businessEncrypted = true
        let setup = OppoSetup()
        guard case .send(let start)? = setup.start().first else { return XCTFail("Missing start request") }
        _ = setup.didSubmit(token: start.token, streamOffset: 0)
        guard case .send(let query)? = setup.writeCompleted(token: start.token, succeeded: true).first else {
            return XCTFail("Missing state query")
        }
        _ = setup.didSubmit(token: query.token, streamOffset: 0)
        _ = setup.writeCompleted(token: query.token, succeeded: true)
        _ = setup.receive(OppoWireMessage(serviceID: 11, commandID: 12, protobuf: Data([0x08, 0x3c]),
                                         streamOffset: 0, controlFlags: 0x40, frameCount: 1,
                                         frameShape: "SINGLE_FRAME", crcValidation: "CRC16_LE_VERIFIED"))
        snapshot.initialSetup = setup.snapshot
        var receipt = VendorCommandWriteSnapshot(commandID: 11, stage: "QUERY_OOBE_STATE", frameCount: 2,
                                                queuedAt: Date(timeIntervalSince1970: 0))
        receipt.serviceID = 11
        receipt.encrypted = true
        snapshot.commandWrites = [receipt]
        let encoded = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(VendorProbeSnapshot.self, from: encoded)
        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(restored.accountBinding, "NOT_IMPLEMENTED")
        XCTAssertEqual(restored.initialSetup.accountBinding, "NOT_IMPLEMENTED")
        XCTAssertTrue(restored.initialSetup.deviceSetupFinishedReported)
        XCTAssertEqual(restored.commandWrites.first?.serviceID, 11)
        XCTAssertEqual(restored.commandWrites.first?.encrypted, true)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for privateField in ["clientNonce", "watchNonce", "protobuf", "identityKey", "privateKey", "encryptedProof", "key32", "iv16"] {
            XCTAssertFalse(text.contains("\"" + privateField + "\""))
        }
    }

    func testEnabledSubscriptionsWithNoDataRemainAZeroNotificationTimeout() {
        var snapshot = VendorProbeSnapshot()
        snapshot.commandNotificationsEnabled = true
        snapshot.fileNotificationsEnabled = true
        snapshot.commandNotificationActivation = "ENABLE_CONFIRMED"
        snapshot.commandNotificationCallbackCount = 1
        snapshot.capabilityQuery.queuedAttempts = 4
        snapshot.capabilityQuery.submittedAttempts = 4
        snapshot.capabilityQuery.acknowledgedAttempts = 4

        let failure = snapshot.recordCapabilityTimeout(hasPendingData: false)
        XCTAssertEqual(snapshot.capabilityTimeoutReason, "NO_NOTIFICATIONS")
        XCTAssertEqual(failure.phase, "PROTOCOL_RESPONSE")
        XCTAssertTrue(failure.message.contains("命令 0、文件 0"))
        XCTAssertEqual(snapshot.notificationCount, 0)
        XCTAssertFalse(snapshot.authentication.transportAuthenticated)
        XCTAssertEqual(snapshot.accountBinding, "NOT_IMPLEMENTED")
    }

    func testFileTrafficAndEmptyCommandNotificationsHaveDifferentTimeoutReasons() {
        var snapshot = VendorProbeSnapshot()
        snapshot.recordNotification(channel: .file, byteCount: 20)
        _ = snapshot.recordCapabilityTimeout(hasPendingData: false)
        XCTAssertEqual(snapshot.capabilityTimeoutReason, "FILE_NOTIFICATIONS_ONLY")
        XCTAssertEqual(snapshot.receivedByteCount, 20)
        XCTAssertEqual(snapshot.commandReceivedByteCount, 0)

        snapshot.recordNotification(channel: .command, byteCount: 0)
        _ = snapshot.recordCapabilityTimeout(hasPendingData: false)
        XCTAssertEqual(snapshot.capabilityTimeoutReason, "EMPTY_COMMAND_NOTIFICATIONS")
        XCTAssertEqual(snapshot.commandNotificationCount, 1)
        XCTAssertNil(snapshot.capabilities)
    }

    func testPartialCommandAndRejectedCompleteDataHaveDifferentTimeoutReasons() {
        var snapshot = VendorProbeSnapshot()
        snapshot.recordNotification(channel: .command, byteCount: 20)
        _ = snapshot.recordCapabilityTimeout(hasPendingData: true)
        XCTAssertEqual(snapshot.capabilityTimeoutReason, "INCOMPLETE_COMMAND_MESSAGE")

        snapshot.decoderDiagnostics.lastIssue = "CRC_MISMATCH"
        let failure = snapshot.recordCapabilityTimeout(hasPendingData: false)
        XCTAssertEqual(snapshot.capabilityTimeoutReason, "NO_VALID_CAPABILITIES")
        XCTAssertTrue(failure.message.contains("CRC_MISMATCH"))
        XCTAssertFalse(snapshot.authentication.identityVerified)
    }

    func testIncompleteRetryWriteIsNotReportedAsACompletedQueryWithNoResponse() {
        var snapshot = VendorProbeSnapshot()
        snapshot.capabilityQuery.queuedAttempts = 2
        snapshot.capabilityQuery.submittedAttempts = 2
        snapshot.capabilityQuery.acknowledgedAttempts = 1
        snapshot.attWriteAcknowledged = true // The first query did complete.
        snapshot.capabilities = capability()

        _ = snapshot.recordCapabilityTimeout(hasPendingData: false)
        XCTAssertEqual(snapshot.capabilityTimeoutReason, "CAPABILITY_WRITE_INCOMPLETE")
        XCTAssertFalse(snapshot.authentication.transportAuthenticated)
        XCTAssertEqual(snapshot.capabilityQuery.acknowledgedAttempts, 1)
    }

    func testObservedCapabilityCannotBeMisreportedAsNoValidCapabilityAtTimeout() {
        for isPreQuery in [false, true] {
            var snapshot = VendorProbeSnapshot()
            snapshot.capabilityQuery.queuedAttempts = 1
            snapshot.capabilityQuery.submittedAttempts = 1
            snapshot.capabilityQuery.acknowledgedAttempts = 1
            if isPreQuery { snapshot.decoderDiagnostics.unsolicitedCapabilities = capability() }
            else { snapshot.capabilities = capability() }

            _ = snapshot.recordCapabilityTimeout(hasPendingData: false)
            XCTAssertEqual(snapshot.capabilityTimeoutReason, "CAPABILITIES_OBSERVED_NOT_ADVANCED")
            XCTAssertFalse(snapshot.authentication.transportAuthenticated)
            XCTAssertEqual(snapshot.accountBinding, "NOT_IMPLEMENTED")
        }
    }

    func testRetryAndSubscriptionObservationsSurviveReportEncoding() throws {
        var snapshot = VendorProbeSnapshot()
        snapshot.commandNotificationActivation = "ALREADY_ENABLED"
        snapshot.fileNotificationActivation = "ENABLE_REQUESTED"
        snapshot.commandNotificationsEnabled = true
        snapshot.capabilityQuery.queuedAttempts = 2
        snapshot.capabilityQuery.submittedAttempts = 2
        snapshot.capabilityQuery.acknowledgedAttempts = 2
        var receipt = VendorCommandWriteSnapshot(commandID: 1, stage: "TRANSPORT_QUERY", frameCount: 1,
                                                queuedAt: Date(timeIntervalSince1970: 0))
        receipt.queryAttempt = 2
        snapshot.commandWrites = [receipt]
        _ = snapshot.recordCapabilityTimeout(hasPendingData: false)

        let restored = try JSONDecoder().decode(VendorProbeSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(restored.commandNotificationCallbackCount, 0)
        XCTAssertEqual(restored.commandNotificationActivation, "ALREADY_ENABLED")
        XCTAssertEqual(restored.notificationCount, 0)
        XCTAssertEqual(restored.commandWrites.first?.queryAttempt, 2)
        XCTAssertEqual(restored.capabilityTimeoutReason, "NO_NOTIFICATIONS")
    }

    func testUnstartedProtocolNeverDisplaysAsAwaitingACapabilityReply() {
        var snapshot = VendorProbeSnapshot()
        XCTAssertEqual(snapshot.capabilityProgressLabel, "尚未开始")
        snapshot.profileDiscoveryCompleted = true
        snapshot.profileAvailable = true
        XCTAssertEqual(snapshot.capabilityProgressLabel, "尚未开始")
        XCTAssertEqual(snapshot.capabilityQuery.submittedAttempts, 0)
        XCTAssertFalse(snapshot.requestSubmitted)
    }

    func testCapabilityProgressDistinguishesSubscriptionWaitingFailureAndInterruption() {
        var snapshot = VendorProbeSnapshot()
        snapshot.status = "SUBSCRIBING"
        XCTAssertEqual(snapshot.capabilityProgressLabel, "正在开启通知")
        snapshot.status = "WAITING_FOR_RESPONSE"
        snapshot.requestSubmitted = true
        XCTAssertEqual(snapshot.capabilityProgressLabel, "等待结果")
        snapshot.status = "FAILED"
        XCTAssertEqual(snapshot.capabilityProgressLabel, "未取得")
        snapshot.status = "INTERRUPTED"
        XCTAssertEqual(snapshot.capabilityProgressLabel, "已中断")
    }

    func testLaterFailureKeepsPreviouslyObservedCapabilityProgress() {
        for source in 0..<3 {
            var snapshot = VendorProbeSnapshot()
            snapshot.status = "FAILED"
            switch source {
            case 0: snapshot.capabilities = capability()
            case 1: snapshot.decoderDiagnostics.unsolicitedCapabilities = capability()
            default: snapshot.authentication.selectedCapabilities = capability()
            }
            XCTAssertEqual(snapshot.capabilityProgressLabel, "已取得")
            XCTAssertFalse(snapshot.authentication.transportAuthenticated)
            XCTAssertEqual(snapshot.accountBinding, "NOT_IMPLEMENTED")
        }
    }

    private func capability(version: Int = 5, support: UInt32 = 3) -> OppoTransportCapabilities {
        OppoTransportCapabilities(protocolVersion: version, maxFrameSize: 20, maxTransmissionUnit: 20,
                                  interval: 10, supportProtocol: support, commandID: 0x81, controlFlags: 0,
                                  frameCount: 1, frameShape: "SINGLE_FRAME", crcValidation: "CRC16_LE_VERIFIED",
                                  encodedFieldNumbers: [1, 2, 3, 4, 5])
    }
}
