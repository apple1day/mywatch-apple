import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Bounded, payload-free failures. Never attach nonces, challenges, key material,
/// Security framework error descriptions, or ciphertext to a diagnostic error.
enum OppoCryptoError: String, Error {
    case invalidIdentityKeyLength = "INVALID_IDENTITY_KEY_LENGTH"
    case invalidSessionKeyLength = "INVALID_SESSION_KEY_LENGTH"
    case invalidIVLength = "INVALID_IV_LENGTH"
    case invalidChallengeLength = "INVALID_CHALLENGE_LENGTH"
    case emptyPlaintext = "EMPTY_PLAINTEXT"
    case inputTooLarge = "CRYPTO_INPUT_TOO_LARGE"
    case invalidEnvelopeLength = "INVALID_ENVELOPE_LENGTH"
    case invalidPadding = "INVALID_ZERO_PADDING"
    case aesOperationFailed = "AES_OPERATION_FAILED"
    case randomGenerationFailed = "RANDOM_GENERATION_FAILED"
    case rsaGenerationFailed = "RSA_GENERATION_FAILED"
    case rsaPublicKeyExportFailed = "RSA_PUBLIC_KEY_EXPORT_FAILED"
    case invalidRSAPublicKey = "INVALID_RSA_PUBLIC_KEY"
    case invalidRSACiphertextLength = "INVALID_RSA_CIPHERTEXT_LENGTH"
    case rsaDecryptionFailed = "RSA_DECRYPTION_FAILED"
    case rsaAlgorithmUnavailable = "RSA_ALGORITHM_UNAVAILABLE"
}

/// Original implementation of the legacy transport identity transform recovered
/// statically from libencrypt.so key_generator (0x3784) and encrypt (0x2484).
/// MD5 and ECB are required here for protocol compatibility, not selected as a
/// general-purpose KDF or encryption format. Synthetic tests are not watch proof.
enum OppoIdentityCrypto {
    static func deriveKey(clientNonce: UInt64, watchNonce: UInt64) -> Data {
        let firstDigest = shuffleDigest(pattern(clientNonce), seed: clientNonce)
        var secondPattern = pattern(watchNonce)
        secondPattern.replaceSubrange(0..<16, with: firstDigest)
        return Data(shuffleDigest(secondPattern, seed: watchNonce))
    }

    static func randomChallenge() throws -> Data {
        var challenge = Data(count: 4)
        let status = challenge.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> OSStatus in
            guard let address = bytes.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, 4, address)
        }
        guard status == errSecSuccess else { throw OppoCryptoError.randomGenerationFailed }
        return challenge
    }

    static func encryptIdentity(plaintext: Data, key: Data) throws -> Data {
        guard key.count == 16 else { throw OppoCryptoError.invalidIdentityKeyLength }
        guard !plaintext.isEmpty else { throw OppoCryptoError.emptyPlaintext }
        guard plaintext.count <= OppoCryptoEnvelope.maximumPaddedBytes else {
            throw OppoCryptoError.inputTooLarge
        }
        let padding = (16 - plaintext.count % 16) % 16
        var padded = Data(plaintext)
        padded.append(Data(repeating: 0, count: padding))
        let ciphertext = try OppoAESPrimitive.ecb(padded, key: key, operation: CCOperation(kCCEncrypt))
        var envelope = Data([UInt8(padding)])
        envelope.append(ciphertext)
        return envelope
    }

    static func decryptIdentity(envelope: Data, key: Data) throws -> Data {
        guard key.count == 16 else { throw OppoCryptoError.invalidIdentityKeyLength }
        let parsed = try OppoCryptoEnvelope.parse(envelope, acceptsAlignedPrefix16: false)
        let padded = try OppoAESPrimitive.ecb(parsed.ciphertext, key: key, operation: CCOperation(kCCDecrypt))
        return try OppoCryptoEnvelope.removePadding(padded, count: parsed.padding)
    }

    /// ot0.a.z() compares the original four-byte challenge with the bitwise NOT
    /// of the decrypted response. An encrypted echo of our request is not proof.
    static func validateIdentityReply(challenge: Data, encryptedReply: Data, key: Data) throws -> Bool {
        guard challenge.count == 4 else { throw OppoCryptoError.invalidChallengeLength }
        let decoded = try decryptIdentity(envelope: encryptedReply, key: key)
        guard decoded.count == 4 else { return false }
        var difference: UInt8 = 0
        for (actual, original) in zip(decoded, challenge) {
            difference |= actual ^ original ^ 0xff
        }
        return difference == 0
    }

    private static func pattern(_ seed: UInt64) -> [UInt8] {
        let offset = Int(seed % 127)
        return (0..<512).map { UInt8(truncatingIfNeeded: offset + $0) }
    }

    private static func shuffleDigest(_ initial: [UInt8], seed: UInt64) -> [UInt8] {
        var buffer = initial
        var current = seed
        for index in 0..<512 {
            current = current &* 1_103_515_245 &+ 12_345
            let other = Int((current >> 16) & 511)
            buffer.swapAt(index, other)
        }
        return Array(Insecure.MD5.hash(data: Data(buffer)))
    }
}

/// Ephemeral RSA-2048 identity-negotiation key. Only public parameters leave this
/// object; the private key is never exported or persisted to the keychain.
final class OppoRSAKeyPair {
    let modulus: Data
    let exponent: Data
    private let privateKey: SecKey

    init() throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false],
            kSecPublicKeyAttrs as String: [kSecAttrIsPermanent as String: false]
        ]
        guard let generated = SecKeyCreateRandomKey(attributes as CFDictionary, nil),
              SecKeyGetBlockSize(generated) == 256 else {
            throw OppoCryptoError.rsaGenerationFailed
        }
        guard let publicKey = SecKeyCopyPublicKey(generated),
              let representation = SecKeyCopyExternalRepresentation(publicKey, nil) else {
            throw OppoCryptoError.rsaPublicKeyExportFailed
        }
        // Security exports RSA public keys as a PKCS#1 DER SEQUENCE of INTEGERs.
        // ot0.a.K() transmits unsigned big-endian magnitude, without DER sign 00.
        let parameters = try OppoRSAPublicDER.parameters(representation as Data)
        privateKey = generated
        modulus = parameters.modulus
        exponent = parameters.exponent
    }

    /// Returns only a candidate 32-byte AES-256 session key. Security may return
    /// candidate bytes for an invalid PKCS#1 block instead of a padding error.
    /// A returned value is therefore not proof: the caller must still verify
    /// the complete, independently supplied AESConsult plaintext/envelope pair.
    func decryptPKCS1(_ ciphertext: Data) throws -> Data {
        guard ciphertext.count == 256 else { throw OppoCryptoError.invalidRSACiphertextLength }
        guard SecKeyIsAlgorithmSupported(privateKey, .decrypt, .rsaEncryptionPKCS1) else {
            throw OppoCryptoError.rsaAlgorithmUnavailable
        }
        guard let result = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionPKCS1,
                                                    ciphertext as CFData, nil) else {
            throw OppoCryptoError.rsaDecryptionFailed
        }
        let plaintext = result as Data
        guard plaintext.count == 32 else { throw OppoCryptoError.invalidSessionKeyLength }
        return plaintext
    }
}

/// AES-256 envelopes used by AESConsult and subsequent encrypted business
/// messages. AESConsult callers must compare the entire decrypted proof with
/// its independently supplied plaintext. CTR alone is not an integrity check.
enum OppoSessionCrypto {
    static func encryptEnvelope(plaintext: Data, key32: Data, iv16: Data) throws -> Data {
        guard key32.count == 32 else { throw OppoCryptoError.invalidSessionKeyLength }
        guard iv16.count == 16 else { throw OppoCryptoError.invalidIVLength }
        guard !plaintext.isEmpty else { throw OppoCryptoError.emptyPlaintext }
        guard plaintext.count <= OppoCryptoEnvelope.maximumPaddedBytes else {
            throw OppoCryptoError.inputTooLarge
        }
        // AESCipher.e(): prefix zero for an aligned message, otherwise pad
        // with zeros and put the padding count before the ciphertext.
        let padding = (16 - plaintext.count % 16) % 16
        var padded = Data(plaintext)
        padded.append(Data(repeating: 0, count: padding))
        let ciphertext = try applyCTR(padded, key32: key32, iv16: iv16)
        return Data([UInt8(padding)]) + ciphertext
    }

    static func decryptEnvelope(envelope: Data, key32: Data, iv16: Data) throws -> Data {
        guard key32.count == 32 else { throw OppoCryptoError.invalidSessionKeyLength }
        guard iv16.count == 16 else { throw OppoCryptoError.invalidIVLength }
        // AESCipher.d() explicitly treats prefix 16 as zero; e() emits zero.
        let parsed = try OppoCryptoEnvelope.parse(envelope, acceptsAlignedPrefix16: true)
        let padded = try applyCTR(parsed.ciphertext, key32: key32, iv16: iv16)
        return try OppoCryptoEnvelope.removePadding(padded, count: parsed.padding)
    }

    private static func applyCTR(_ input: Data, key32: Data, iv16: Data) throws -> Data {
        // libencrypt.so AES_CTR_xcrypt_buffer (0x1e70): encrypt the supplied IV
        // first, then increment bytes 15...0, carrying through all 128 bits.
        // Its JNI wrapper reinitializes the IV for each envelope. Generate the
        // exact counter blocks here and use the system AES primitive so no
        // CommonCrypto mode-specific counter width or endian default is assumed.
        var counter = Array(iv16)
        var counters = Data(capacity: input.count)
        for _ in stride(from: 0, to: input.count, by: 16) {
            counters.append(contentsOf: counter)
            for index in stride(from: 15, through: 0, by: -1) {
                counter[index] &+= 1
                if counter[index] != 0 { break }
            }
        }
        let keystream = try OppoAESPrimitive.ecb(counters, key: key32, operation: CCOperation(kCCEncrypt))
        return Data(zip(input, keystream).map { $0.0 ^ $0.1 })
    }
}

private enum OppoCryptoEnvelope {
    // Independent of the BLE stream/reassembly budgets. Negotiation proofs are
    // small; malformed encrypted input cannot cause unbounded allocations.
    static let maximumPaddedBytes = 65_536

    static func parse(_ envelope: Data, acceptsAlignedPrefix16: Bool) throws
        -> (padding: Int, ciphertext: Data) {
        guard envelope.count <= maximumPaddedBytes + 1 else { throw OppoCryptoError.inputTooLarge }
        guard envelope.count >= 17, (envelope.count - 1) % 16 == 0,
              let prefix = envelope.first else { throw OppoCryptoError.invalidEnvelopeLength }
        let padding = acceptsAlignedPrefix16 && prefix == 16 ? 0 : Int(prefix)
        guard padding <= 15 else { throw OppoCryptoError.invalidPadding }
        return (padding, Data(envelope.dropFirst()))
    }

    static func removePadding(_ padded: Data, count: Int) throws -> Data {
        guard count >= 0, count <= 15, padded.count > count else { throw OppoCryptoError.invalidPadding }
        // Original encryptors write zero padding. Reject malformed padding
        // rather than exposing the APK's unchecked truncation behavior.
        guard padded.suffix(count).allSatisfy({ $0 == 0 }) else { throw OppoCryptoError.invalidPadding }
        return Data(padded.dropLast(count))
    }
}

private enum OppoAESPrimitive {
    static func ecb(_ input: Data, key: Data, operation: CCOperation) throws -> Data {
        guard !input.isEmpty, input.count % 16 == 0,
              input.count <= OppoCryptoEnvelope.maximumPaddedBytes,
              key.count == 16 || key.count == 32 else { throw OppoCryptoError.aesOperationFailed }
        let capacity = input.count
        let keyCount = key.count
        var output = Data(count: capacity)
        var written = 0
        let status = output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            input.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                key.withUnsafeBytes { (secret: UnsafeRawBufferPointer) in
                    CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            secret.baseAddress, keyCount, nil, source.baseAddress, capacity,
                            out.baseAddress, capacity, &written)
                }
            }
        }
        guard status == kCCSuccess, written == capacity else { throw OppoCryptoError.aesOperationFailed }
        return output
    }
}

private enum OppoRSAPublicDER {
    static func parameters(_ representation: Data) throws -> (modulus: Data, exponent: Data) {
        var outer = Reader(bytes: Array(representation))
        var inner = Reader(bytes: try outer.value(tag: 0x30))
        guard outer.isAtEnd else { throw OppoCryptoError.invalidRSAPublicKey }
        let modulus = try unsignedInteger(inner.value(tag: 0x02))
        let exponent = try unsignedInteger(inner.value(tag: 0x02))
        guard inner.isAtEnd, modulus.count == 256, modulus[0] & 0x80 != 0,
              !exponent.isEmpty, exponent.count <= 8 else { throw OppoCryptoError.invalidRSAPublicKey }
        let exponentNumber = exponent.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard exponentNumber >= 3, exponentNumber & 1 == 1 else { throw OppoCryptoError.invalidRSAPublicKey }
        return (Data(modulus), Data(exponent))
    }

    private static func unsignedInteger(_ encoded: [UInt8]) throws -> [UInt8] {
        guard let first = encoded.first, first & 0x80 == 0 else { throw OppoCryptoError.invalidRSAPublicKey }
        if first == 0 {
            guard encoded.count > 1, encoded[1] & 0x80 != 0 else { throw OppoCryptoError.invalidRSAPublicKey }
            return Array(encoded.dropFirst())
        }
        return encoded
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        var isAtEnd: Bool { offset == bytes.count }

        mutating func value(tag: UInt8) throws -> [UInt8] {
            guard bytes.count - offset >= 2, bytes[offset] == tag else { throw OppoCryptoError.invalidRSAPublicKey }
            offset += 1
            let firstLength = bytes[offset]
            offset += 1
            let length: Int
            if firstLength & 0x80 == 0 {
                length = Int(firstLength)
            } else {
                let lengthBytes = Int(firstLength & 0x7f)
                guard (1...4).contains(lengthBytes), lengthBytes <= bytes.count - offset,
                      bytes[offset] != 0 else { throw OppoCryptoError.invalidRSAPublicKey }
                var result = 0
                for _ in 0..<lengthBytes {
                    result = (result << 8) | Int(bytes[offset])
                    offset += 1
                }
                guard result >= 128 else { throw OppoCryptoError.invalidRSAPublicKey }
                length = result
            }
            guard length <= bytes.count - offset else { throw OppoCryptoError.invalidRSAPublicKey }
            let result = Array(bytes[offset..<(offset + length)])
            offset += length
            return result
        }
    }
}
