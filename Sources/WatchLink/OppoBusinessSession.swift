import Foundation

/// One authenticated connection's transient business-message cipher context.
/// Intentionally not Codable: neither this object nor its payloads belong in a
/// diagnostic report. The connection owner serializes use and invalidates it
/// on disconnect, cancellation or background entry; it must not be persisted.
final class OppoBusinessSession {
    enum Failure: String, Error {
        case invalidated = "BUSINESS_SESSION_INVALIDATED"
        case encryptionModeMismatch = "BUSINESS_ENCRYPTION_MODE_MISMATCH"
        case invalidPayloadLength = "BUSINESS_PAYLOAD_LENGTH_INVALID"
    }

    // The wire decoder's maximum complete payload is 1024 bytes. An encrypted
    // plaintext of 1008 bytes produces a 1009-byte prefixed AES envelope; the
    // next block would exceed the wire limit. Payload includes sid and cid.
    static let maximumClearPayloadLength = 1024
    static let maximumEncryptedPlaintextLength = 1008
    private static let maximumEncryptedPayloadLength = 1009

    let isEncrypted: Bool
    private var active = true
    private var key32: Data?
    private var iv16: Data?

    /// Used by the identity engine only after a successful unencrypted proof.
    init() {
        isEncrypted = false
    }

    /// The identity engine prepares this after the AESConsult proof succeeds,
    /// but must not hand it to business code before the final ATT confirmation.
    init(key32: Data, iv16: Data) throws {
        guard key32.count == 32 else { throw OppoCryptoError.invalidSessionKeyLength }
        guard iv16.count == 16 else { throw OppoCryptoError.invalidIVLength }
        isEncrypted = true
        self.key32 = Data(key32)
        self.iv16 = Data(iv16)
    }

    deinit { invalidate() }

    /// Seal the complete sid/cid/protobuf payload before the caller fragments
    /// it and adds CRCs. The verified vendor protocol resets IV per message.
    func sealPayload(_ plaintext: Data) throws -> Data {
        guard active else { throw Failure.invalidated }
        let maximum = isEncrypted ? Self.maximumEncryptedPlaintextLength : Self.maximumClearPayloadLength
        guard (2...maximum).contains(plaintext.count) else { throw Failure.invalidPayloadLength }
        guard isEncrypted else { return plaintext }
        guard let key32, let iv16 else { throw Failure.invalidated }
        return try OppoSessionCrypto.encryptEnvelope(plaintext: plaintext, key32: key32, iv16: iv16)
    }

    /// The caller first validates CRCs and reassembles the entire wire payload.
    /// Negotiated encryption is strict: cleartext is never a fallback when an
    /// encrypted session was established, nor accepted as proof of a downgrade.
    /// Returned bytes still require business route/schema/state validation.
    func openPayload(_ payload: Data, encrypted: Bool) throws -> Data {
        guard active else { throw Failure.invalidated }
        guard encrypted == isEncrypted else { throw Failure.encryptionModeMismatch }
        if !isEncrypted {
            guard (2...Self.maximumClearPayloadLength).contains(payload.count) else {
                throw Failure.invalidPayloadLength
            }
            return payload
        }
        guard (17...Self.maximumEncryptedPayloadLength).contains(payload.count) else {
            throw Failure.invalidPayloadLength
        }
        guard let key32, let iv16 else { throw Failure.invalidated }
        let plaintext = try OppoSessionCrypto.decryptEnvelope(envelope: payload, key32: key32, iv16: iv16)
        guard (2...Self.maximumEncryptedPlaintextLength).contains(plaintext.count) else {
            throw Failure.invalidPayloadLength
        }
        return plaintext
    }

    func invalidate() {
        active = false
        // Best-effort overwrite of these owned buffers before release. Swift
        // Data may have temporary copies; this is not a zeroization guarantee.
        if let count = key32?.count { key32?.resetBytes(in: 0..<count) }
        if let count = iv16?.count { iv16?.resetBytes(in: 0..<count) }
        key32 = nil
        iv16 = nil
    }
}
