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

/// A capability reply is useful diagnostic evidence, never a successful bond.
struct VendorProbeSnapshot: Codable, Equatable {
    var mode = "TRANSPORT_CAPABILITY_QUERY_ONLY"
    var profileAvailable = false
    var profileDiscoveryCompleted = false
    var status = "NOT_ATTEMPTED"
    var systemPairing = "NOT_OBSERVABLE_VIA_PUBLIC_CORE_BLUETOOTH_API"
    var vendorAuthentication = "NOT_IMPLEMENTED"
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

    /// One command is submitted per connection. The monitor first validates the
    /// connection generation and exact write characteristic, even after parsing
    /// has finished, so a late ATT result remains an independent observed fact.
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
        case "FAILED": return "协议检查未完成 · 请导出报告查看失败阶段"
        case "INTERRUPTED": return "协议检查已中断 · 本次结果已保留"
        default:
            if !profileDiscoveryCompleted { return "连接后可检查手表协议通道" }
            return profileAvailable ? "发现可检查的手表协议通道" : "未发现完整的手表协议通道"
        }
    }
}
