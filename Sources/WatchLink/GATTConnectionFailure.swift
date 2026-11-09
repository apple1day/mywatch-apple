import Foundation
import CoreBluetooth

/// A system connection failure, separate from later capability or identity
/// checks. Store only bounded error identity and when/where it was observed;
/// NSError.userInfo and localized descriptions can contain device details.
struct GATTConnectionFailure: Codable, Equatable {
    enum Stage: String, Codable {
        case connect = "CONNECT"
        case disconnection = "DISCONNECT"
    }

    let stage: Stage
    let domain: String?
    let code: Int?
    let occurredAt: Date

    init(stage: Stage, error: Error?, occurredAt: Date = Date()) {
        self.stage = stage
        self.occurredAt = occurredAt
        if let error {
            let systemError = error as NSError
            domain = Self.safeDomain(systemError.domain)
            code = systemError.code
        } else {
            domain = nil
            code = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case stage, domain, code, occurredAt, errorIdentifier
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stage = try values.decode(Stage.self, forKey: .stage)
        domain = try values.decodeIfPresent(String.self, forKey: .domain).map(Self.safeDomain)
        code = try values.decodeIfPresent(Int.self, forKey: .code)
        occurredAt = try values.decode(Date.self, forKey: .occurredAt)
        // errorIdentifier is a readable derived label, never an input that
        // grants recovery instructions to an unrelated error domain/code.
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(stage, forKey: .stage)
        try values.encodeIfPresent(domain, forKey: .domain)
        try values.encodeIfPresent(code, forKey: .code)
        try values.encode(occurredAt, forKey: .occurredAt)
        try values.encode(errorIdentifier, forKey: .errorIdentifier)
    }

    /// The numeric value alone is insufficient: CBATTErrorDomain also has 14,
    /// with a different meaning. Use the public SDK symbol and exact domain.
    var requiresPairingRecovery: Bool {
        domain == CBErrorDomain && code == CBError.Code.peerRemovedPairingInformation.rawValue
    }

    var errorIdentifier: String {
        guard domain != nil, code != nil else { return "UNKNOWN" }
        return requiresPairingRecovery ? "PEER_REMOVED_PAIRING_INFORMATION" : "SYSTEM_ERROR"
    }

    var title: String {
        if requiresPairingRecovery { return "需要重新建立系统配对" }
        return stage == .connect ? "GATT 连接失败" : "GATT 连接已断开"
    }

    var message: String {
        if requiresPairingRecovery {
            return "系统报告手表端已移除配对信息，现有系统配对无法继续使用。请在 iPhone 的蓝牙设置中忽略这只手表，再重新扫描配对。"
        }
        if errorIdentifier == "UNKNOWN" {
            return "系统没有提供具体错误原因。请确认手表处于可连接状态，再重新扫描；本次连接结果已保留在报告中。"
        }
        return "系统蓝牙连接没有完成或已经中断。请确认手表处于可连接状态，再重新扫描；具体错误域和错误码已保留在报告中。"
    }

    /// This is a user-operated system recovery. The app cannot claim the old
    /// pairing was deleted or launch a new connection just by showing steps.
    var recoverySteps: [String] {
        guard requiresPairingRecovery else { return [] }
        return Self.pairingRecoverySteps
    }

    static var pairingRecoverySteps: [String] {
        return [
            "打开 iPhone“设置”→“蓝牙”，在“我的设备”中找到这只 OnePlus Watch。",
            "点击设备右侧 ⓘ，选择“忽略此设备”。这会删除 iPhone 保存的这只手表的系统配对记录。",
            "让手表停留在配对页面，回到 Watch Link 重新扫描并连接；出现系统配对提示时核对并确认。"
        ]
    }

    private static func safeDomain(_ value: String) -> String {
        // Preserve leading/trailing characters. Trimming a lookalike domain
        // must never turn it into the exact trusted Core Bluetooth domain.
        let prefix = value.unicodeScalars.prefix(160)
        let cleaned = prefix.map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar) ? "\u{fffd}" : String(scalar)
        }.joined()
        return value.unicodeScalars.count > 160 ? cleaned + "…" : cleaned
    }
}
