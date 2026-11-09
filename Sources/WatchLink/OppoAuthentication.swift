import Foundation

/// The statically reconstructed protocol-3...5 identity handshake only. It still
/// requires validation with the physical watch. This engine neither
/// initiates TransportConsult nor sends account, cloud, OOBE or device commands.
/// Its owner serializes calls, supplies complete validated wire messages, and
/// reports write completion only after every ATT fragment of a command succeeds.
final class OppoAuthentication {
    enum Phase: String, Codable {
        case idle = "NOT_STARTED"
        case nonce = "NONCE_EXCHANGE"
        case identity = "IDENTITY_CHECK"
        case sessionKeys = "SESSION_KEY_EXCHANGE"
        case sessionConfirm = "SESSION_KEY_CONFIRM"
        case completed = "COMPLETED"
        case failed = "FAILED"
        case cancelled = "CANCELLED"
    }

    /// Live protocol data. Intentionally not Codable and never part of a report.
    struct Command {
        let token: Int
        let phase: Phase
        let serviceID: UInt8
        let commandID: UInt8
        let protobuf: Data
    }

    struct Completion: Codable, Equatable {
        let protocolVersion: Int
        let encryptedTransport: Bool
    }

    struct Failure: Error, Codable, Equatable {
        let phase: Phase
        let code: String
        let message: String
    }

    enum Action {
        case send(Command)
        case completed(Completion)
        case failed(Failure)
    }

    /// Counters and fixed reason codes only; no nonces, ciphertext or keys.
    struct Diagnostics: Codable, Equatable {
        var ignoredMessageCount = 0
        var preSubmissionMessageCount = 0
        var staleMessageCount = 0
        var echoMessageCount = 0
        var bufferedReplyCount = 0
        var duplicateReplyCount = 0
        var lastIgnoredReason: String?
    }

    /// Keeping the private-key operation opaque also makes ordering tests
    /// independent of platform key generation. Releasing this value releases
    /// its captured private key; nothing here is persisted or Codable.
    struct RSAContext {
        let modulus: Data
        let exponent: Data
        let decrypt: (Data) throws -> Data
    }

    struct Dependencies {
        var makeNonce: () -> UInt64
        var randomChallenge: () throws -> Data
        var deriveIdentityKey: (UInt64, UInt64) -> Data
        var encryptIdentity: (Data, Data) throws -> Data
        var validateIdentityReply: (Data, Data, Data) throws -> Bool
        var makeRSA: () throws -> RSAContext
        var decryptSessionEnvelope: (Data, Data, Data) throws -> Data

        static var live: Dependencies {
            Dependencies(
                makeNonce: { UInt64(max(0, Date().timeIntervalSince1970 * 1000)) },
                randomChallenge: { try OppoIdentityCrypto.randomChallenge() },
                deriveIdentityKey: { OppoIdentityCrypto.deriveKey(clientNonce: $0, watchNonce: $1) },
                encryptIdentity: { try OppoIdentityCrypto.encryptIdentity(plaintext: $0, key: $1) },
                validateIdentityReply: {
                    try OppoIdentityCrypto.validateIdentityReply(challenge: $0, encryptedReply: $1, key: $2)
                },
                makeRSA: {
                    let pair = try OppoRSAKeyPair()
                    return RSAContext(modulus: pair.modulus, exponent: pair.exponent,
                                      decrypt: { try pair.decryptPKCS1($0) })
                },
                decryptSessionEnvelope: {
                    try OppoSessionCrypto.decryptEnvelope(envelope: $0, key32: $1, iv16: $2)
                })
        }
    }

    private struct PendingCommand {
        let command: Command
        var streamOffset: Int?
        var writeSucceeded = false
        var reply: OppoWireMessage?
    }

    private let dependencies: Dependencies
    private var pending: PendingCommand?
    private var nextToken = 0
    private var protocolVersion = 0
    private var requiresSessionKeys = false
    private var clientNonce: UInt64?
    private var identityKey: Data?
    private var challenge: Data?
    private var rsa: RSAContext?
    private var businessSession: OppoBusinessSession?

    private(set) var phase: Phase = .idle
    private(set) var diagnostics = Diagnostics()
    /// These observed facts survive failure/cancellation and never imply that
    /// the final acknowledgement, business binding or first setup completed.
    private(set) var identityVerified = false
    private(set) var keyExchangeVerified = false

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    deinit { businessSession?.invalidate() }

    /// Single ownership transfer after all required protocol checks AND the
    /// final physical write acknowledgement. Before completion or after a
    /// previous transfer it returns nil. The owner must invalidate the returned
    /// context when this connection ends; no secret is included in Completion.
    func takeBusinessSession() -> OppoBusinessSession? {
        guard phase == .completed else { return nil }
        let session = businessSession
        businessSession = nil
        return session
    }

    private var isActive: Bool {
        switch phase {
        case .nonce, .identity, .sessionKeys, .sessionConfirm: return true
        default: return false
        }
    }

    /// A single-use engine. Capabilities must come from a real validated message;
    /// the owner records their provenance separately from authentication.
    func start(capabilities: OppoTransportCapabilities) -> [Action] {
        guard phase == .idle else { return [] }
        guard (3...5).contains(capabilities.protocolVersion) else {
            return fail(code: "UNSUPPORTED_PROTOCOL_VERSION",
                        message: "只实现协议版本 3 至 5 的身份流程；旧版本所需的持久密钥路径尚未实现。")
        }
        protocolVersion = capabilities.protocolVersion
        requiresSessionKeys = capabilities.supportProtocol & 3 != 0
        let nonce = dependencies.makeNonce()
        clientNonce = nonce
        do {
            let body = try OppoProtobufWriter.encode([1: .varint(nonce)])
            return send(command: 24, body: body, phase: .nonce)
        } catch {
            return fail(code: "NONCE_ENCODING_FAILED", message: "无法编码身份随机数请求。")
        }
    }

    /// Call immediately before the first physical ATT fragment is submitted,
    /// not when the command is merely queued. This never resets the decoder.
    func didSubmit(token: Int, streamOffset: Int) -> [Action] {
        guard isActive, var current = pending, current.command.token == token else { return [] }
        guard current.streamOffset == nil else { return [] }
        guard streamOffset >= 0 else {
            return fail(code: "INVALID_SUBMISSION_OFFSET", message: "无法确定本次身份请求的接收流起点。")
        }
        current.streamOffset = streamOffset
        pending = current
        return []
    }

    /// The owner retains the original ATT error domain/code independently. A
    /// late result for another token can never advance or fail this command.
    func writeCompleted(token: Int, succeeded: Bool) -> [Action] {
        guard isActive, var current = pending, current.command.token == token,
              current.streamOffset != nil, !current.writeSucceeded else { return [] }
        guard succeeded else {
            return fail(code: "ATT_WRITE_FAILED", message: "身份消息没有获得完整的蓝牙写入确认。")
        }
        current.writeSucceeded = true
        pending = current
        return advanceIfReady()
    }

    func receive(_ message: OppoWireMessage) -> [Action] {
        guard isActive, var current = pending else { return [] }
        guard message.serviceID == 1,
              message.commandID & 0x7f == expectedReplyCommand,
              phase != .sessionConfirm else {
            return ignore("OTHER_AUTHENTICATION_COMMAND")
        }
        // This engine only consumes validated cleartext handshake messages.
        guard message.controlFlags & ~UInt16(0x000b) == 0 else {
            return ignore("UNSUPPORTED_HANDSHAKE_CONTROL")
        }
        guard let boundary = current.streamOffset else {
            diagnostics.preSubmissionMessageCount += 1
            return ignore("MESSAGE_BEFORE_REQUEST_SUBMISSION")
        }
        guard message.streamOffset >= boundary else {
            diagnostics.staleMessageCount += 1
            return ignore("MESSAGE_STARTED_BEFORE_REQUEST")
        }
        guard message.protobuf.count <= OppoProtobufReader.maximumEncodedLength else {
            return fail(code: "AUTHENTICATION_MESSAGE_TOO_LARGE", message: "身份回应超过本阶段允许的消息长度。")
        }
        if message.commandID & 0x7f == current.command.commandID,
           message.protobuf == current.command.protobuf {
            diagnostics.echoMessageCount += 1
            return ignore("REQUEST_ECHO")
        }
        // Also reject a nonce echo with different protobuf encoding/unknown
        // fields before it can occupy the sole early-reply buffer.
        if phase == .nonce, let clientNonce,
           let fields = try? OppoProtobufReader(message.protobuf, fields: [1: .varint]),
           let receivedNonce = try? fields.uint64(1), receivedNonce == clientNonce {
            diagnostics.echoMessageCount += 1
            return ignore("NONCE_EQUALS_REQUEST")
        }
        guard current.reply == nil else {
            diagnostics.duplicateReplyCount += 1
            return ignore("REPLY_ALREADY_BUFFERED")
        }
        current.reply = message
        if !current.writeSucceeded { diagnostics.bufferedReplyCount += 1 }
        pending = current
        return advanceIfReady()
    }

    func timeout() -> [Action] {
        guard isActive else { return [] }
        return fail(code: "AUTHENTICATION_TIMEOUT", message: "等待本阶段的手表身份回应或完整写入确认超时。")
    }

    /// Retires the single-use engine. No subsequent callback can revive it.
    func cancel() {
        guard phase != .cancelled else { return }
        releaseEphemeralState()
        phase = .cancelled
    }

    private var expectedReplyCommand: UInt8 {
        switch phase {
        case .nonce: return 24
        case .identity: return 25
        case .sessionKeys: return 37 // RSAConsult (36) has no independent reply.
        default: return 0
        }
    }

    private func advanceIfReady() -> [Action] {
        guard let current = pending, current.writeSucceeded else { return [] }
        if phase == .sessionConfirm { return complete() }
        guard let reply = current.reply else { return [] }
        // Consume one bounded reply. A future valid nonce may still arrive if
        // this one proves to be a semantic echo rather than a watch nonce.
        pending?.reply = nil
        switch phase {
        case .nonce: return receiveNonce(reply.protobuf)
        case .identity: return receiveIdentity(reply.protobuf)
        case .sessionKeys: return receiveSessionKeys(reply.protobuf)
        default: return []
        }
    }

    private func receiveNonce(_ body: Data) -> [Action] {
        do {
            let fields = try OppoProtobufReader(body, fields: [1: .varint])
            guard let watchNonce = try fields.uint64(1), let clientNonce else {
                return fail(code: "MISSING_WATCH_NONCE", message: "手表身份回应缺少随机数。")
            }
            guard watchNonce != clientNonce else {
                diagnostics.echoMessageCount += 1
                return ignore("NONCE_EQUALS_REQUEST")
            }
            // Explicit zero is a valid uint64. The APK does not reject it.
            let key = dependencies.deriveIdentityKey(clientNonce, watchNonce)
            guard key.count == 16 else {
                return fail(code: "INVALID_IDENTITY_KEY", message: "身份密钥派生结果长度不符合协议。")
            }
            let value = try dependencies.randomChallenge()
            guard value.count == 4 else {
                return fail(code: "INVALID_CHALLENGE_LENGTH", message: "身份随机挑战长度不符合协议。")
            }
            let encrypted = try dependencies.encryptIdentity(value, key)
            let request = try OppoProtobufWriter.encode([1: .bytes(value), 2: .bytes(encrypted)])
            self.clientNonce = nil
            identityKey = key
            challenge = value
            return send(command: 25, body: request, phase: .identity)
        } catch {
            return fail(code: "NONCE_HANDSHAKE_FAILED", message: "无法解析身份随机数或生成加密挑战。")
        }
    }

    private func receiveIdentity(_ body: Data) -> [Action] {
        do {
            let fields = try OppoProtobufReader(body, fields: [1: .bytes, 2: .bytes])
            guard let encrypted = try fields.bytes(2), let challenge, let identityKey else {
                return fail(code: "MISSING_IDENTITY_PROOF", message: "手表身份回应缺少加密验证数据。")
            }
            guard try dependencies.validateIdentityReply(challenge, encrypted, identityKey) else {
                return fail(code: "IDENTITY_PROOF_MISMATCH", message: "手表返回的反码挑战未通过身份验证。")
            }
            identityVerified = true
            self.challenge = nil
            self.identityKey = nil
            guard requiresSessionKeys else { return complete() }

            let context = try dependencies.makeRSA()
            guard context.modulus.count == 256, !context.exponent.isEmpty else {
                return fail(code: "INVALID_RSA_PUBLIC_KEY", message: "本次 RSA 公钥格式不符合协议。")
            }
            let request = try OppoProtobufWriter.encode([
                1: .varint(2048), 2: .bytes(context.modulus), 3: .bytes(context.exponent)
            ])
            rsa = context
            return send(command: 36, body: request, phase: .sessionKeys)
        } catch {
            return fail(code: identityVerified ? "RSA_SETUP_FAILED" : "IDENTITY_PROOF_INVALID",
                        message: identityVerified ? "身份挑战已验证，但无法创建本次 RSA 密钥交换。"
                            : "手表身份验证数据无法解密或格式不正确。")
        }
    }

    private func receiveSessionKeys(_ body: Data) -> [Action] {
        do {
            let fields = try OppoProtobufReader(body, fields: [
                1: .bytes, 2: .bytes, 3: .bytes, 4: .bytes, 5: .varint
            ])
            guard let encryptedKey = try fields.bytes(1), encryptedKey.count == 256,
                  let iv = try fields.bytes(2), iv.count == 16,
                  let plaintext = try fields.bytes(3), !plaintext.isEmpty,
                  let encryptedProof = try fields.bytes(4), !encryptedProof.isEmpty,
                  let rsa else {
                return fail(code: "INVALID_SESSION_KEY_FIELDS", message: "手表会话密钥回应缺少有效的密钥、IV 或验证数据。")
            }
            // APK validates these cryptographic fields, not a particular value
            // of the incoming state field. A state-only echo cannot pass here.
            let key = try rsa.decrypt(encryptedKey)
            guard key.count == 32 else {
                return fail(code: "INVALID_SESSION_KEY_LENGTH", message: "解密后的会话密钥长度不符合协议。")
            }
            let decoded = try dependencies.decryptSessionEnvelope(encryptedProof, key, iv)
            guard Self.equalBytes(decoded, plaintext) else {
                return fail(code: "SESSION_PROOF_MISMATCH", message: "手表会话密钥的加密验证数据不匹配。")
            }
            keyExchangeVerified = true
            self.rsa = nil
            businessSession = try OppoBusinessSession(key32: key, iv16: iv)
            let confirmation = try OppoProtobufWriter.encode([5: .varint(1)])
            return send(command: 37, body: confirmation, phase: .sessionConfirm)
        } catch {
            return fail(code: "SESSION_KEY_VALIDATION_FAILED", message: "无法解密或验证本次会话密钥。")
        }
    }

    private func send(command: UInt8, body: Data, phase: Phase) -> [Action] {
        nextToken += 1
        self.phase = phase
        let request = Command(token: nextToken, phase: phase, serviceID: 1,
                              commandID: command, protobuf: body)
        pending = PendingCommand(command: request)
        return [.send(request)]
    }

    private func complete() -> [Action] {
        if requiresSessionKeys {
            guard identityVerified, keyExchangeVerified, businessSession?.isEncrypted == true else {
                return fail(code: "BUSINESS_SESSION_UNAVAILABLE", message: "身份验证未能提供本次业务会话。")
            }
        } else {
            guard identityVerified else {
                return fail(code: "BUSINESS_SESSION_UNAVAILABLE", message: "身份验证未能提供本次业务会话。")
            }
            businessSession = OppoBusinessSession()
        }
        let completion = Completion(protocolVersion: protocolVersion,
                                    encryptedTransport: requiresSessionKeys)
        releaseEphemeralState(keepingBusinessSession: true)
        phase = .completed
        return [.completed(completion)]
    }

    private func fail(code: String, message: String) -> [Action] {
        let failure = Failure(phase: phase, code: code, message: message)
        releaseEphemeralState()
        phase = .failed
        return [.failed(failure)]
    }

    private func ignore(_ reason: String) -> [Action] {
        diagnostics.ignoredMessageCount += 1
        diagnostics.lastIgnoredReason = reason
        return []
    }

    private func releaseEphemeralState(keepingBusinessSession: Bool = false) {
        pending = nil
        clientNonce = nil
        identityKey = nil
        challenge = nil
        rsa = nil
        if !keepingBusinessSession {
            businessSession?.invalidate()
            businessSession = nil
        }
    }

    private static func equalBytes(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }
}
