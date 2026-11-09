import XCTest
@testable import WatchLink

final class OppoAuthenticationTests: XCTestCase {
    // Deterministic state-machine fixtures, never recordings from a watch.
    // Primitive algorithms have independent coverage in OppoCryptoTests.
    private let clientNonce: UInt64 = 1_794_200_000_123
    private let watchNonce: UInt64 = 1_794_200_000_456
    private let challenge = Data([0x12, 0x34, 0x56, 0x78])
    private let identityKey = Data(repeating: 0x11, count: 16)
    private let identityRequest = Data([12]) + Data(repeating: 0x22, count: 16)
    private let identityReply = Data([12]) + Data(repeating: 0x33, count: 16)
    private let encryptedSessionKey = Data(repeating: 0x44, count: 256)
    private let sessionKey = Data(repeating: 0x55, count: 32)
    private let sessionIV = Data(repeating: 0x66, count: 16)
    private let sessionPlaintext = Data([0x87, 0x65, 0x43, 0x21])
    private let sessionEnvelope = Data([12]) + Data(repeating: 0x77, count: 16)

    func testUnsupportedVersionsCannotSendOrPretendToUseAnotherDeviceType() throws {
        for version in [0, 1, 2, 6] {
            var dependencies = fakeDependencies()
            dependencies.makeNonce = { XCTFail("Unsupported versions must not begin a handshake"); return 1 }
            let engine = OppoAuthentication(dependencies: dependencies)
            let failure = try failed(engine.start(capabilities: capabilities(version: version)))
            XCTAssertEqual(failure.code, "UNSUPPORTED_PROTOCOL_VERSION")
            XCTAssertEqual(engine.phase, .failed)
            XCTAssertFalse(engine.identityVerified)
            XCTAssertFalse(engine.keyExchangeVerified)
            XCTAssertTrue(engine.start(capabilities: capabilities()).isEmpty)
        }
    }

    func testRealCapabilitiesBeginNonceCommandAndPreserveUInt64Width() throws {
        let nonce = UInt64.max - 7
        var dependencies = fakeDependencies()
        dependencies.makeNonce = { nonce }
        let engine = OppoAuthentication(dependencies: dependencies)
        let command = try sent(engine.start(capabilities: capabilities(version: 3, support: 0)))
        XCTAssertEqual(command.serviceID, 1)
        XCTAssertEqual(command.commandID, 24)
        XCTAssertEqual(command.phase, .nonce)
        let fields = try OppoProtobufReader(command.protobuf, fields: [1: .varint])
        XCTAssertEqual(try fields.uint64(1), nonce)
        XCTAssertTrue(engine.start(capabilities: capabilities()).isEmpty)
    }

    func testEarlyNonceReplyWaitsForWholeMessageATTSuccess() throws {
        let engine = makeEngine()
        let request = try sent(engine.start(capabilities: capabilities()))
        XCTAssertTrue(engine.didSubmit(token: request.token, streamOffset: 100).isEmpty)
        XCTAssertTrue(engine.receive(try nonceMessage(offset: 100)).isEmpty)
        XCTAssertEqual(engine.phase, .nonce)
        XCTAssertEqual(engine.diagnostics.bufferedReplyCount, 1)
        let challengeRequest = try sent(engine.writeCompleted(token: request.token, succeeded: true))
        XCTAssertEqual(challengeRequest.commandID, 25)
        XCTAssertEqual(engine.phase, .identity)
        XCTAssertFalse(engine.identityVerified)
    }

    func testMessageBeforePhysicalSubmissionIsIgnoredAndNotReplayedLater() throws {
        let engine = makeEngine()
        let request = try sent(engine.start(capabilities: capabilities()))
        XCTAssertTrue(engine.receive(try nonceMessage(offset: 10)).isEmpty)
        XCTAssertEqual(engine.diagnostics.preSubmissionMessageCount, 1)
        XCTAssertTrue(engine.didSubmit(token: request.token, streamOffset: 100).isEmpty)
        XCTAssertTrue(engine.writeCompleted(token: request.token, succeeded: true).isEmpty)
        XCTAssertEqual(engine.phase, .nonce)
        XCTAssertEqual(try sent(engine.receive(try nonceMessage(offset: 100))).commandID, 25)
    }

    func testFirstFragmentBeforeStageBoundaryCannotCompleteCurrentStage() throws {
        let engine = makeEngine()
        let request = try sent(engine.start(capabilities: capabilities()))
        _ = engine.didSubmit(token: request.token, streamOffset: 100)
        _ = engine.writeCompleted(token: request.token, succeeded: true)
        let stale = try nonceMessage(offset: 99, frames: 3)
        XCTAssertTrue(engine.receive(stale).isEmpty)
        XCTAssertEqual(engine.diagnostics.staleMessageCount, 1)
        XCTAssertEqual(engine.phase, .nonce)
        XCTAssertEqual(try sent(engine.receive(try nonceMessage(offset: 100))).commandID, 25)
    }

    func testRepeatedSubmissionAndWrongTokensCannotMoveStageBoundary() throws {
        let engine = makeEngine()
        let request = try sent(engine.start(capabilities: capabilities()))
        _ = engine.didSubmit(token: request.token, streamOffset: 100)
        _ = engine.didSubmit(token: request.token, streamOffset: 200)
        XCTAssertTrue(engine.writeCompleted(token: request.token + 100, succeeded: false).isEmpty)
        _ = engine.writeCompleted(token: request.token, succeeded: true)
        let next = try sent(engine.receive(try nonceMessage(offset: 150)))
        XCTAssertEqual(next.commandID, 25)
        XCTAssertTrue(engine.writeCompleted(token: request.token, succeeded: false).isEmpty)
        XCTAssertEqual(engine.phase, .identity)
    }

    func testRequestEchoAndSemanticNonceEchoDoNotAdvance() throws {
        let engine = makeEngine()
        let request = try sent(engine.start(capabilities: capabilities()))
        _ = engine.didSubmit(token: request.token, streamOffset: 100)
        _ = engine.writeCompleted(token: request.token, succeeded: true)
        XCTAssertTrue(engine.receive(message(command: 0x98, body: request.protobuf, offset: 100)).isEmpty)
        // Unknown protobuf fields cannot disguise an echoed nonce.
        let body = try OppoProtobufWriter.encode([1: .varint(clientNonce), 9: .varint(1)])
        XCTAssertTrue(engine.receive(message(command: 24, body: body, offset: 120)).isEmpty)
        XCTAssertEqual(engine.diagnostics.echoMessageCount, 2)
        XCTAssertEqual(engine.phase, .nonce)
        XCTAssertEqual(try sent(engine.receive(try nonceMessage(offset: 140))).commandID, 25)
    }

    func testExplicitZeroWatchNonceIsAllowedButMissingNonceFails() throws {
        let engine = makeEngine()
        let request = try sent(engine.start(capabilities: capabilities()))
        _ = engine.didSubmit(token: request.token, streamOffset: 0)
        _ = engine.writeCompleted(token: request.token, succeeded: true)
        XCTAssertEqual(try sent(engine.receive(try nonceMessage(value: 0, offset: 0))).commandID, 25)

        let missing = makeEngine()
        let missingRequest = try sent(missing.start(capabilities: capabilities()))
        _ = missing.didSubmit(token: missingRequest.token, streamOffset: 0)
        _ = missing.writeCompleted(token: missingRequest.token, succeeded: true)
        XCTAssertEqual(try failed(missing.receive(message(command: 24, body: Data(), offset: 0))).code,
                       "MISSING_WATCH_NONCE")
    }

    func testSemanticNonceEchoCannotOccupyEarlyReplyBuffer() throws {
        let engine = makeEngine()
        let request = try sent(engine.start(capabilities: capabilities()))
        _ = engine.didSubmit(token: request.token, streamOffset: 100)
        let echo = try OppoProtobufWriter.encode([1: .varint(clientNonce), 9: .varint(1)])
        XCTAssertTrue(engine.receive(message(command: 24, body: echo, offset: 100)).isEmpty)
        XCTAssertTrue(engine.receive(try nonceMessage(offset: 120)).isEmpty)
        XCTAssertEqual(engine.diagnostics.echoMessageCount, 1)
        XCTAssertEqual(engine.diagnostics.bufferedReplyCount, 1)
        XCTAssertEqual(engine.diagnostics.duplicateReplyCount, 0)
        XCTAssertEqual(try sent(engine.writeCompleted(token: request.token, succeeded: true)).commandID, 25)
    }

    func testIdentityProofBeforeATTSuccessCannotCompleteUnencryptedHandshake() throws {
        let engine = makeEngine()
        let request = try reachIdentity(engine, support: 0)
        _ = engine.didSubmit(token: request.token, streamOffset: 200)
        XCTAssertTrue(engine.receive(try identityMessage(offset: 200)).isEmpty)
        XCTAssertFalse(engine.identityVerified)
        XCTAssertEqual(engine.phase, .identity)
        let result = try completed(engine.writeCompleted(token: request.token, succeeded: true))
        XCTAssertFalse(result.encryptedTransport)
        XCTAssertEqual(result.protocolVersion, 5)
        XCTAssertTrue(engine.identityVerified)
        XCTAssertFalse(engine.keyExchangeVerified)
        XCTAssertEqual(engine.phase, .completed)
        XCTAssertTrue(engine.timeout().isEmpty)
        XCTAssertTrue(engine.writeCompleted(token: request.token, succeeded: false).isEmpty)
    }

    func testFailedWriteDiscardsBufferedProofAndCannotBeRevivedByLateSuccess() throws {
        let engine = makeEngine()
        let request = try reachIdentity(engine, support: 0)
        _ = engine.didSubmit(token: request.token, streamOffset: 200)
        _ = engine.receive(try identityMessage(offset: 200))
        let failure = try failed(engine.writeCompleted(token: request.token, succeeded: false))
        XCTAssertEqual(failure.phase, .identity)
        XCTAssertEqual(failure.code, "ATT_WRITE_FAILED")
        XCTAssertFalse(engine.identityVerified)
        XCTAssertEqual(engine.phase, .failed)
        XCTAssertTrue(engine.writeCompleted(token: request.token, succeeded: true).isEmpty)
        XCTAssertTrue(engine.receive(try identityMessage(offset: 220)).isEmpty)
    }

    func testWrongIdentityChallengeCannotReachRSAOrCompletion() throws {
        let engine = makeEngine()
        let request = try reachIdentity(engine)
        _ = engine.didSubmit(token: request.token, streamOffset: 200)
        _ = engine.writeCompleted(token: request.token, succeeded: true)
        let body = try OppoProtobufWriter.encode([2: .bytes(Data(repeating: 0xff, count: 17))])
        let failure = try failed(engine.receive(message(command: 25, body: body, offset: 200)))
        XCTAssertEqual(failure.code, "IDENTITY_PROOF_MISMATCH")
        XCTAssertFalse(engine.identityVerified)
        XCTAssertFalse(engine.keyExchangeVerified)
    }

    func testEncryptedHandshakeWaitsForRSAWriteAndFinalConfirmationWrite() throws {
        let engine = makeEngine()
        let rsa = try reachRSA(engine)
        let rsaFields = try OppoProtobufReader(rsa.protobuf, fields: [1: .varint, 2: .bytes, 3: .bytes])
        XCTAssertEqual(try rsaFields.uint32(1), 2048)
        XCTAssertEqual(try rsaFields.bytes(2)?.count, 256)
        XCTAssertEqual(try rsaFields.bytes(3), Data([1, 0, 1]))
        _ = engine.didSubmit(token: rsa.token, streamOffset: 300)
        // There is no separate reply to RSAConsult (36).
        XCTAssertTrue(engine.receive(message(command: 0xa4, body: rsa.protobuf, offset: 300)).isEmpty)
        XCTAssertTrue(engine.receive(try sessionMessage(offset: 320)).isEmpty)
        XCTAssertFalse(engine.keyExchangeVerified)
        let confirmation = try sent(engine.writeCompleted(token: rsa.token, succeeded: true))
        XCTAssertEqual(confirmation.commandID, 37)
        XCTAssertEqual(confirmation.protobuf, Data([0x28, 0x01]))
        XCTAssertTrue(engine.identityVerified)
        XCTAssertTrue(engine.keyExchangeVerified)
        XCTAssertEqual(engine.phase, .sessionConfirm)
        XCTAssertTrue(engine.receive(message(command: 37, body: confirmation.protobuf, offset: 400)).isEmpty)
        _ = engine.didSubmit(token: confirmation.token, streamOffset: 400)
        let result = try completed(engine.writeCompleted(token: confirmation.token, succeeded: true))
        XCTAssertTrue(result.encryptedTransport)
        XCTAssertEqual(engine.phase, .completed)
        XCTAssertTrue(engine.writeCompleted(token: confirmation.token, succeeded: true).isEmpty)
    }

    func testFinalConfirmationWriteFailureRetainsVerifiedFactsWithoutCompletion() throws {
        let engine = makeEngine()
        let confirmation = try reachConfirmation(engine)
        _ = engine.didSubmit(token: confirmation.token, streamOffset: 400)
        let failure = try failed(engine.writeCompleted(token: confirmation.token, succeeded: false))
        XCTAssertEqual(failure.phase, .sessionConfirm)
        XCTAssertEqual(failure.code, "ATT_WRITE_FAILED")
        XCTAssertEqual(engine.phase, .failed)
        XCTAssertTrue(engine.identityVerified)
        XCTAssertTrue(engine.keyExchangeVerified)
        XCTAssertTrue(engine.writeCompleted(token: confirmation.token, succeeded: true).isEmpty)
    }

    func testSessionProofMismatchCannotSendConfirmation() throws {
        var dependencies = fakeDependencies()
        dependencies.decryptSessionEnvelope = { _, _, _ in Data([0, 0, 0, 0]) }
        let engine = OppoAuthentication(dependencies: dependencies)
        let rsa = try reachRSA(engine)
        _ = engine.didSubmit(token: rsa.token, streamOffset: 300)
        _ = engine.writeCompleted(token: rsa.token, succeeded: true)
        let failure = try failed(engine.receive(try sessionMessage(offset: 300)))
        XCTAssertEqual(failure.code, "SESSION_PROOF_MISMATCH")
        XCTAssertTrue(engine.identityVerified)
        XCTAssertFalse(engine.keyExchangeVerified)
    }

    func testStateOnlyAESReplyCannotStandInForKeyProof() throws {
        let engine = makeEngine()
        let rsa = try reachRSA(engine)
        _ = engine.didSubmit(token: rsa.token, streamOffset: 300)
        _ = engine.writeCompleted(token: rsa.token, succeeded: true)
        let stateOnly = try OppoProtobufWriter.encode([5: .varint(1)])
        let failure = try failed(engine.receive(message(command: 37, body: stateOnly, offset: 300)))
        XCTAssertEqual(failure.code, "INVALID_SESSION_KEY_FIELDS")
        XCTAssertFalse(engine.keyExchangeVerified)
    }

    func testOldAESReplyAndEarlyIdentityReplyCannotCrossTheirStageBoundary() throws {
        let engine = makeEngine()
        let identity = try reachIdentity(engine)
        // A valid-looking identity reply in the queue is not sent-request evidence.
        XCTAssertTrue(engine.receive(try identityMessage(offset: 190)).isEmpty)
        _ = engine.didSubmit(token: identity.token, streamOffset: 200)
        _ = engine.writeCompleted(token: identity.token, succeeded: true)
        XCTAssertTrue(engine.receive(try identityMessage(offset: 199)).isEmpty)
        let rsa = try sent(engine.receive(try identityMessage(offset: 200)))
        XCTAssertTrue(engine.receive(try sessionMessage(offset: 290)).isEmpty)
        _ = engine.didSubmit(token: rsa.token, streamOffset: 300)
        _ = engine.writeCompleted(token: rsa.token, succeeded: true)
        XCTAssertTrue(engine.receive(try sessionMessage(offset: 299)).isEmpty)
        XCTAssertEqual(engine.phase, .sessionKeys)
        XCTAssertEqual(try sent(engine.receive(try sessionMessage(offset: 300))).commandID, 37)
        XCTAssertEqual(engine.diagnostics.preSubmissionMessageCount, 2)
        XCTAssertEqual(engine.diagnostics.staleMessageCount, 2)
    }

    func testSupportMaskControlsOnlyVerifiedEncryptionBranch() throws {
        for support in [UInt32(0), 4, 8] {
            let engine = makeEngine()
            let request = try reachIdentity(engine, support: support)
            _ = engine.didSubmit(token: request.token, streamOffset: 200)
            _ = engine.writeCompleted(token: request.token, succeeded: true)
            XCTAssertFalse(try completed(engine.receive(try identityMessage(offset: 200))).encryptedTransport)
        }
        for support in [UInt32(1), 2, 3, 5] {
            let engine = makeEngine()
            XCTAssertEqual(try reachRSA(engine, support: support).commandID, 36)
        }
    }

    func testTimeoutAndCancellationReleasePrivateKeyAndIgnoreFurtherCallbacks() throws {
        for cancel in [false, true] {
            let witness = PrivateKeyWitness()
            var dependencies = fakeDependencies()
            let key = sessionKey
            dependencies.makeRSA = {
                let lifetime = PrivateKeyLifetime()
                witness.value = lifetime
                return OppoAuthentication.RSAContext(
                    modulus: Data(repeating: 0x80, count: 256), exponent: Data([1, 0, 1]),
                    decrypt: { _ in withExtendedLifetime(lifetime) { key } })
            }
            let engine = OppoAuthentication(dependencies: dependencies)
            let rsa = try reachRSA(engine)
            XCTAssertNotNil(witness.value)
            _ = engine.didSubmit(token: rsa.token, streamOffset: 300)
            if cancel {
                engine.cancel()
                XCTAssertEqual(engine.phase, .cancelled)
            } else {
                XCTAssertEqual(try failed(engine.timeout()).code, "AUTHENTICATION_TIMEOUT")
                XCTAssertEqual(engine.phase, .failed)
            }
            XCTAssertNil(witness.value)
            XCTAssertTrue(engine.identityVerified)
            XCTAssertFalse(engine.keyExchangeVerified)
            XCTAssertTrue(engine.receive(try sessionMessage(offset: 300)).isEmpty)
            XCTAssertTrue(engine.writeCompleted(token: rsa.token, succeeded: true).isEmpty)
            XCTAssertTrue(engine.start(capabilities: capabilities()).isEmpty)
        }
    }

    func testRSASetupFailureStillRecordsSuccessfulIdentityProof() throws {
        var dependencies = fakeDependencies()
        dependencies.makeRSA = { throw FixtureError.failed }
        let engine = OppoAuthentication(dependencies: dependencies)
        let request = try reachIdentity(engine)
        _ = engine.didSubmit(token: request.token, streamOffset: 200)
        _ = engine.writeCompleted(token: request.token, succeeded: true)
        let failure = try failed(engine.receive(try identityMessage(offset: 200)))
        XCTAssertEqual(failure.code, "RSA_SETUP_FAILED")
        XCTAssertTrue(engine.identityVerified)
        XCTAssertFalse(engine.keyExchangeVerified)
    }

    func testOtherCommandsEncryptedControlsAndDuplicateRepliesDoNotAdvance() throws {
        let engine = makeEngine()
        let request = try sent(engine.start(capabilities: capabilities()))
        _ = engine.didSubmit(token: request.token, streamOffset: 100)
        let nonce = try nonceMessage(offset: 100)
        XCTAssertTrue(engine.receive(message(service: 2, command: 24, body: nonce.protobuf, offset: 100)).isEmpty)
        XCTAssertTrue(engine.receive(message(command: 25, body: nonce.protobuf, offset: 100)).isEmpty)
        XCTAssertTrue(engine.receive(message(command: 24, body: nonce.protobuf, offset: 100, control: 0x40)).isEmpty)
        XCTAssertTrue(engine.receive(nonce).isEmpty)
        XCTAssertTrue(engine.receive(nonce).isEmpty)
        XCTAssertEqual(engine.diagnostics.duplicateReplyCount, 1)
        XCTAssertEqual(engine.diagnostics.bufferedReplyCount, 1)
        XCTAssertEqual(try sent(engine.writeCompleted(token: request.token, succeeded: true)).commandID, 25)
    }

    func testLiveIdentityPrimitivesVerifyComplementOnlyAfterActualWriteCompletion() throws {
        var dependencies = OppoAuthentication.Dependencies.live
        let nonce = clientNonce
        let random = challenge
        dependencies.makeNonce = { nonce }
        dependencies.randomChallenge = { random }
        let engine = OppoAuthentication(dependencies: dependencies)
        let request = try reachIdentity(engine, support: 0)
        let fields = try OppoProtobufReader(request.protobuf, fields: [1: .bytes, 2: .bytes])
        XCTAssertEqual(try fields.bytes(1), challenge)
        let key = OppoIdentityCrypto.deriveKey(clientNonce: clientNonce, watchNonce: watchNonce)
        let incomingCiphertext = try OppoIdentityCrypto.encryptIdentity(
            plaintext: Data(challenge.map { ~$0 }), key: key)
        let reply = try OppoProtobufWriter.encode([2: .bytes(incomingCiphertext)])
        _ = engine.didSubmit(token: request.token, streamOffset: 200)
        XCTAssertTrue(engine.receive(message(command: 0x99, body: reply, offset: 200)).isEmpty)
        XCTAssertEqual(engine.phase, .identity)
        XCTAssertFalse(try completed(engine.writeCompleted(token: request.token, succeeded: true)).encryptedTransport)
        XCTAssertTrue(engine.identityVerified)
    }

    func testClearBusinessSessionTransfersOnceAfterIdentityAndWholeWrite() throws {
        let engine = makeEngine()
        XCTAssertNil(engine.takeBusinessSession())
        let request = try reachIdentity(engine, support: 0)
        XCTAssertNil(engine.takeBusinessSession())
        _ = engine.didSubmit(token: request.token, streamOffset: 200)
        _ = engine.receive(try identityMessage(offset: 200))
        XCTAssertNil(engine.takeBusinessSession())
        _ = try completed(engine.writeCompleted(token: request.token, succeeded: true))
        let session = try XCTUnwrap(engine.takeBusinessSession())
        XCTAssertFalse(session.isEncrypted)
        XCTAssertNil(engine.takeBusinessSession())
        let payload = Data([11, 7, 8, 1, 16, 2])
        XCTAssertEqual(try session.sealPayload(payload), payload)
        // After transfer, retiring the handshake must not destroy the owner's
        // business session. Connection teardown invalidates it separately.
        engine.cancel()
        XCTAssertEqual(try session.openPayload(payload, encrypted: false), payload)
        session.invalidate()
        XCTAssertThrowsError(try session.sealPayload(payload))
    }

    func testEncryptedBusinessSessionTransfersOnlyAfterFinalAcknowledgement() throws {
        let engine = makeEngine()
        let rsa = try reachRSA(engine)
        XCTAssertNil(engine.takeBusinessSession())
        _ = engine.didSubmit(token: rsa.token, streamOffset: 300)
        _ = engine.receive(try sessionMessage(offset: 300))
        XCTAssertNil(engine.takeBusinessSession())
        let confirmation = try sent(engine.writeCompleted(token: rsa.token, succeeded: true))
        XCTAssertTrue(engine.keyExchangeVerified)
        XCTAssertNil(engine.takeBusinessSession())
        _ = engine.didSubmit(token: confirmation.token, streamOffset: 400)
        XCTAssertNil(engine.takeBusinessSession())
        _ = try completed(engine.writeCompleted(token: confirmation.token, succeeded: true))
        let session = try XCTUnwrap(engine.takeBusinessSession())
        XCTAssertTrue(session.isEncrypted)
        XCTAssertNil(engine.takeBusinessSession())
        // Independent AES/CTR fixtures for fakeDependencies' synthetic key/IV.
        XCTAssertEqual(try session.sealPayload(Data([11, 11])),
                       hex("0e973aa86bb952d1d7efeac0e3e790ddd9"))
        XCTAssertEqual(try session.openPayload(hex("0c973aa06bb952d1d7efeac0e3e790ddd9"), encrypted: true),
                       Data([11, 11, 8, 0]))
        XCTAssertThrowsError(try session.openPayload(Data([11, 11, 8, 0]), encrypted: false))
    }

    func testFailedTimedOutOrCancelledFinalWriteCannotExposeBusinessSession() throws {
        for terminal in 0..<3 {
            let engine = makeEngine()
            let confirmation = try reachConfirmation(engine)
            XCTAssertTrue(engine.keyExchangeVerified)
            XCTAssertNil(engine.takeBusinessSession())
            _ = engine.didSubmit(token: confirmation.token, streamOffset: 400)
            switch terminal {
            case 0: _ = try failed(engine.writeCompleted(token: confirmation.token, succeeded: false))
            case 1: _ = try failed(engine.timeout())
            default: engine.cancel()
            }
            XCTAssertNil(engine.takeBusinessSession())
            XCTAssertTrue(engine.writeCompleted(token: confirmation.token, succeeded: true).isEmpty)
            XCTAssertNil(engine.takeBusinessSession())
        }
    }

    func testCancellingCompletedUntakenSessionPreventsLaterTransfer() throws {
        for encrypted in [false, true] {
            let engine = makeEngine()
            if encrypted {
                let confirmation = try reachConfirmation(engine)
                _ = engine.didSubmit(token: confirmation.token, streamOffset: 400)
                _ = try completed(engine.writeCompleted(token: confirmation.token, succeeded: true))
            } else {
                let identity = try reachIdentity(engine, support: 0)
                _ = engine.didSubmit(token: identity.token, streamOffset: 200)
                _ = engine.writeCompleted(token: identity.token, succeeded: true)
                _ = try completed(engine.receive(try identityMessage(offset: 200)))
            }
            engine.cancel()
            XCTAssertNil(engine.takeBusinessSession())
            XCTAssertEqual(engine.phase, .cancelled)
        }
    }

    func testTransferredSessionOutlivesRetiredAuthenticationEngine() throws {
        var engine: OppoAuthentication? = makeEngine()
        weak var witness = engine
        let confirmation = try reachConfirmation(try XCTUnwrap(engine))
        _ = engine?.didSubmit(token: confirmation.token, streamOffset: 400)
        _ = try completed(try XCTUnwrap(engine).writeCompleted(token: confirmation.token, succeeded: true))
        let session = try XCTUnwrap(engine?.takeBusinessSession())
        engine = nil
        XCTAssertNil(witness)
        XCTAssertEqual(try session.sealPayload(Data([11, 11])),
                       hex("0e973aa86bb952d1d7efeac0e3e790ddd9"))
        session.invalidate()
        XCTAssertThrowsError(try session.sealPayload(Data([11, 11])))
    }

    private func hex(_ value: String) -> Data {
        let characters = Array(value)
        precondition(characters.count % 2 == 0)
        return Data(stride(from: 0, to: characters.count, by: 2).map {
            UInt8(String(characters[$0...($0 + 1)]), radix: 16)!
        })
    }

    private func makeEngine() -> OppoAuthentication {
        OppoAuthentication(dependencies: fakeDependencies())
    }

    private func fakeDependencies() -> OppoAuthentication.Dependencies {
        let nonce = clientNonce
        let random = challenge
        let derivedKey = identityKey
        let outgoing = identityRequest
        let validReply = identityReply
        let key = sessionKey
        let iv = sessionIV
        let proof = sessionPlaintext
        let envelope = sessionEnvelope
        return OppoAuthentication.Dependencies(
            makeNonce: { nonce }, randomChallenge: { random },
            deriveIdentityKey: { _, _ in derivedKey }, encryptIdentity: { _, _ in outgoing },
            validateIdentityReply: { $0 == random && $1 == validReply && $2 == derivedKey },
            makeRSA: {
                OppoAuthentication.RSAContext(modulus: Data(repeating: 0x80, count: 256),
                                              exponent: Data([1, 0, 1]), decrypt: { _ in key })
            },
            decryptSessionEnvelope: {
                guard $0 == envelope, $1 == key, $2 == iv else { throw FixtureError.failed }
                return proof
            })
    }

    private func reachIdentity(_ engine: OppoAuthentication, support: UInt32 = 3) throws -> OppoAuthentication.Command {
        let nonce = try sent(engine.start(capabilities: capabilities(support: support)))
        _ = engine.didSubmit(token: nonce.token, streamOffset: 100)
        XCTAssertTrue(engine.writeCompleted(token: nonce.token, succeeded: true).isEmpty)
        return try sent(engine.receive(try nonceMessage(offset: 100)))
    }

    private func reachRSA(_ engine: OppoAuthentication, support: UInt32 = 3) throws -> OppoAuthentication.Command {
        let identity = try reachIdentity(engine, support: support)
        _ = engine.didSubmit(token: identity.token, streamOffset: 200)
        XCTAssertTrue(engine.writeCompleted(token: identity.token, succeeded: true).isEmpty)
        let request = try sent(engine.receive(try identityMessage(offset: 200)))
        XCTAssertEqual(request.commandID, 36)
        return request
    }

    private func reachConfirmation(_ engine: OppoAuthentication) throws -> OppoAuthentication.Command {
        let rsa = try reachRSA(engine)
        _ = engine.didSubmit(token: rsa.token, streamOffset: 300)
        XCTAssertTrue(engine.writeCompleted(token: rsa.token, succeeded: true).isEmpty)
        return try sent(engine.receive(try sessionMessage(offset: 300)))
    }

    private func capabilities(version: Int = 5, support: UInt32 = 3) -> OppoTransportCapabilities {
        OppoTransportCapabilities(protocolVersion: version, maxFrameSize: 20, maxTransmissionUnit: 20,
                                  interval: 10, supportProtocol: support, commandID: 0x81,
                                  controlFlags: 0, frameCount: 1, frameShape: "SINGLE_FRAME",
                                  crcValidation: "CRC16_LE_VERIFIED", encodedFieldNumbers: [1, 2, 3, 4, 5])
    }

    private func nonceMessage(value: UInt64? = nil, offset: Int, frames: Int = 1) throws -> OppoWireMessage {
        message(command: 0x98, body: try OppoProtobufWriter.encode([1: .varint(value ?? watchNonce)]),
                offset: offset, frames: frames)
    }

    private func identityMessage(offset: Int) throws -> OppoWireMessage {
        message(command: 0x99, body: try OppoProtobufWriter.encode([2: .bytes(identityReply)]), offset: offset)
    }

    private func sessionMessage(offset: Int) throws -> OppoWireMessage {
        message(command: 0xa5, body: try OppoProtobufWriter.encode([
            1: .bytes(encryptedSessionKey), 2: .bytes(sessionIV), 3: .bytes(sessionPlaintext),
            4: .bytes(sessionEnvelope), 5: .varint(0)
        ]), offset: offset)
    }

    private func message(service: UInt8 = 1, command: UInt8, body: Data, offset: Int,
                         frames: Int = 1, control: UInt16 = 0) -> OppoWireMessage {
        OppoWireMessage(serviceID: service, commandID: command, protobuf: body, streamOffset: offset,
                        controlFlags: control, frameCount: frames,
                        frameShape: frames == 1 ? "SINGLE_FRAME" : "REASSEMBLED_FRAGMENTS",
                        crcValidation: "CRC16_LE_VERIFIED")
    }

    private func sent(_ actions: [OppoAuthentication.Action], file: StaticString = #filePath,
                      line: UInt = #line) throws -> OppoAuthentication.Command {
        XCTAssertEqual(actions.count, 1, file: file, line: line)
        let action = try XCTUnwrap(actions.first, file: file, line: line)
        guard case .send(let command) = action else {
            XCTFail("Expected an outgoing authentication command", file: file, line: line)
            throw FixtureError.failed
        }
        return command
    }

    private func failed(_ actions: [OppoAuthentication.Action], file: StaticString = #filePath,
                        line: UInt = #line) throws -> OppoAuthentication.Failure {
        XCTAssertEqual(actions.count, 1, file: file, line: line)
        let action = try XCTUnwrap(actions.first, file: file, line: line)
        guard case .failed(let failure) = action else {
            XCTFail("Expected authentication failure", file: file, line: line)
            throw FixtureError.failed
        }
        return failure
    }

    private func completed(_ actions: [OppoAuthentication.Action], file: StaticString = #filePath,
                           line: UInt = #line) throws -> OppoAuthentication.Completion {
        XCTAssertEqual(actions.count, 1, file: file, line: line)
        let action = try XCTUnwrap(actions.first, file: file, line: line)
        guard case .completed(let completion) = action else {
            XCTFail("Expected completed transport authentication", file: file, line: line)
            throw FixtureError.failed
        }
        return completion
    }

    private enum FixtureError: Error { case failed }
    private final class PrivateKeyLifetime {}
    private final class PrivateKeyWitness { weak var value: PrivateKeyLifetime? }
}
