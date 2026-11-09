import Foundation

/// UUID directions are taken from the original client's BLE transport, not the names
/// assigned to its constants. Presence alone never proves that a handshake is supported.
enum OppoGATTProfile {
    static let commandService = "00002760-08C2-11E1-9073-0E8AC72E1011"
    static let commandWrite = "00002760-08C2-11E1-9073-0E8AC72E0011"
    static let commandNotify = "00002760-08C2-11E1-9073-0E8AC72E0012"
    static let fileService = "00002760-08C2-11E1-9073-0E8AC72E1012"
    static let fileNotify = "00002760-08C2-11E1-9073-0E8AC72E0015"

    static func isAvailable(in rows: [ServiceRow]) -> Bool {
        let writes = rows.filter {
            WatchProfile.normalizeUUID($0.serviceUUID) == commandService
                && $0.characteristicUUID.map(WatchProfile.normalizeUUID) == commandWrite
                && $0.properties.contains("write")
        }
        let notifications = rows.filter {
            WatchProfile.normalizeUUID($0.serviceUUID) == commandService
                && $0.characteristicUUID.map(WatchProfile.normalizeUUID) == commandNotify
                && $0.properties.contains("notify")
        }
        return writes.count == 1 && notifications.count == 1
    }
}

enum VendorCapabilitySelection {
    enum Failure: Error { case conflictingObservations }
    struct Choice: Equatable {
        let capabilities: OppoTransportCapabilities
        let source: String
    }

    static func sameParameters(_ lhs: OppoTransportCapabilities, _ rhs: OppoTransportCapabilities) -> Bool {
        lhs.protocolVersion == rhs.protocolVersion && lhs.maxFrameSize == rhs.maxFrameSize
            && lhs.maxTransmissionUnit == rhs.maxTransmissionUnit && lhs.interval == rhs.interval
            && lhs.supportProtocol == rhs.supportProtocol
    }

    static func choose(response: OppoTransportCapabilities?, unsolicited: OppoTransportCapabilities?) throws -> Choice? {
        try validate(selected: nil, response: response, unsolicited: unsolicited, incoming: [])
        if let response { return Choice(capabilities: response, source: "POST_QUERY_MESSAGE_NO_TRANSACTION_ID") }
        if let unsolicited { return Choice(capabilities: unsolicited, source: "PRE_QUERY_OBSERVATION") }
        return nil
    }

    /// Validate the whole decoded notification before any contained identity
    /// proof can advance or complete the handshake. Late pre-query assemblies
    /// and coalesced capability messages must participate in the same check.
    static func validate(selected: OppoTransportCapabilities?, response: OppoTransportCapabilities?,
                         unsolicited: OppoTransportCapabilities?, incoming: [OppoTransportCapabilities]) throws {
        let observations = [selected, response, unsolicited].compactMap { $0 } + incoming
        guard let baseline = observations.first else { return }
        guard observations.allSatisfy({ sameParameters(baseline, $0) }) else {
            throw Failure.conflictingObservations
        }
    }
}

/// Safe observations only. No nonce, challenge, protobuf payload or session key
/// is stored in this report model.
struct VendorAuthenticationSnapshot: Codable, Equatable {
    var phase: OppoAuthentication.Phase = .idle
    var status = "NOT_ATTEMPTED"
    var capabilitySource: String?
    var selectedCapabilities: OppoTransportCapabilities?
    var identityVerified = false
    var keyExchangeVerified = false
    var transportAuthenticated = false
    var startedAt: Date?
    var completedAt: Date?
    var diagnostics = OppoAuthentication.Diagnostics()
    var error: OppoAuthentication.Failure?

    var phaseDescription: String {
        switch phase {
        case .idle: return "尚未开始身份认证"
        case .nonce: return "正在交换身份随机值"
        case .identity: return "正在验证手表身份挑战"
        case .sessionKeys: return "正在协商加密会话"
        case .sessionConfirm: return "正在确认加密协商结果"
        case .completed: return "传输身份认证通过 · 业务绑定尚未实现"
        case .failed: return error?.message ?? "身份认证未通过"
        case .cancelled: return "身份认证已中断"
        }
    }
}

/// Each receipt belongs to one logical command and records every physical ATT
/// fragment. A partial write can never acknowledge the entire command.
struct VendorCommandWriteSnapshot: Codable, Equatable {
    let commandID: Int
    let stage: String
    let frameCount: Int
    let queuedAt: Date
    var submittedFragments = 0
    var acknowledgedFragments = 0
    var callbackCount = 0
    var firstSubmittedAt: Date?
    var lastCallbackAt: Date?
    var error: VendorGATTTransport.Failure?
    var serviceID = 1
    var encrypted = false
    var queryAttempt: Int?

    var fullyAcknowledged: Bool {
        frameCount > 0 && acknowledgedFragments == frameCount && error == nil
    }

    mutating func recordSubmission(index: Int, at date: Date) -> Bool {
        guard error == nil, index == submittedFragments,
              acknowledgedFragments == index, index < frameCount else { return false }
        submittedFragments += 1
        if firstSubmittedAt == nil { firstSubmittedAt = date }
        return true
    }

    mutating func recordCallback(error failure: VendorGATTTransport.Failure?, at date: Date) -> Bool {
        guard error == nil, callbackCount < submittedFragments else { return false }
        callbackCount += 1
        lastCallbackAt = date
        if let failure { error = failure }
        else { acknowledgedFragments += 1 }
        return true
    }
}

/// GATT, capability observations, transport authentication and account binding
/// remain distinct even after a successful identity challenge.
struct VendorProbeSnapshot: Codable, Equatable {
    var mode = "TRANSPORT_IDENTITY_AND_INITIAL_SETUP"
    var profileAvailable = false
    var profileDiscoveryCompleted = false
    var status = "NOT_ATTEMPTED"
    var systemPairing = "NOT_OBSERVABLE_VIA_PUBLIC_CORE_BLUETOOTH_API"
    var vendorAuthentication = "NOT_ATTEMPTED"
    var accountBinding = "NOT_IMPLEMENTED"
    var commandNotificationsEnabled = false
    var fileNotificationsEnabled = false
    var commandNotificationActivation = "NOT_REQUESTED"
    var fileNotificationActivation = "NOT_REQUESTED"
    var commandNotificationCallbackCount = 0
    var fileNotificationCallbackCount = 0
    var capabilityQuery = VendorCapabilityQuery.Snapshot()
    var capabilityTimeoutReason: String?
    var requestSubmitted = false
    var attWriteAcknowledged = false
    var attWriteCallbackObserved = false
    var attWriteCompletedAt: Date?
    var attWriteError: VendorGATTTransport.Failure?
    var notificationCount = 0
    var preQueryNotificationCount = 0
    var receivedByteCount = 0
    var commandNotificationCount = 0
    var fileNotificationCount = 0
    var preQueryCommandNotificationCount = 0
    var preQueryFileNotificationCount = 0
    var commandReceivedByteCount = 0
    var fileReceivedByteCount = 0
    var startedAt: Date?
    var querySubmittedAt: Date?
    var responseAt: Date?
    var responseCorrelation: String?
    var capabilities: OppoTransportCapabilities?
    var decoderDiagnostics = OppoDecoderDiagnostics()
    var error: VendorGATTTransport.Failure?
    var authentication = VendorAuthenticationSnapshot()
    var initialSetup = OppoSetupSnapshot()
    var businessSessionState = "NOT_ESTABLISHED"
    var businessEncrypted: Bool?
    var ignoredBusinessMessageCount = 0
    var commandWrites: [VendorCommandWriteSnapshot] = []

    /// A query timeout describes the observed receiving stage, not a login or
    /// pairing failure. Zero traffic must remain visible rather than being
    /// conflated with a decoder rejection or an incomplete message.
    mutating func recordCapabilityTimeout(hasPendingData: Bool) -> VendorGATTTransport.Failure {
        let message: String
        if capabilityQuery.queuedAttempts > capabilityQuery.acknowledgedAttempts {
            capabilityTimeoutReason = "CAPABILITY_WRITE_INCOMPLETE"
            message = "能力协商等待超时，当前查询尚未取得完整 ATT 写入确认；身份验证未开始。"
        } else if capabilities != nil || decoderDiagnostics.unsolicitedCapabilities != nil {
            capabilityTimeoutReason = "CAPABILITIES_OBSERVED_NOT_ADVANCED"
            message = "已观测到完整能力，但当前协商尚未满足继续条件；请导出本轮报告。"
        } else if notificationCount == 0 {
            capabilityTimeoutReason = "NO_NOTIFICATIONS"
            message = "能力查询已写入，但本轮未收到任何手表通知（命令 0、文件 0）；身份验证未开始。请导出本轮报告，再断开重连。"
        } else if commandNotificationCount == 0 {
            capabilityTimeoutReason = "FILE_NOTIFICATIONS_ONLY"
            message = "已收到文件通道通知，但命令通道没有通知；尚未取得可用于身份验证的能力信息。"
        } else if commandReceivedByteCount == 0 {
            capabilityTimeoutReason = "EMPTY_COMMAND_NOTIFICATIONS"
            message = "命令通知已到达，但没有数据字节；尚未取得可用于身份验证的能力信息。"
        } else if hasPendingData {
            capabilityTimeoutReason = "INCOMPLETE_COMMAND_MESSAGE"
            message = "已收到命令数据，但仍有未收齐的消息；等待完整能力信息超时。"
        } else {
            capabilityTimeoutReason = "NO_VALID_CAPABILITIES"
            let detail = decoderDiagnostics.lastIssue.map { " 最近接收情况：\($0)。" } ?? ""
            message = "已收到命令数据，但没有可用于身份验证的完整有效能力信息。\(detail)"
        }
        return .init(phase: "PROTOCOL_RESPONSE", domain: "WatchLink.ProtocolProbe",
                     code: 1001, message: message)
    }

    /// Records only the initial capability query, once per connection. The
    /// monitor validates the connection generation and exact characteristic,
    /// so a late ATT result remains an independent observed fact.
    @discardableResult
    mutating func recordWriteCompletion(error: VendorGATTTransport.Failure?, at date: Date) -> Bool {
        guard requestSubmitted, !attWriteCallbackObserved else { return false }
        attWriteCallbackObserved = true
        attWriteCompletedAt = date
        attWriteAcknowledged = error == nil
        attWriteError = error
        return true
    }

    mutating func recordNotification(channel: VendorGATTTransport.Channel, byteCount: Int) {
        notificationCount += 1
        receivedByteCount += byteCount
        if !requestSubmitted { preQueryNotificationCount += 1 }
        switch channel {
        case .command:
            commandNotificationCount += 1
            commandReceivedByteCount += byteCount
            if !requestSubmitted { preQueryCommandNotificationCount += 1 }
        case .file:
            fileNotificationCount += 1
            fileReceivedByteCount += byteCount
            if !requestSubmitted { preQueryFileNotificationCount += 1 }
        }
    }

    var summary: String {
        switch status {
        case "SUBSCRIBING": return "正在开启手表消息通道 · 请完成系统配对提示"
        case "WAITING_FOR_RESPONSE":
            return commandNotificationCount == 0
                ? "能力查询 \(capabilityQuery.submittedAttempts)/\(capabilityQuery.maximumAttempts) · 命令通知 0 条，等待手表回应"
                : "正在等待能力信息 · 已收到 \(commandNotificationCount) 条命令通知"
        case "CAPABILITIES_RECEIVED_AUTH_PENDING": return "已收到手表协议回应 · 认证和绑定尚未完成"
        case "CAPABILITIES_WAITING_FOR_WRITE": return "已取得协议能力 · 等待查询写入确认"
        case "AUTHENTICATING": return authentication.phaseDescription
        case "AUTHENTICATED_BINDING_PENDING": return "传输身份认证通过 · 业务绑定尚未实现"
        case "READY_FOR_INITIAL_SETUP": return "身份验证已通过 · 可以继续首次设置"
        case "INITIAL_SETUP_RUNNING", "INITIAL_SETUP_OBSERVED", "INITIAL_SETUP_FAILED", "INITIAL_SETUP_INTERRUPTED":
            return initialSetup.summary
        case "BUSINESS_SESSION_FAILED": return "身份已通过，但业务通道已结束 · 请重连后继续"
        case "BUSINESS_SESSION_CLOSED": return "身份验证结果已保留 · 继续设置前请重连"
        case "FAILED": return "连接验证未完成 · 查看下方失败原因"
        case "INTERRUPTED": return "连接验证已中断 · 本次结果已保留"
        default:
            if !profileDiscoveryCompleted { return "连接后可检查手表协议通道" }
            return profileAvailable ? "发现可检查的手表协议通道" : "未发现完整的手表协议通道"
        }
    }

    var checkButtonTitle: String {
        switch status {
        case "SUBSCRIBING": return "正在开启手表消息通道…"
        case "WAITING_FOR_RESPONSE": return "正在查询协议能力…"
        case "CAPABILITIES_WAITING_FOR_WRITE": return "正在等待写入确认…"
        case "AUTHENTICATING": return authentication.phaseDescription + "…"
        case "AUTHENTICATED_BINDING_PENDING": return "身份验证已通过"
        case "READY_FOR_INITIAL_SETUP", "INITIAL_SETUP_RUNNING", "INITIAL_SETUP_OBSERVED", "INITIAL_SETUP_FAILED", "INITIAL_SETUP_INTERRUPTED", "BUSINESS_SESSION_FAILED", "BUSINESS_SESSION_CLOSED": return "身份验证已通过"
        case "FAILED": return "本次验证失败"
        case "INTERRUPTED": return "本次验证已中断"
        default: return "验证连接与身份"
        }
    }
}
