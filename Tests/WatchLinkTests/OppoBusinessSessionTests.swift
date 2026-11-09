import Foundation
import XCTest
@testable import WatchLink

final class OppoBusinessSessionTests: XCTestCase {
    private let key = Data((0..<32).map(UInt8.init))
    private let iv = Data((0..<16).map(UInt8.init))

    func testClearSessionPreservesWholePayloadAndRejectsEncryptedMode() throws {
        let session = OppoBusinessSession()
        XCTAssertFalse(session.isEncrypted)
        let payload = Data([11, 7, 8, 1, 16, 2])
        XCTAssertEqual(try session.sealPayload(payload), payload)
        XCTAssertEqual(try session.openPayload(payload, encrypted: false), payload)
        assertSessionFailure(.encryptionModeMismatch) {
            _ = try session.openPayload(Data(repeating: 0, count: 17), encrypted: true)
        }
    }

    func testEncryptedSessionUsesIndependentWholeMessageFixturesAndRejectsDowngrade() throws {
        let session = try OppoBusinessSession(key32: key, iv16: iv)
        XCTAssertTrue(session.isEncrypted)
        // Independent Python cryptography AES/CTR. The header bytes sid/cid
        // must be inside the envelope, not left in front of encrypted protobuf.
        let payload = hex("0b0708011002")
        let expected = hex("0a51690c5618f97196f02e553d02c3a692")
        XCTAssertEqual(try session.sealPayload(payload), expected)
        XCTAssertEqual(try session.openPayload(expected, encrypted: true), payload)
        XCTAssertEqual(try session.sealPayload(Data([11, 11])),
                       hex("0e5165045708fb7196f02e553d02c3a692"))
        XCTAssertEqual(try session.sealPayload(payload), expected)
        assertSessionFailure(.encryptionModeMismatch) {
            _ = try session.openPayload(payload, encrypted: false)
        }
    }

    func testCompletePayloadBoundsAccountForEncryptionExpansion() throws {
        let clear = OppoBusinessSession()
        let maximumClear = Data(repeating: 1, count: 1024)
        XCTAssertEqual(try clear.sealPayload(maximumClear), maximumClear)
        XCTAssertEqual(try clear.openPayload(maximumClear, encrypted: false), maximumClear)
        for count in [0, 1, 1025] {
            assertSessionFailure(.invalidPayloadLength) { _ = try clear.sealPayload(Data(count: count)) }
            assertSessionFailure(.invalidPayloadLength) {
                _ = try clear.openPayload(Data(count: count), encrypted: false)
            }
        }

        let encrypted = try OppoBusinessSession(key32: key, iv16: iv)
        let maximumPlaintext = Data(repeating: 1, count: 1008)
        let maximumEnvelope = try encrypted.sealPayload(maximumPlaintext)
        XCTAssertEqual(maximumEnvelope.count, 1009)
        XCTAssertEqual(try encrypted.openPayload(maximumEnvelope, encrypted: true), maximumPlaintext)
        for count in [0, 1, 1009, 1024] {
            assertSessionFailure(.invalidPayloadLength) { _ = try encrypted.sealPayload(Data(count: count)) }
        }
        let tooLarge = try OppoSessionCrypto.encryptEnvelope(plaintext: maximumClear, key32: key, iv16: iv)
        assertSessionFailure(.invalidPayloadLength) { _ = try encrypted.openPayload(tooLarge, encrypted: true) }
        let tooShort = try OppoSessionCrypto.encryptEnvelope(plaintext: Data([1]), key32: key, iv16: iv)
        assertSessionFailure(.invalidPayloadLength) { _ = try encrypted.openPayload(tooShort, encrypted: true) }
        assertSessionFailure(.invalidPayloadLength) {
            _ = try encrypted.openPayload(Data(count: 16), encrypted: true)
        }
    }

    func testInvalidationIsTerminalForBothCipherModes() throws {
        for session in [OppoBusinessSession(), try OppoBusinessSession(key32: key, iv16: iv)] {
            let payload = Data([11, 11])
            let envelope = try session.sealPayload(payload)
            session.invalidate()
            session.invalidate()
            assertSessionFailure(.invalidated) { _ = try session.sealPayload(payload) }
            assertSessionFailure(.invalidated) {
                _ = try session.openPayload(envelope, encrypted: session.isEncrypted)
            }
        }
    }

    func testSessionOwnsItsCipherMaterialAfterInputDataChanges() throws {
        var sourceKey = key
        var sourceIV = iv
        let session = try OppoBusinessSession(key32: sourceKey, iv16: sourceIV)
        sourceKey.resetBytes(in: 0..<sourceKey.count)
        sourceIV.resetBytes(in: 0..<sourceIV.count)
        XCTAssertEqual(try session.sealPayload(Data([11, 11])),
                       hex("0e5165045708fb7196f02e553d02c3a692"))
    }

    func testInvalidCipherMaterialCannotCreateAnEncryptedSession() {
        XCTAssertThrowsError(try OppoBusinessSession(key32: Data(count: 31), iv16: iv)) { error in
            XCTAssertEqual(error as? OppoCryptoError, .invalidSessionKeyLength)
        }
        XCTAssertThrowsError(try OppoBusinessSession(key32: key, iv16: Data(count: 15))) { error in
            XCTAssertEqual(error as? OppoCryptoError, .invalidIVLength)
        }
    }

    private func assertSessionFailure(_ expected: OppoBusinessSession.Failure,
                                      file: StaticString = #filePath, line: UInt = #line,
                                      _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? OppoBusinessSession.Failure, expected, file: file, line: line)
        }
    }

    private func hex(_ value: String) -> Data {
        let characters = Array(value)
        precondition(characters.count % 2 == 0)
        return Data(stride(from: 0, to: characters.count, by: 2).map {
            UInt8(String(characters[$0...($0 + 1)]), radix: 16)!
        })
    }
}
