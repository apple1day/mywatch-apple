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
    var mode = "TRANSPORT_AND_IDENTITY_VERIFICATION"
    var profileAvailable = false
    var profileDiscoveryCompleted = false
    var status = "NOT_ATTEMPTED"
    var systemPairing = "NOT_OBSERVABLE_VIA_PUBLIC_CORE_BLUETOOTH_API"
    var vendorAuthentication = "NOT_ATTEMPTED"
    var accountBinding = "NOT_IMPLEMENTED"
    var commandNotificationsEnabled = false
    var fileNotificationsEnabled = false
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
    var commandWrites: [VendorCommandWriteSnapshot] = []

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
                ? "已提交协议查询 · 等待手表回应"
                : "正在等待能力信息 · 已收到 \(commandNotificationCount) 条命令通知"
        case "CAPABILITIES_RECEIVED_AUTH_PENDING": return "已收到手表协议回应 · 认证和绑定尚未完成"
        case "CAPABILITIES_WAITING_FOR_WRITE": return "已取得协议能力 · 等待查询写入确认"
        case "AUTHENTICATING": return authentication.phaseDescription
        case "AUTHENTICATED_BINDING_PENDING": return "传输身份认证通过 · 业务绑定尚未实现"
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
        case "FAILED": return "本次验证失败"
        case "INTERRUPTED": return "本次验证已中断"
        default: return "验证连接与身份"
        }
    }
}
