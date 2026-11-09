import Foundation
import CryptoKit

/// Public identifiers observed in the Android companion. They are not GATT UUIDs.
enum WatchProfile {
    static let commandRFCOMM = "db764ac8-4b08-7f25-aafe-59d03c27bae3"
    static let dataRFCOMM = "db764ac8-4b08-7f25-aafe-59d03c27bae4"
    static let sourceAPKHash = "5b9ce81310236a3c02a603f4032ab9bc9ad482e95abcc1a654aeef4c31933ce1"
    static let classicUnavailable = "UNAVAILABLE_VIA_PUBLIC_IOS_API"
    static let notImplemented = "NOT_IMPLEMENTED"

    static func isNameCandidate(_ name: String?) -> Bool {
        guard let name else { return false }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return value == "ONEPLUS WATCH"
            || value.hasPrefix("W301CN") || value.hasPrefix("W501CN")
            || value.range(of: "^ONEPLUS WATCH\\W+[0-9A-F]+$", options: .regularExpression) != nil
    }

    static func normalizeUUID(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.count == 36, value.hasPrefix("0000"), value.hasSuffix("-0000-1000-8000-00805F9B34FB") {
            let start = value.index(value.startIndex, offsetBy: 4)
            let end = value.index(start, offsetBy: 4)
            return String(value[start..<end])
        }
        return value
    }

    static func standardLabel(_ uuid: String) -> String? {
        switch normalizeUUID(uuid) {
        case "2A19": return "电量"
        case "2A24": return "型号"
        case "2A26": return "固件版本"
        case "2A28": return "软件版本"
        case "2A29": return "制造商"
        default: return nil
        }
    }

    static func canReadStandard(characteristic: String, service: String) -> Bool {
        let characteristic = normalizeUUID(characteristic)
        let service = normalizeUUID(service)
        if characteristic == "2A19" { return service == "180F" }
        return ["2A24", "2A26", "2A28", "2A29"].contains(characteristic) && service == "180A"
    }

    static func standardValue(uuid: String, data: Data?) -> (value: String, status: String) {
        guard standardLabel(uuid) != nil else { return ("未读取非白名单字段", "NOT_READ") }
        guard let data, !data.isEmpty else { return ("空值", "EMPTY") }
        if normalizeUUID(uuid) == "2A19" {
            guard data.count == 1, let battery = data.first, battery <= 100 else {
                return ("非有效标准电量值", "INVALID")
            }
            return ("\(battery)%", "VALID")
        }
        guard let value = String(data: data, encoding: .utf8) else {
            return ("非有效 UTF-8 字符串", "INVALID")
        }
        let text = safeText(value.replacingOccurrences(of: "\0", with: " "), limit: 120)
        return text.isEmpty ? ("空值", "EMPTY") : (text, "VALID")
    }

    static func safeText(_ text: String, limit: Int = 80) -> String {
        let clean = text.unicodeScalars.map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > limit ? String(clean.prefix(limit)) + "…" : clean
    }

    static func anonymousID(_ identifier: UUID, salt: String) -> String {
        let bytes = Data((salt + ":" + identifier.uuidString).utf8)
        return SHA256.hash(data: bytes).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

/// Internal identifiers are intentionally not Codable. Reports use a separate type.
struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int?
    var isCandidate: Bool
    var advertisedServices: [String]
    var isConnectable: Bool?
}

struct ServiceRow: Identifiable, Codable, Equatable {
    let id: String
    let serviceUUID: String
    let characteristicUUID: String?
    let properties: [String]
}

struct StandardReading: Identifiable, Codable, Equatable {
    var id: String { uuid }
    let uuid: String
    let label: String
    let value: String
    let status: String
}

struct ProbeEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let message: String

    init(message: String, timestamp: Date = Date()) {
        id = UUID()
        self.timestamp = timestamp
        self.message = message
    }
}

struct DeviceSnapshot: Codable, Equatable {
    let anonymousID: String
    let name: String
    let isNameCandidate: Bool
    let modelVerification: String
    let rssi: Int?
    let advertisedServiceUUIDs: [String]
    let advertisedConnectable: Bool?

    init(device: DiscoveredDevice, salt: String) {
        anonymousID = WatchProfile.anonymousID(device.id, salt: salt)
        name = device.name
        isNameCandidate = device.isCandidate
        modelVerification = "NOT_PERFORMED"
        rssi = device.rssi
        advertisedServiceUUIDs = device.advertisedServices
        advertisedConnectable = device.isConnectable
    }
}

struct PlatformSnapshot: Codable, Equatable {
    let system: String
    let systemVersion: String
    let deviceType: String
    let appVersion: String
    let appBuild: String
}

struct CapabilitySnapshot: Codable, Equatable {
    let gatt: String
    let classicRFCOMM: String
    let vendorAuthentication: String
    let accountBinding: String
    let initialSetup: String
    let healthSync: String
    let notifications: String
    let commandRFCOMMUUID: String
    let dataRFCOMMUUID: String

    init() {
        gatt = "CORE_BLUETOOTH_IDENTITY_AND_INITIAL_SETUP"
        classicRFCOMM = WatchProfile.classicUnavailable
        vendorAuthentication = "EXPERIMENTAL_PROTOCOL_3_TO_5"
        accountBinding = WatchProfile.notImplemented
        initialSetup = "EXPERIMENTAL_START_AND_STATE_OBSERVATION"
        healthSync = WatchProfile.notImplemented
        notifications = WatchProfile.notImplemented
        commandRFCOMMUUID = WatchProfile.commandRFCOMM
        dataRFCOMMUUID = WatchProfile.dataRFCOMM
    }
}

struct ObservationSnapshot: Codable, Equatable {
    let stateText: String
    let bluetoothState: String
    let scanningAtExport: Bool
    let connectingAtExport: Bool
    let gattConnectedAtExport: Bool
    let gattConnectionObservedThisAttempt: Bool
    let result: String
}

struct ProbeReport: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date
    let platform: PlatformSnapshot
    let capabilities: CapabilitySnapshot
    let selectedDevice: DeviceSnapshot?
    let observations: ObservationSnapshot
    let services: [ServiceRow]
    let standardReadings: [StandardReading]
    let events: [ProbeEvent]
    let privacy: String
    var vendorProtocol: VendorProbeSnapshot? = nil

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        // All fields use finite scalar values. Preserve an explicit error if encoding ever fails.
        return (try? encoder.encode(self)) ?? Data("{\"schemaVersion\":1,\"error\":\"REPORT_ENCODING_FAILED\"}".utf8)
    }
}
