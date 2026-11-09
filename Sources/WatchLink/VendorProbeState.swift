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
    var notificationCount = 0
    var preQueryNotificationCount = 0
    var receivedByteCount = 0
    var startedAt: Date?
    var responseAt: Date?
    var capabilities: OppoTransportCapabilities?
    var error: VendorGATTTransport.Failure?

    var summary: String {
        switch status {
        case "SUBSCRIBING": return "正在开启手表消息通道 · 请完成系统配对提示"
        case "WAITING_FOR_RESPONSE": return "已发送协议查询 · 等待手表回应"
        case "CAPABILITIES_RECEIVED_AUTH_PENDING": return "已收到手表协议回应 · 认证和绑定尚未完成"
        case "FAILED": return "协议检查未完成 · 请导出报告查看失败阶段"
        case "INTERRUPTED": return "协议检查已中断 · 本次结果已保留"
        default:
            if !profileDiscoveryCompleted { return "连接后可检查手表协议通道" }
            return profileAvailable ? "发现可检查的手表协议通道" : "未发现完整的手表协议通道"
        }
    }
}
