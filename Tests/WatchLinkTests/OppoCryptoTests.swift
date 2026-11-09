import Foundation
import Security
import XCTest
@testable import WatchLink

final class OppoCryptoTests: XCTestCase {
    // These are independent Python/hashlib/cryptography reconstruction fixtures.
    // They are synthetic, public test values, not captured app/watch transcripts.
    func testIdentityKDFMatchesIndependentSyntheticVectors() {
        let vectors: [(UInt64, UInt64, String)] = [
            (0, 0, "dc705fd8a3abe69c58e77495a1074401"),
            (1, 2, "6524dca50f7f7fe28a794acaf5d745ed"),
            (1_700_000_000_000, 1_700_000_000_123, "c407155af90f950c535a5d88e5e03c69"),
            (.max, UInt64(1) << 63, "a3cf0cfe12d6913074e98cd82165b154"),
            (UInt64(1) << 63, .max, "ec2174811b75edac1f29243f9644ae76")
        ]
        for (client, watch, expected) in vectors {
            XCTAssertEqual(OppoIdentityCrypto.deriveKey(clientNonce: client, watchNonce: watch), hex(expected))
        }
    }

    func testIdentityNonceOrderingIsSignificant() {
        XCTAssertNotEqual(OppoIdentityCrypto.deriveKey(clientNonce: 1, watchNonce: 2),
                          OppoIdentityCrypto.deriveKey(clientNonce: 2, watchNonce: 1))
    }

    func testFourByteIdentityRequestAndComplementReply() throws {
        let challenge = hex("01234567")
        let vectors: [(String, String, String)] = [
            ("dc705fd8a3abe69c58e77495a1074401", "0c234329bed97fa618e1cf3f6cf8b5d79a", "0c55c9f120114f3aa9b4c5abecdfa48cf0"),
            ("6524dca50f7f7fe28a794acaf5d745ed", "0ccecc0b7c98a4fa4a7ac16997a1b37f5b", "0c8e474242214d2de8692adf00a7854b44"),
            ("c407155af90f950c535a5d88e5e03c69", "0cf209e4e2e61557cadcc6348b559064ff", "0c6b56b960b58cc87b89f4f87178c374e2")
        ]
        for (keyHex, requestHex, replyHex) in vectors {
            let key = hex(keyHex)
            let request = hex(requestHex)
            XCTAssertEqual(try OppoIdentityCrypto.encryptIdentity(plaintext: challenge, key: key), request)
            XCTAssertEqual(try OppoIdentityCrypto.decryptIdentity(envelope: request, key: key), challenge)
            XCTAssertTrue(try OppoIdentityCrypto.validateIdentityReply(challenge: challenge,
                                                                       encryptedReply: hex(replyHex), key: key))
            XCTAssertFalse(try OppoIdentityCrypto.validateIdentityReply(challenge: challenge,
                                                                        encryptedReply: request, key: key))
        }
    }

    func testIdentityAlignedInputUsesZeroPrefixAndNoExtraBlock() throws {
        // NIST SP 800-38A F.1.1 ECB-AES128, plus the verified vendor prefix.
        // https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38a.pdf
        let key = hex("2b7e151628aed2a6abf7158809cf4f3c")
        let plaintext = hex("6bc1bee22e409f96e93d7e117393172a")
        let envelope = hex("003ad77bb40d7a3660a89ecaf32466ef97")
        XCTAssertEqual(try OppoIdentityCrypto.encryptIdentity(plaintext: plaintext, key: key), envelope)
        XCTAssertEqual(try OppoIdentityCrypto.decryptIdentity(envelope: envelope, key: key), plaintext)
    }

    func testIdentityRejectsMalformedEnvelopeAndNonzeroPadding() throws {
        let key = hex("dc705fd8a3abe69c58e77495a1074401")
        for envelope in [Data(), Data(repeating: 0, count: 16), Data(repeating: 0, count: 18)] {
            assertCryptoError(.invalidEnvelopeLength) {
                _ = try OppoIdentityCrypto.decryptIdentity(envelope: envelope, key: key)
            }
        }
        for prefix in [UInt8(16), 17, 255] {
            var envelope = hex("0c234329bed97fa618e1cf3f6cf8b5d79a")
            envelope[0] = prefix
            assertCryptoError(.invalidPadding) {
                _ = try OppoIdentityCrypto.decryptIdentity(envelope: envelope, key: key)
            }
        }
        // AES-ECB of 01234567 followed by twelve 01 bytes, claiming twelve zeros.
        assertCryptoError(.invalidPadding) {
            _ = try OppoIdentityCrypto.decryptIdentity(envelope: hex("0c24d227b43ad4a93eca85d664a9e43edd"), key: key)
        }
    }

    func testIdentityRejectsInvalidInputsBeforeCrypto() {
        let key = Data(repeating: 0, count: 16)
        assertCryptoError(.invalidIdentityKeyLength) {
            _ = try OppoIdentityCrypto.encryptIdentity(plaintext: Data([1]), key: Data(repeating: 0, count: 32))
        }
        assertCryptoError(.emptyPlaintext) {
            _ = try OppoIdentityCrypto.encryptIdentity(plaintext: Data(), key: key)
        }
        assertCryptoError(.inputTooLarge) {
            _ = try OppoIdentityCrypto.encryptIdentity(plaintext: Data(repeating: 0, count: 65_537), key: key)
        }
        assertCryptoError(.inputTooLarge) {
            _ = try OppoIdentityCrypto.decryptIdentity(envelope: Data(repeating: 0, count: 65_538), key: key)
        }
        assertCryptoError(.invalidChallengeLength) {
            _ = try OppoIdentityCrypto.validateIdentityReply(challenge: Data([1, 2, 3]),
                                                             encryptedReply: Data(), key: key)
        }
    }

    func testIdentityReplyRequiresExactlyFourDecryptedBytes() throws {
        let key = Data(repeating: 0, count: 16)
        let reply = try OppoIdentityCrypto.encryptIdentity(plaintext: Data(repeating: 255, count: 5), key: key)
        XCTAssertFalse(try OppoIdentityCrypto.validateIdentityReply(challenge: Data(repeating: 0, count: 4),
                                                                   encryptedReply: reply, key: key))
    }

    func testChallengeUsesFourSecureRandomBytes() throws {
        // Size is deterministic. Do not assert probabilistic uniqueness or print
        // generated challenge bytes in test failure diagnostics.
        XCTAssertEqual(try OppoIdentityCrypto.randomChallenge().count, 4)
    }

    func testAES256CTRMatchesNISTFourBlockVectorAndRestartsIV() throws {
        // NIST SP 800-38A F.5.5 / F.5.6, with vendor aligned-prefix 00 added.
        let key = hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
        let iv = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let envelope = hex("00"
            + "601ec313775789a5b7a7f504bbf3d228"
            + "f443e3ca4d62b59aca84e990cacaf5c5"
            + "2b0930daa23de94ce87017ba2d84988d"
            + "dfc9c58db67aada613c2dd08457941a6")
        let expected = hex("6bc1bee22e409f96e93d7e117393172a"
            + "ae2d8a571e03ac9c9eb76fac45af8e51"
            + "30c81c46a35ce411e5fbc1191a0a52ef"
            + "f69f2445df4f9b17ad2b417be66c3710")
        XCTAssertEqual(try OppoSessionCrypto.decryptEnvelope(envelope: envelope, key32: key, iv16: iv), expected)
        XCTAssertEqual(try OppoSessionCrypto.decryptEnvelope(envelope: envelope, key32: key, iv16: iv), expected)
        XCTAssertEqual(try OppoSessionCrypto.encryptEnvelope(plaintext: expected, key32: key, iv16: iv), envelope)
        XCTAssertEqual(try OppoSessionCrypto.encryptEnvelope(plaintext: expected, key32: key, iv16: iv), envelope)
    }

    func testAES256CTRFull128BitBigEndianCarry() throws {
        let key = Data((0..<32).map(UInt8.init))
        let expected = Data((0..<48).map(UInt8.init))
        // Generated independently by Python cryptography AES/CTR, exercising
        // carry beyond 64 bits and wrapping the entire 128-bit counter.
        let vectors: [(String, String)] = [
            ("0011223344556677ffffffffffffffff",
             "00c1fb494a30a5b0542aae5db00113f58250b777a31944dcf88517eed1368e40e5d3ad9ee95b46de0499cd6ba888220221"),
            ("ffffffffffffffffffffffffffffffff",
             "00e998e61e48a276dd5b8e1b70518259e1e28112a53e5c89c7b1ea8071c133699fd07c548d6e9cb9c28edfb11a64ef1812")
        ]
        for (ivHex, envelopeHex) in vectors {
            XCTAssertEqual(try OppoSessionCrypto.decryptEnvelope(envelope: hex(envelopeHex), key32: key,
                                                                 iv16: hex(ivHex)), expected)
            XCTAssertEqual(try OppoSessionCrypto.encryptEnvelope(plaintext: expected, key32: key,
                                                                 iv16: hex(ivHex)), hex(envelopeHex))
        }
    }

    func testAES256CTREncryptionMatchesIndependentPaddingBoundaryFixtures() throws {
        let key = Data((0..<32).map(UInt8.init))
        let iv = hex("000102030405060708090a0b0c0d0e0f")
        // Independent Python cryptography AES/CTR fixtures. Exact alignment
        // must use prefix0 and must not add another padded block.
        let vectors: [(Int, String)] = [
            (2, "0e5a6f045708fb7196f02e553d02c3a692"),
            (15, "015a6f06540cfe7791f8275f360ecea892"),
            (16, "005a6f06540cfe7791f8275f360ecea89d"),
            (17, "0f5a6f06540cfe7791f8275f360ecea89d70f310d5c385585d5516fb5172e520cf"),
            (31, "015a6f06540cfe7791f8275f360ecea89d70e202c6d7904e4a4d0fe14a6ef83ecf"),
            (32, "005a6f06540cfe7791f8275f360ecea89d70e202c6d7904e4a4d0fe14a6ef83ed0")
        ]
        for (length, expected) in vectors {
            let plaintext = Data((0..<length).map(UInt8.init))
            XCTAssertEqual(try OppoSessionCrypto.encryptEnvelope(plaintext: plaintext, key32: key, iv16: iv),
                           hex(expected))
        }
    }

    func testAES256CTREncryptionRejectsInvalidInputsBeforeAllocation() {
        let key = Data(repeating: 0, count: 32)
        let iv = Data(repeating: 0, count: 16)
        assertCryptoError(.invalidSessionKeyLength) {
            _ = try OppoSessionCrypto.encryptEnvelope(plaintext: Data([1]), key32: Data(count: 16), iv16: iv)
        }
        assertCryptoError(.invalidIVLength) {
            _ = try OppoSessionCrypto.encryptEnvelope(plaintext: Data([1]), key32: key, iv16: Data(count: 15))
        }
        assertCryptoError(.emptyPlaintext) {
            _ = try OppoSessionCrypto.encryptEnvelope(plaintext: Data(), key32: key, iv16: iv)
        }
        assertCryptoError(.inputTooLarge) {
            _ = try OppoSessionCrypto.encryptEnvelope(plaintext: Data(count: 65_537), key32: key, iv16: iv)
        }
    }

    func testAES256CTRRemovesZeroPaddingAndAcceptsLegacyAlignedPrefix16() throws {
        let key = Data((0..<32).map(UInt8.init))
        let iv = hex("000102030405060708090a0b0c0d0e0f")
        let ciphertext = hex("5b6c07530dfb7196f02e553d02c3a692")
        XCTAssertEqual(try OppoSessionCrypto.decryptEnvelope(envelope: Data([11]) + ciphertext, key32: key, iv16: iv),
                       hex("0102030405"))
        let aligned = try OppoSessionCrypto.decryptEnvelope(envelope: Data([0]) + ciphertext, key32: key, iv16: iv)
        XCTAssertEqual(aligned, hex("01020304050000000000000000000000"))
        XCTAssertEqual(try OppoSessionCrypto.decryptEnvelope(envelope: Data([16]) + ciphertext, key32: key, iv16: iv),
                       aligned)
    }

    func testAES256CTRRejectsMalformedInputsAndPadding() {
        let key = Data((0..<32).map(UInt8.init))
        let iv = hex("000102030405060708090a0b0c0d0e0f")
        let envelope = hex("0b5b6c07530dfb7196f02e553d02c3a692")
        assertCryptoError(.invalidSessionKeyLength) {
            _ = try OppoSessionCrypto.decryptEnvelope(envelope: envelope, key32: Data(repeating: 0, count: 16), iv16: iv)
        }
        assertCryptoError(.invalidIVLength) {
            _ = try OppoSessionCrypto.decryptEnvelope(envelope: envelope, key32: key, iv16: Data(repeating: 0, count: 15))
        }
        assertCryptoError(.invalidEnvelopeLength) {
            _ = try OppoSessionCrypto.decryptEnvelope(envelope: Data(envelope.dropLast()), key32: key, iv16: iv)
        }
        var invalidPrefix = envelope
        invalidPrefix[0] = 255
        assertCryptoError(.invalidPadding) {
            _ = try OppoSessionCrypto.decryptEnvelope(envelope: invalidPrefix, key32: key, iv16: iv)
        }
        var alteredPadding = envelope
        alteredPadding[alteredPadding.count - 1] ^= 1
        assertCryptoError(.invalidPadding) {
            _ = try OppoSessionCrypto.decryptEnvelope(envelope: alteredPadding, key32: key, iv16: iv)
        }
        assertCryptoError(.inputTooLarge) {
            _ = try OppoSessionCrypto.decryptEnvelope(envelope: Data(repeating: 0, count: 65_538), key32: key, iv16: iv)
        }
    }

    func testRSA2048PublicParametersAndPKCS1Decryption() throws {
        let pair = try OppoRSAKeyPair()
        XCTAssertEqual(pair.modulus.count, 256)
        XCTAssertEqual(pair.exponent, hex("010001"))
        XCTAssertTrue(pair.modulus.first.map { $0 & 0x80 != 0 } == true)
        // Rebuild a separate public key from exactly the parameters sent on the
        // wire, not from the object's private key or a shared DER parser.
        let syntheticSessionKey = Data((0..<32).map(UInt8.init))
        let encrypted = try encryptWithPublicParameters(pair, plaintext: syntheticSessionKey)
        XCTAssertEqual(try pair.decryptPKCS1(encrypted), syntheticSessionKey)
    }

    func testRSARejectsPubliclyInvalidCiphertextLengths() throws {
        let pair = try OppoRSAKeyPair()
        for length in [0, 255, 257] {
            assertCryptoError(.invalidRSACiphertextLength) {
                _ = try pair.decryptPKCS1(Data(repeating: 0, count: length))
            }
        }
    }

    func testRSARejectsValidPKCS1MessagesWithNonSessionKeyLengths() throws {
        let pair = try OppoRSAKeyPair()
        for length in [31, 33] {
            // Valid RSA padding, invalid protocol key size. This result is
            // deterministic and does not depend on padding-error disclosure.
            let ciphertext = try encryptWithPublicParameters(pair, plaintext: Data(repeating: 0x42, count: length))
            assertCryptoError(.invalidSessionKeyLength) {
                _ = try pair.decryptPKCS1(ciphertext)
            }
        }
    }

    func testInvalidRSABlockCannotAuthenticateWithLivePrimitives() throws {
        let pair = try OppoRSAKeyPair()
        let engine = try liveEngineReadyForSession(pair)
        // Security can either reject this PKCS#1 block or return candidate
        // bytes. Do not assert which behavior the operating system chooses.
        // If a 32-byte candidate is returned, the independent AES proof must
        // still fail: prefix0 specifies sixteen plaintext bytes, not four.
        let actions = try deliverSessionProof(to: engine,
                                             encryptedKey: Data(repeating: 0, count: 256),
                                             plaintext: hex("01020304"),
                                             envelope: Data([0]) + Data(repeating: 0, count: 16))
        assertSessionRejected(engine, actions: actions)
    }

    func testValidRSAKeyCannotAuthenticateWithTamperedAESProof() throws {
        let pair = try OppoRSAKeyPair()
        let engine = try liveEngineReadyForSession(pair)
        let ciphertext = try encryptWithPublicParameters(pair, plaintext: Data((0..<32).map(UInt8.init)))
        // Independent AES-256 CTR fixture above, with the last padding byte
        // flipped. This forces the real RSA -> real AES -> state-machine path.
        let actions = try deliverSessionProof(to: engine, encryptedKey: ciphertext,
                                             plaintext: hex("0102030405"),
                                             envelope: hex("0b5b6c07530dfb7196f02e553d02c3a693"))
        assertSessionRejected(engine, actions: actions)
    }

    private func encryptWithPublicParameters(_ pair: OppoRSAKeyPair, plaintext: Data) throws -> Data {
        let publicDER = rsaPublicDER(modulus: pair.modulus, exponent: pair.exponent)
        let publicKey = try XCTUnwrap(SecKeyCreateWithData(publicDER as CFData, [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 2048
        ] as CFDictionary, nil))
        let encrypted = try XCTUnwrap(SecKeyCreateEncryptedData(publicKey, .rsaEncryptionPKCS1,
                                                               plaintext as CFData, nil))
        return encrypted as Data
    }

    /// Drive the genuine identity primitives with synthetic inputs, then leave
    /// the engine awaiting cid37 after successful physical submission/ATT ack.
    private func liveEngineReadyForSession(_ pair: OppoRSAKeyPair) throws -> OppoAuthentication {
        let clientNonce: UInt64 = 1_700_000_000_000
        let watchNonce: UInt64 = 1_700_000_000_123
        let challenge = hex("01234567")
        var dependencies = OppoAuthentication.Dependencies.live
        dependencies.makeNonce = { clientNonce }
        dependencies.randomChallenge = { challenge }
        dependencies.makeRSA = {
            OppoAuthentication.RSAContext(modulus: pair.modulus, exponent: pair.exponent,
                                          decrypt: { try pair.decryptPKCS1($0) })
        }
        let engine = OppoAuthentication(dependencies: dependencies)
        let capabilities = OppoTransportCapabilities(
            protocolVersion: 5, maxFrameSize: 20, maxTransmissionUnit: 20,
            interval: 10, supportProtocol: 3, commandID: 0x81, controlFlags: 0,
            frameCount: 1, frameShape: "SINGLE_FRAME", crcValidation: "CRC16_LE_VERIFIED",
            encodedFieldNumbers: [1, 2, 3, 4, 5])
        let nonce = try sentCommand(engine.start(capabilities: capabilities))
        _ = engine.didSubmit(token: nonce.token, streamOffset: 100)
        XCTAssertTrue(engine.writeCompleted(token: nonce.token, succeeded: true).isEmpty)
        let nonceReply = try OppoProtobufWriter.encode([1: .varint(watchNonce)])
        let identity = try sentCommand(engine.receive(wireMessage(command: 24, body: nonceReply, offset: 100)))
        _ = engine.didSubmit(token: identity.token, streamOffset: 200)
        XCTAssertTrue(engine.writeCompleted(token: identity.token, succeeded: true).isEmpty)
        // Independently reconstructed synthetic complement-reply fixture.
        let identityReply = try OppoProtobufWriter.encode([
            2: .bytes(hex("0c6b56b960b58cc87b89f4f87178c374e2"))
        ])
        let rsa = try sentCommand(engine.receive(wireMessage(command: 25, body: identityReply, offset: 200)))
        XCTAssertEqual(rsa.commandID, 36)
        _ = engine.didSubmit(token: rsa.token, streamOffset: 300)
        XCTAssertTrue(engine.writeCompleted(token: rsa.token, succeeded: true).isEmpty)
        XCTAssertEqual(engine.phase, .sessionKeys)
        XCTAssertTrue(engine.identityVerified)
        return engine
    }

    private func deliverSessionProof(to engine: OppoAuthentication, encryptedKey: Data,
                                     plaintext: Data, envelope: Data) throws -> [OppoAuthentication.Action] {
        let body = try OppoProtobufWriter.encode([
            1: .bytes(encryptedKey), 2: .bytes(hex("000102030405060708090a0b0c0d0e0f")),
            3: .bytes(plaintext), 4: .bytes(envelope)
        ])
        return engine.receive(wireMessage(command: 37, body: body, offset: 300))
    }

    private func assertSessionRejected(_ engine: OppoAuthentication, actions: [OppoAuthentication.Action],
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(engine.phase, .failed, file: file, line: line)
        XCTAssertFalse(engine.keyExchangeVerified, file: file, line: line)
        XCTAssertFalse(actions.contains { if case .completed = $0 { return true }; return false }, file: file, line: line)
        XCTAssertFalse(actions.contains {
            if case .send(let command) = $0 { return command.commandID & 0x7f == 37 }
            return false
        }, file: file, line: line)
        XCTAssertEqual(actions.count, 1, file: file, line: line)
        guard let action = actions.first, case .failed(let failure) = action else {
            XCTFail("Invalid session proof must produce a failure", file: file, line: line)
            return
        }
        XCTAssertEqual(failure.phase, .sessionKeys, file: file, line: line)
    }

    private func wireMessage(command: UInt8, body: Data, offset: Int) -> OppoWireMessage {
        OppoWireMessage(serviceID: 1, commandID: command, protobuf: body, streamOffset: offset,
                        controlFlags: 0, frameCount: 1, frameShape: "SINGLE_FRAME",
                        crcValidation: "CRC16_LE_VERIFIED")
    }

    private func sentCommand(_ actions: [OppoAuthentication.Action]) throws -> OppoAuthentication.Command {
        XCTAssertEqual(actions.count, 1)
        let action = try XCTUnwrap(actions.first)
        guard case .send(let command) = action else {
            XCTFail("Expected an authentication request")
            throw FixtureError.unexpectedAction
        }
        return command
    }

    private enum FixtureError: Error { case unexpectedAction }

    private func assertCryptoError(_ expected: OppoCryptoError, file: StaticString = #filePath, line: UInt = #line,
                                   _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            // Comparing only the fixed code prevents payload-bearing framework
            // errors from appearing even if a regression returns a wrong type.
            XCTAssertEqual((error as? OppoCryptoError)?.rawValue, expected.rawValue, file: file, line: line)
        }
    }

    private func hex(_ value: String) -> Data {
        let characters = Array(value)
        precondition(characters.count % 2 == 0)
        return Data(stride(from: 0, to: characters.count, by: 2).map {
            UInt8(String(characters[$0...($0 + 1)]), radix: 16)!
        })
    }

    private func rsaPublicDER(modulus: Data, exponent: Data) -> Data {
        func length(_ count: Int) -> Data {
            if count < 128 { return Data([UInt8(count)]) }
            if count <= 255 { return Data([0x81, UInt8(count)]) }
            return Data([0x82, UInt8(count >> 8), UInt8(count & 255)])
        }
        func integer(_ magnitude: Data) -> Data {
            let positive = magnitude.first.map { $0 & 0x80 != 0 } == true ? Data([0]) + magnitude : magnitude
            return Data([0x02]) + length(positive.count) + positive
        }
        let integers = integer(modulus) + integer(exponent)
        return Data([0x30]) + length(integers.count) + integers
    }
}
