import Foundation
import XCTest
@testable import WatchLink

final class OppoInitialSetupIntegrationTests: XCTestCase {
    /// Synthetic peers, not a watch recording. Identity/AES use the real crypto
    /// implementation; only RSA key unwrapping is injected to supply fixed
    /// session material. This exercises the actual authentication state machine
    /// and the complete session -> wire -> session -> setup boundary.
    func testAuthenticatedSessionCarriesSetupAndPreservesReplyOriginUntilQueryACK() throws {
        for encrypted in [false, true] {
            var phoneDecoder = OppoTransportDecoder(emitAuthenticationMessages: true, emitBusinessMessages: true)
            let session = try authenticate(encrypted: encrypted, decoder: &phoneDecoder)
            defer { session.invalidate() }
            XCTAssertEqual(session.isEncrypted, encrypted)
            XCTAssertGreaterThan(phoneDecoder.diagnostics.receivedByteCount, 0)

            var watchDecoder = OppoTransportDecoder(emitBusinessMessages: true)
            let setup = OppoSetup()
            let start = try setupCommand(setup.start())
            _ = setup.didSubmit(token: start.token, streamOffset: phoneDecoder.diagnostics.receivedByteCount)
            let receivedStart = try transmit(start, session: session, decoder: &watchDecoder)
            XCTAssertEqual(receivedStart.serviceID, 11)
            XCTAssertEqual(receivedStart.commandID, 7)
            XCTAssertEqual(receivedStart.protobuf, Data([8, 1, 16, 2]))
            XCTAssertEqual(receivedStart.controlFlags & 0x40, encrypted ? 0x40 : 0)
            if encrypted { XCTAssertGreaterThan(receivedStart.frameCount, 1) }
            let query = try setupCommand(setup.writeCompleted(token: start.token, succeeded: true))

            // A state message starts before the query, but finishes afterward.
            // The first header byte, not decryption time, owns its provenance.
            let statePayload = Data([11, 0x8c, 8, 60])
            let frames = try OppoProtocol.encodePayload(session.sealPayload(statePayload),
                encrypted: session.isEncrypted, maximumFrameLength: 20)
            let stateBytes = frames.reduce(Data(), +)
            let oldOffset = phoneDecoder.diagnostics.receivedByteCount
            XCTAssertTrue(phoneDecoder.append(Data(stateBytes.prefix(1))).isEmpty)
            let queryBoundary = phoneDecoder.diagnostics.receivedByteCount
            _ = setup.didSubmit(token: query.token, streamOffset: queryBoundary)
            let receivedQuery = try transmit(query, session: session, decoder: &watchDecoder)
            XCTAssertEqual(receivedQuery.serviceID, 11)
            XCTAssertEqual(receivedQuery.commandID, 11)
            XCTAssertTrue(receivedQuery.protobuf.isEmpty)

            let oldEvent = try singleEvent(feed(Data(stateBytes.dropFirst()), decoder: &phoneDecoder))
            let oldState = try open(oldEvent, session: session)
            XCTAssertEqual(oldState.streamOffset, oldOffset)
            XCTAssertLessThan(oldState.streamOffset, queryBoundary)
            XCTAssertTrue(setup.receive(oldState).isEmpty)
            XCTAssertEqual(setup.snapshot.preQueryObservation?.result, 60)
            XCTAssertEqual(setup.snapshot.preQueryObservation?.source, "STARTED_BEFORE_QUERY_SUBMISSION")
            XCTAssertNil(setup.snapshot.latestObservation)
            XCTAssertFalse(setup.snapshot.deviceSetupFinishedReported)

            // A fresh fragmented encrypted reply is decoded before the query's
            // final ATT callback. It must remain buffered until the whole ACK.
            let currentOffset = phoneDecoder.diagnostics.receivedByteCount
            let currentEvent = try singleEvent(feed(stateBytes, decoder: &phoneDecoder))
            let currentState = try open(currentEvent, session: session)
            XCTAssertEqual(currentState.streamOffset, currentOffset)
            XCTAssertGreaterThanOrEqual(currentState.streamOffset, queryBoundary)
            XCTAssertEqual(currentState.frameCount, frames.count)
            XCTAssertEqual(currentState.crcValidation, "CRC16_LE_VERIFIED")
            XCTAssertEqual(currentState.controlFlags, encrypted ? 0x43 : 0)
            if encrypted {
                XCTAssertEqual(frames.count, 2)
                XCTAssertEqual(currentState.frameShape, "REASSEMBLED_FRAGMENTS")
            }
            XCTAssertTrue(setup.receive(currentState).isEmpty)
            XCTAssertEqual(setup.snapshot.diagnostics.bufferedStateCount, 1)
            XCTAssertFalse(setup.snapshot.queryWriteAcknowledged)
            XCTAssertFalse(setup.snapshot.deviceSetupFinishedReported)

            let actions = setup.writeCompleted(token: query.token, succeeded: true)
            XCTAssertTrue(actions.contains { action in
                if case .finished(.deviceReportedFinished) = action { return true }
                return false
            })
            XCTAssertTrue(setup.snapshot.queryWriteAcknowledged)
            XCTAssertTrue(setup.snapshot.deviceSetupFinishedReported)
            XCTAssertEqual(setup.snapshot.latestObservation?.streamOffset, currentOffset)
            XCTAssertEqual(setup.snapshot.latestObservation?.source, "AFTER_QUERY_SUBMISSION_NO_TRANSACTION_ID")
            XCTAssertEqual(setup.snapshot.accountBinding, "NOT_IMPLEMENTED")
        }
    }

    private func authenticate(encrypted: Bool, decoder: inout OppoTransportDecoder) throws -> OppoBusinessSession {
        let clientNonce: UInt64 = 1000
        let watchNonce: UInt64 = 2000
        let challenge = Data([0x12, 0x34, 0x56, 0x78])
        let key = Data((0..<32).map { UInt8($0) })
        let iv = Data((0..<16).map { UInt8($0) })
        let wrappedKey = Data(repeating: 0x77, count: 256)
        var dependencies = OppoAuthentication.Dependencies.live
        dependencies.makeNonce = { clientNonce }
        dependencies.randomChallenge = { challenge }
        dependencies.makeRSA = {
            OppoAuthentication.RSAContext(modulus: Data(repeating: 0x80, count: 256),
                exponent: Data([1, 0, 1]), decrypt: { ciphertext in
                    guard ciphertext == wrappedKey else { throw FixtureError.invalid }
                    return key
                })
        }
        let authentication = OppoAuthentication(dependencies: dependencies)
        let capabilities = OppoTransportCapabilities(protocolVersion: 5, maxFrameSize: 20,
            maxTransmissionUnit: 20, interval: 10, supportProtocol: encrypted ? 3 : 0,
            commandID: 0x81, controlFlags: 0, frameCount: 1, frameShape: "SINGLE_FRAME",
            crcValidation: "CRC16_LE_VERIFIED", encodedFieldNumbers: [1, 2, 3, 4, 5])
        let nonce = try authCommand(authentication.start(capabilities: capabilities))
        _ = authentication.didSubmit(token: nonce.token, streamOffset: decoder.diagnostics.receivedByteCount)
        XCTAssertTrue(authentication.writeCompleted(token: nonce.token, succeeded: true).isEmpty)
        let nonceReply = try authReply(command: 0x98,
            body: OppoProtobufWriter.encode([1: .varint(watchNonce)]), decoder: &decoder)
        let identity = try authCommand(authentication.receive(nonceReply))
        _ = authentication.didSubmit(token: identity.token, streamOffset: decoder.diagnostics.receivedByteCount)
        XCTAssertTrue(authentication.writeCompleted(token: identity.token, succeeded: true).isEmpty)
        let identityKey = OppoIdentityCrypto.deriveKey(clientNonce: clientNonce, watchNonce: watchNonce)
        let proof = try OppoIdentityCrypto.encryptIdentity(plaintext: Data(challenge.map { ~$0 }), key: identityKey)
        let identityReply = try authReply(command: 0x99,
            body: OppoProtobufWriter.encode([2: .bytes(proof)]), decoder: &decoder)
        var actions = authentication.receive(identityReply)
        if encrypted {
            let rsa = try authCommand(actions)
            _ = authentication.didSubmit(token: rsa.token, streamOffset: decoder.diagnostics.receivedByteCount)
            XCTAssertTrue(authentication.writeCompleted(token: rsa.token, succeeded: true).isEmpty)
            let plainProof = Data([0x42, 0x17, 0x29, 0x39])
            let encryptedProof = try OppoSessionCrypto.encryptEnvelope(plaintext: plainProof, key32: key, iv16: iv)
            let reply = try authReply(command: 0xa5, body: OppoProtobufWriter.encode([
                1: .bytes(wrappedKey), 2: .bytes(iv), 3: .bytes(plainProof),
                4: .bytes(encryptedProof), 5: .varint(0)
            ]), decoder: &decoder)
            let confirmation = try authCommand(authentication.receive(reply))
            XCTAssertNil(authentication.takeBusinessSession())
            _ = authentication.didSubmit(token: confirmation.token, streamOffset: decoder.diagnostics.receivedByteCount)
            actions = authentication.writeCompleted(token: confirmation.token, succeeded: true)
        }
        let completion = try XCTUnwrap(actions.compactMap { action -> OppoAuthentication.Completion? in
            if case .completed(let value) = action { return value }
            return nil
        }.first)
        XCTAssertEqual(completion.encryptedTransport, encrypted)
        let session = try XCTUnwrap(authentication.takeBusinessSession())
        XCTAssertNil(authentication.takeBusinessSession())
        return session
    }

    private func transmit(_ command: OppoSetup.Command, session: OppoBusinessSession,
                          decoder: inout OppoTransportDecoder) throws -> OppoWireMessage {
        let payload = Data([command.serviceID, command.commandID]) + command.protobuf
        let frames = try OppoProtocol.encodePayload(session.sealPayload(payload),
            encrypted: session.isEncrypted, maximumFrameLength: 20)
        return try open(singleEvent(feed(frames.reduce(Data(), +), decoder: &decoder)), session: session)
    }

    private func authReply(command: UInt8, body: Data,
                           decoder: inout OppoTransportDecoder) throws -> OppoWireMessage {
        let frames = try OppoProtocol.encode(service: 1, command: command, protobuf: body, maximumFrameLength: 20)
        guard case .message(let message) = try singleEvent(feed(frames.reduce(Data(), +), decoder: &decoder)) else {
            XCTFail("Expected a clear authentication reply")
            throw FixtureError.invalid
        }
        return message
    }

    private func open(_ event: OppoDecodeEvent, session: OppoBusinessSession) throws -> OppoWireMessage {
        switch event {
        case .message(let message):
            _ = try session.openPayload(Data([message.serviceID, message.commandID]) + message.protobuf, encrypted: false)
            return message
        case .encryptedMessage(let message):
            let bytes = Array(try session.openPayload(message.payload, encrypted: true))
            return OppoWireMessage(serviceID: bytes[0], commandID: bytes[1], protobuf: Data(bytes.dropFirst(2)),
                streamOffset: message.streamOffset, controlFlags: message.controlFlags,
                frameCount: message.frameCount, frameShape: message.frameShape, crcValidation: message.crcValidation)
        default:
            XCTFail("Expected a complete business payload")
            throw FixtureError.invalid
        }
    }

    /// Notifications can split both TL headers and encrypted fragments.
    private func feed(_ bytes: Data, decoder: inout OppoTransportDecoder) -> [OppoDecodeEvent] {
        var events: [OppoDecodeEvent] = []
        for byte in bytes { events += decoder.append(Data([byte])) }
        return events
    }

    private func singleEvent(_ events: [OppoDecodeEvent]) throws -> OppoDecodeEvent {
        XCTAssertEqual(events.count, 1)
        return try XCTUnwrap(events.first)
    }

    private func setupCommand(_ actions: [OppoSetup.Action]) throws -> OppoSetup.Command {
        try XCTUnwrap(actions.compactMap { action -> OppoSetup.Command? in
            if case .send(let command) = action { return command }
            return nil
        }.first)
    }

    private func authCommand(_ actions: [OppoAuthentication.Action]) throws -> OppoAuthentication.Command {
        try XCTUnwrap(actions.compactMap { action -> OppoAuthentication.Command? in
            if case .send(let command) = action { return command }
            return nil
        }.first)
    }

    private enum FixtureError: Error { case invalid }
}
