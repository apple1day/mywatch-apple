import Foundation
import XCTest
@testable import WatchLink

final class OppoSetupTests: XCTestCase {
    // Synthetic state-machine fixtures, not recordings from a watch. Only the
    // schema and start/query command bytes come from the inspected vendor APK.
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)

    func testVerifiedStartRequestAndQueryRequireActualSubmissionAndWholeWriteSuccess() throws {
        let engine = makeEngine()
        let start = try sent(engine.start())
        XCTAssertEqual(start.serviceID, 11)
        XCTAssertEqual(start.commandID, 7)
        XCTAssertEqual(start.protobuf, Data([0x08, 0x01, 0x10, 0x02]))
        XCTAssertEqual(start.phase, .startSetting)
        XCTAssertEqual(engine.snapshot.startedAt, instant)
        XCTAssertTrue(engine.start().isEmpty)
        XCTAssertTrue(engine.writeCompleted(token: start.token, succeeded: true).isEmpty)
        XCTAssertFalse(engine.snapshot.startWriteAcknowledged)
        _ = engine.didSubmit(token: start.token, streamOffset: 100)
        XCTAssertTrue(engine.writeCompleted(token: start.token + 99, succeeded: true).isEmpty)
        let query = try sent(engine.writeCompleted(token: start.token, succeeded: true))
        XCTAssertEqual(query.serviceID, 11)
        XCTAssertEqual(query.commandID, 11)
        XCTAssertTrue(query.protobuf.isEmpty)
        XCTAssertEqual(query.phase, .queryState)
        XCTAssertNotEqual(query.token, start.token)
        XCTAssertTrue(engine.snapshot.startWriteAcknowledged)
        XCTAssertFalse(engine.snapshot.queryWriteAcknowledged)
        XCTAssertFalse(engine.snapshot.deviceSetupFinishedReported)
        XCTAssertTrue(engine.writeCompleted(token: start.token, succeeded: false).isEmpty)
        XCTAssertEqual(engine.phase, .queryState)
    }

    func testFailedStartDoesNotSendQueryOrReviveWithLateCallback() throws {
        let engine = makeEngine()
        let start = try sent(engine.start())
        _ = engine.didSubmit(token: start.token, streamOffset: 100)
        let failure = try failed(engine.writeCompleted(token: start.token, succeeded: false))
        XCTAssertEqual(failure.phase, .startSetting)
        XCTAssertEqual(failure.code, "ATT_WRITE_FAILED")
        XCTAssertFalse(engine.snapshot.startWriteAcknowledged)
        XCTAssertTrue(engine.writeCompleted(token: start.token, succeeded: true).isEmpty)
        XCTAssertTrue(engine.receive(try state(60)).isEmpty)
        XCTAssertFalse(engine.snapshot.deviceSetupFinishedReported)
    }

    func testPreSubmissionAndOldFragmentMessagesCannotBecomeObservations() throws {
        let engine = makeEngine()
        let start = try sent(engine.start())
        XCTAssertTrue(engine.receive(try state(60, offset: 100)).isEmpty)
        _ = engine.didSubmit(token: start.token, streamOffset: 100)
        XCTAssertTrue(engine.receive(try state(60, offset: 99)).isEmpty)
        XCTAssertNil(engine.snapshot.preQueryObservation)
        XCTAssertNil(engine.snapshot.latestObservation)
        XCTAssertEqual(engine.snapshot.diagnostics.preSubmissionMessageCount, 1)
        XCTAssertEqual(engine.snapshot.diagnostics.staleMessageCount, 1)
    }

    func testPreQueryStateIsRetainedWithoutClaimingQueryResponseOrCompletion() throws {
        let engine = makeEngine()
        let start = try sent(engine.start())
        _ = engine.didSubmit(token: start.token, streamOffset: 100)
        XCTAssertTrue(engine.receive(try state(60, command: 12, offset: 101)).isEmpty)
        XCTAssertEqual(engine.snapshot.preQueryObservation?.result, 60)
        XCTAssertEqual(engine.snapshot.preQueryObservation?.source, "BEFORE_QUERY_SUBMISSION")
        let query = try sent(engine.writeCompleted(token: start.token, succeeded: true))
        XCTAssertTrue(engine.receive(try state(10, command: 12, offset: 150)).isEmpty)
        _ = engine.didSubmit(token: query.token, streamOffset: 200)
        _ = engine.writeCompleted(token: query.token, succeeded: true)
        XCTAssertEqual(engine.snapshot.preQueryObservation?.result, 10)
        XCTAssertEqual(engine.snapshot.diagnostics.preQueryStateCount, 2)
        XCTAssertNil(engine.snapshot.latestObservation)
        XCTAssertTrue(engine.snapshot.observations.isEmpty)
        XCTAssertFalse(engine.snapshot.deviceSetupFinishedReported)
        XCTAssertEqual(engine.phase, .observing)
    }

    func testMessageThatStartedBeforeQueryRemainsPreQueryAfterItsFinalFragmentArrives() throws {
        let engine = makeEngine()
        _ = try reachQuery(engine)
        XCTAssertTrue(engine.receive(try state(60, command: 12, offset: 199)).isEmpty)
        XCTAssertEqual(engine.snapshot.preQueryObservation?.source, "STARTED_BEFORE_QUERY_SUBMISSION")
        XCTAssertEqual(engine.snapshot.preQueryObservation?.result, 60)
        XCTAssertNil(engine.snapshot.latestObservation)
        XCTAssertEqual(engine.phase, .observing)
    }

    func testEarlyQueryStateWaitsForWholeQueryWriteSuccess() throws {
        let engine = makeEngine()
        let query = try reachQuery(engine, acknowledge: false)
        XCTAssertTrue(engine.receive(try state(60)).isEmpty)
        XCTAssertEqual(engine.snapshot.diagnostics.bufferedStateCount, 1)
        XCTAssertNil(engine.snapshot.latestObservation)
        XCTAssertFalse(engine.snapshot.queryWriteAcknowledged)
        XCTAssertFalse(engine.snapshot.deviceSetupFinishedReported)
        let actions = engine.writeCompleted(token: query.token, succeeded: true)
        XCTAssertEqual(try observed(actions).result, 60)
        XCTAssertEqual(try finished(actions), .deviceReportedFinished)
        XCTAssertTrue(engine.snapshot.queryWriteAcknowledged)
        XCTAssertTrue(engine.snapshot.deviceSetupFinishedReported)
    }

    func testFailedQueryDiscardsBufferedTerminalState() throws {
        let engine = makeEngine()
        let query = try reachQuery(engine, acknowledge: false)
        _ = engine.receive(try state(60))
        let failure = try failed(engine.writeCompleted(token: query.token, succeeded: false))
        XCTAssertEqual(failure.phase, .queryState)
        XCTAssertEqual(failure.code, "ATT_WRITE_FAILED")
        XCTAssertTrue(engine.snapshot.startWriteAcknowledged)
        XCTAssertFalse(engine.snapshot.queryWriteAcknowledged)
        XCTAssertNil(engine.snapshot.latestObservation)
        XCTAssertFalse(engine.snapshot.deviceSetupFinishedReported)
        XCTAssertTrue(engine.writeCompleted(token: query.token, succeeded: true).isEmpty)
    }

    func testBufferedProgressThenTerminalStateAreAppliedInReceiveOrderAfterQueryACK() throws {
        let engine = makeEngine()
        let query = try reachQuery(engine, acknowledge: false)
        _ = engine.receive(try state(10))
        _ = engine.receive(try state(47, command: 12, offset: 210))
        _ = engine.receive(try state(60, command: 12, offset: 220))
        let actions = engine.writeCompleted(token: query.token, succeeded: true)
        XCTAssertEqual(observations(actions).map(\.result), [10, 47, 60])
        XCTAssertEqual(try finished(actions), .deviceReportedFinished)
        XCTAssertEqual(engine.snapshot.observations.map(\.result), [10, 47, 60])
        XCTAssertEqual(engine.snapshot.accountBinding, "NOT_IMPLEMENTED")
    }

    func testProgressKeepsObservingForSubsequentWatchNotification() throws {
        let engine = makeEngine()
        _ = try reachQuery(engine)
        for value in [0, 10, 47, 59] {
            let actions = engine.receive(try state(value))
            XCTAssertEqual(try observed(actions).result, value)
            XCTAssertEqual(actions.count, 1)
            XCTAssertTrue(engine.snapshot.isRunning)
            XCTAssertEqual(engine.phase, .observing)
            XCTAssertNil(engine.snapshot.completedAt)
        }
        let terminal = engine.receive(try state(60, command: 12, offset: 250))
        XCTAssertEqual(try finished(terminal), .deviceReportedFinished)
        XCTAssertEqual(engine.snapshot.completedAt, instant)
        XCTAssertTrue(engine.snapshot.deviceSetupFinishedReported)
        XCTAssertEqual(engine.snapshot.accountBinding, "NOT_IMPLEMENTED")
        XCTAssertTrue(engine.timeout().isEmpty)
        XCTAssertTrue(engine.receive(try state(0, offset: 300)).isEmpty)
        XCTAssertEqual(engine.snapshot.latestObservation?.result, 60)
    }

    func testTimeoutWithRealProgressMeansPendingRatherThanLoginFailure() throws {
        let engine = makeEngine()
        _ = try reachQuery(engine)
        _ = engine.receive(try state(47))
        XCTAssertEqual(try finished(engine.timeout()), .awaitingDevice)
        XCTAssertNil(engine.snapshot.error)
        XCTAssertEqual(engine.snapshot.latestObservation?.result, 47)
        XCTAssertFalse(engine.snapshot.deviceSetupFinishedReported)
        XCTAssertFalse(engine.snapshot.isRunning)
    }

    func testTimeoutWithoutCurrentQueryObservationDoesNotPromotePreQueryTerminalState() throws {
        let engine = makeEngine()
        let start = try sent(engine.start())
        _ = engine.didSubmit(token: start.token, streamOffset: 100)
        _ = engine.receive(try state(60, command: 12, offset: 110))
        let query = try sent(engine.writeCompleted(token: start.token, succeeded: true))
        _ = engine.didSubmit(token: query.token, streamOffset: 200)
        _ = engine.writeCompleted(token: query.token, succeeded: true)
        let failure = try failed(engine.timeout())
        XCTAssertEqual(failure.code, "OOBE_STATE_TIMEOUT")
        XCTAssertTrue(failure.message.contains("查询前"))
        XCTAssertEqual(engine.snapshot.preQueryObservation?.result, 60)
        XCTAssertNil(engine.snapshot.latestObservation)
        XCTAssertFalse(engine.snapshot.deviceSetupFinishedReported)
    }

    func testUnknownNumericStatesDoNotUseVendorsBroadSuccessNegation() throws {
        for value in [-1, Int(Int32.min), 1, 2, 9, 61, 999, Int(Int32.max)] {
            let engine = makeEngine()
            _ = try reachQuery(engine)
            let observation = try observed(engine.receive(try state(value)))
            XCTAssertEqual(observation.result, value)
            XCTAssertEqual(observation.interpretation, .unknown)
            XCTAssertTrue(engine.snapshot.isRunning)
            XCTAssertFalse(engine.snapshot.deviceSetupFinishedReported)
            XCTAssertEqual(try finished(engine.timeout()), .unrecognizedState)
            XCTAssertNil(engine.snapshot.error)
        }
    }

    func testProto3OmittedZeroRetainsEncodedFieldProvenance() throws {
        let engine = makeEngine()
        _ = try reachQuery(engine)
        let body = try OppoProtobufWriter.encode([2: .varint(0), 3: .varint(1)])
        let observation = try observed(engine.receive(message(body: body)))
        XCTAssertEqual(observation.result, 0)
        XCTAssertEqual(observation.deviceType, 0)
        XCTAssertEqual(observation.oobeFrom, 1)
        XCTAssertEqual(observation.encodedFieldNumbers, [2, 3])
        XCTAssertEqual(observation.interpretation, .notStarted)
        XCTAssertEqual(observation.source, "AFTER_QUERY_SUBMISSION_NO_TRANSACTION_ID")
        XCTAssertEqual(observation.observedAt, instant)
        XCTAssertFalse(engine.snapshot.deviceSetupFinishedReported)
    }

    func testEmptyQueryEchoAndEmptyNotificationCannotSupplyDefaultZeroOrSuccess() throws {
        let engine = makeEngine()
        _ = try reachQuery(engine)
        for command in [UInt8(11), 12, 0x8b, 0x8c] {
            XCTAssertTrue(engine.receive(message(command: command, body: Data())).isEmpty)
        }
        XCTAssertNil(engine.snapshot.latestObservation)
        XCTAssertEqual(engine.snapshot.diagnostics.echoMessageCount, 4)
        XCTAssertEqual(try failed(engine.timeout()).code, "OOBE_STATE_TIMEOUT")
    }

    func testStartEchoOtherCommandsAndWrongServiceCannotCompleteSetup() throws {
        let engine = makeEngine()
        _ = try reachQuery(engine)
        XCTAssertTrue(engine.receive(message(command: 0x87, body: Data([8, 1, 16, 2]))).isEmpty)
        XCTAssertTrue(engine.receive(try state(60, command: 9)).isEmpty)
        XCTAssertTrue(engine.receive(message(service: 1, body: Data([8, 60]))).isEmpty)
        XCTAssertEqual(engine.snapshot.diagnostics.echoMessageCount, 1)
        XCTAssertNil(engine.snapshot.latestObservation)
        XCTAssertFalse(engine.snapshot.deviceSetupFinishedReported)
    }

    func testMalformedOrOutOfRangeStateFailsWithoutWrappingToTerminalCode() throws {
        let cases: [Data] = [
            Data([0x08]),                         // truncated value
            Data([0x08, 60, 0x08, 60]),           // duplicate result
            Data([0x0a, 0x01, 60]),               // wrong known wire type
            Data([0x08, 0xbc, 0x00]),             // noncanonical 60
            try OppoProtobufWriter.encode([1: .varint(UInt64(UInt32.max) + 61)]),
            try OppoProtobufWriter.encode([2: .varint(UInt64(UInt32.max))]),
            try OppoProtobufWriter.encode([9: .varint(60)]) // unknown fields only
        ]
        for body in cases {
            let engine = makeEngine()
            _ = try reachQuery(engine)
            XCTAssertEqual(try failed(engine.receive(message(body: body))).code, "INVALID_OOBE_STATE")
            XCTAssertNil(engine.snapshot.latestObservation)
            XCTAssertFalse(engine.snapshot.deviceSetupFinishedReported)
        }
    }

    func testMalformedPreQueryStateIsIgnoredWithoutBlockingVerifiedQuery() throws {
        let engine = makeEngine()
        let start = try sent(engine.start())
        _ = engine.didSubmit(token: start.token, streamOffset: 100)
        XCTAssertTrue(engine.receive(message(body: Data([8]), offset: 100)).isEmpty)
        XCTAssertEqual(engine.snapshot.diagnostics.lastIgnoredReason, "INVALID_PRE_QUERY_STATE")
        XCTAssertNil(engine.snapshot.preQueryObservation)
        XCTAssertEqual(try sent(engine.writeCompleted(token: start.token, succeeded: true)).commandID, 11)
    }

    func testUnknownOrdinaryFieldsDoNotEraseKnownNumericState() throws {
        let engine = makeEngine()
        _ = try reachQuery(engine)
        let body = try OppoProtobufWriter.encode([1: .varint(10), 2: .varint(1), 3: .varint(0),
                                                  9: .bytes(Data([0xde, 0xad]))])
        let observation = try observed(engine.receive(message(body: body)))
        XCTAssertEqual(observation.result, 10)
        XCTAssertEqual(observation.encodedFieldNumbers, [1, 2, 3])
        XCTAssertTrue(engine.snapshot.isRunning)
    }

    func testAlreadyValidatedEncryptedMessagesKeepRealControlsAndCommandAlias() throws {
        for control in [UInt16(0), 8, 0x40, 0x48, 0x4b] {
            let engine = makeEngine()
            _ = try reachQuery(engine)
            let actions = engine.receive(try state(60, command: 0x8c, control: control))
            XCTAssertEqual(try observed(actions).commandID, 0x8c)
            XCTAssertEqual(try finished(actions), .deviceReportedFinished)
        }
        let unsupported = makeEngine()
        _ = try reachQuery(unsupported)
        XCTAssertTrue(unsupported.receive(try state(60, control: 0x80)).isEmpty)
        XCTAssertNil(unsupported.snapshot.latestObservation)
        XCTAssertEqual(unsupported.snapshot.diagnostics.lastIgnoredReason, "UNSUPPORTED_SETUP_CONTROL")
    }

    func testQuerySubmissionCannotMoveAfterFirstWriteOrBackBeforeStart() throws {
        let engine = makeEngine()
        let query = try reachQuery(engine)
        _ = engine.didSubmit(token: query.token, streamOffset: 300)
        XCTAssertEqual(try observed(engine.receive(try state(10, offset: 250))).result, 10)

        let invalid = makeEngine()
        let start = try sent(invalid.start())
        _ = invalid.didSubmit(token: start.token, streamOffset: 100)
        let invalidQuery = try sent(invalid.writeCompleted(token: start.token, succeeded: true))
        XCTAssertEqual(try failed(invalid.didSubmit(token: invalidQuery.token, streamOffset: 99)).code,
                       "INVALID_SUBMISSION_OFFSET")
    }

    func testEarlyStateBufferIsBoundedAndCannotAdvanceWithoutACK() throws {
        let engine = makeEngine()
        _ = try reachQuery(engine, acknowledge: false)
        for index in 0..<8 {
            XCTAssertTrue(engine.receive(try state(10, offset: 200 + index)).isEmpty)
        }
        XCTAssertEqual(try failed(engine.receive(try state(60, offset: 220))).code,
                       "EARLY_STATE_BUDGET_EXCEEDED")
        XCTAssertEqual(engine.snapshot.diagnostics.bufferedStateCount, 8)
        XCTAssertNil(engine.snapshot.latestObservation)
        XCTAssertFalse(engine.snapshot.deviceSetupFinishedReported)
    }

    func testObservationHistoryIsBoundedWhileCountsAndLatestRemainAccurate() throws {
        let engine = makeEngine()
        _ = try reachQuery(engine)
        for index in 0..<20 { _ = engine.receive(try state(10, offset: 200 + index)) }
        XCTAssertEqual(engine.snapshot.observations.count, 16)
        XCTAssertEqual(engine.snapshot.observations.first?.streamOffset, 204)
        XCTAssertEqual(engine.snapshot.latestObservation?.streamOffset, 219)
        XCTAssertEqual(engine.snapshot.diagnostics.observedStateCount, 20)
        XCTAssertEqual(engine.snapshot.diagnostics.duplicateStateCount, 19)
        XCTAssertTrue(engine.snapshot.isRunning)
        XCTAssertEqual(try finished(engine.timeout()), .awaitingDevice)
    }

    func testAbortPreservesObservedFactsAndPreventsLateContinuation() throws {
        let engine = makeEngine()
        let query = try reachQuery(engine)
        _ = engine.receive(try state(10))
        let failure = try failed(engine.abort(code: "BUSINESS_CHANNEL_FAILED", message: "会话已断开"))
        XCTAssertEqual(failure.phase, .observing)
        XCTAssertEqual(engine.snapshot.error, failure)
        XCTAssertEqual(engine.snapshot.latestObservation?.result, 10)
        XCTAssertEqual(engine.snapshot.completedAt, instant)
        XCTAssertTrue(engine.receive(try state(60)).isEmpty)
        XCTAssertTrue(engine.writeCompleted(token: query.token, succeeded: true).isEmpty)
        XCTAssertTrue(engine.abort(code: "LATE_ERROR", message: "迟到回调").isEmpty)
        XCTAssertEqual(engine.snapshot.error?.code, "BUSINESS_CHANNEL_FAILED")
    }

    func testCancelDiscardsBufferedStateAndDoesNotOverwriteCompletedFacts() throws {
        let engine = makeEngine()
        let query = try reachQuery(engine, acknowledge: false)
        _ = engine.receive(try state(60))
        engine.cancel()
        XCTAssertEqual(engine.phase, .cancelled)
        XCTAssertTrue(engine.writeCompleted(token: query.token, succeeded: true).isEmpty)
        XCTAssertTrue(engine.receive(try state(60)).isEmpty)
        XCTAssertFalse(engine.snapshot.deviceSetupFinishedReported)

        let completed = makeEngine()
        _ = try reachQuery(completed)
        _ = completed.receive(try state(60))
        let before = completed.snapshot
        completed.cancel()
        XCTAssertEqual(completed.snapshot, before)
    }

    func testSnapshotRoundTripReportsNumericEvidenceWithoutPayloadOrClaimingAccountBinding() throws {
        let engine = makeEngine()
        _ = try reachQuery(engine)
        _ = engine.receive(try state(60))
        let encoded = try JSONEncoder().encode(engine.snapshot)
        XCTAssertEqual(try JSONDecoder().decode(OppoSetupSnapshot.self, from: encoded), engine.snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["accountBinding"] as? String, "NOT_IMPLEMENTED")
        let observation = try XCTUnwrap(object["latestObservation"] as? [String: Any])
        XCTAssertEqual(observation["result"] as? Int, 60)
        XCTAssertEqual(Set(observation.keys), Set(["result", "encodedFieldNumbers", "commandID",
                                                  "streamOffset", "observedAt", "source"]))
        XCTAssertTrue(engine.snapshot.summary.contains("账号绑定未验证"))
    }

    private func makeEngine() -> OppoSetup {
        let date = instant
        return OppoSetup(now: { date })
    }

    private func reachQuery(_ engine: OppoSetup, acknowledge: Bool = true) throws -> OppoSetup.Command {
        let start = try sent(engine.start())
        _ = engine.didSubmit(token: start.token, streamOffset: 100)
        let query = try sent(engine.writeCompleted(token: start.token, succeeded: true))
        _ = engine.didSubmit(token: query.token, streamOffset: 200)
        if acknowledge { _ = engine.writeCompleted(token: query.token, succeeded: true) }
        return query
    }

    private func state(_ result: Int, command: UInt8 = 11, offset: Int = 200,
                       control: UInt16 = 0) throws -> OppoWireMessage {
        let body = try OppoProtobufWriter.encode([1: .varint(UInt64(bitPattern: Int64(result)))])
        return message(command: command, body: body, offset: offset, control: control)
    }

    private func message(service: UInt8 = 11, command: UInt8 = 11, body: Data,
                         offset: Int = 200, control: UInt16 = 0) -> OppoWireMessage {
        OppoWireMessage(serviceID: service, commandID: command, protobuf: body, streamOffset: offset,
                        controlFlags: control, frameCount: 1, frameShape: "SINGLE", crcValidation: "VALID")
    }

    private func sent(_ actions: [OppoSetup.Action]) throws -> OppoSetup.Command {
        try XCTUnwrap(actions.compactMap { action -> OppoSetup.Command? in
            if case .send(let command) = action { return command }
            return nil
        }.first)
    }

    private func observations(_ actions: [OppoSetup.Action]) -> [OppoSetup.StateObservation] {
        actions.compactMap { action in
            if case .observed(let observation) = action { return observation }
            return nil
        }
    }

    private func observed(_ actions: [OppoSetup.Action]) throws -> OppoSetup.StateObservation {
        try XCTUnwrap(observations(actions).first)
    }

    private func finished(_ actions: [OppoSetup.Action]) throws -> OppoSetup.Outcome {
        try XCTUnwrap(actions.compactMap { action -> OppoSetup.Outcome? in
            if case .finished(let outcome) = action { return outcome }
            return nil
        }.first)
    }

    private func failed(_ actions: [OppoSetup.Action]) throws -> OppoSetup.Failure {
        try XCTUnwrap(actions.compactMap { action -> OppoSetup.Failure? in
            if case .failed(let failure) = action { return failure }
            return nil
        }.first)
    }
}
