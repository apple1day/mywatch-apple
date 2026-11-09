import Foundation

/// Describes the bytes of one exported report, independently of the running
/// app's version or the time the save sheet happens to be presented. Only the
/// report's four metadata fields are decoded; device/account fields never
/// participate in the filename. The owner creates this once per snapshot.
struct ReportExportMetadata {
    let appVersion: String?
    let appBuild: String?
    let schemaVersion: Int?
    let generatedAt: Date?
    let suggestedFilename: String
    let generatedAtSummary: String

    var versionSummary: String {
        "报告版本：\(appVersion ?? "未知") · 构建 \(appBuild ?? "未知") · schema \(schemaVersion.map(String.init) ?? "未知")"
    }

    init(snapshot: Data, exportID: UUID = UUID(), timeZone: TimeZone = .current) {
        // Reports produced by this app are already bounded. Avoid parsing an
        // unexpectedly large input just to extract a display label.
        let envelope: Envelope?
        if snapshot.count <= 1024 * 1024 {
            envelope = try? JSONDecoder().decode(Envelope.self, from: snapshot)
        } else {
            envelope = nil
        }
        appVersion = Self.safeComponent(envelope?.platform?.appVersion, maximumLength: 32)
        appBuild = Self.safeComponent(envelope?.platform?.appBuild, maximumLength: 20)
        if let schema = envelope?.schemaVersion, (1...9999).contains(schema) {
            schemaVersion = schema
        } else {
            schemaVersion = nil
        }
        generatedAt = Self.parseDate(envelope?.generatedAt)

        let timestamp: String
        if let generatedAt {
            timestamp = Self.format(generatedAt, pattern: "yyyyMMdd-HHmmss", timeZone: timeZone)
            let displayed = Self.format(generatedAt, pattern: "yyyy-MM-dd HH:mm:ss", timeZone: timeZone)
            let seconds = timeZone.secondsFromGMT(for: generatedAt)
            let absolute = abs(seconds)
            let offset = String(format: "UTC%@%02d:%02d", seconds < 0 ? "-" : "+",
                                absolute / 3600, (absolute % 3600) / 60)
            generatedAtSummary = "生成于 \(displayed)（\(offset)）"
        } else {
            timestamp = "date-unknown"
            generatedAtSummary = "生成时间未知 · 报告未包含可识别的时间"
        }
        // An export-scoped random suffix distinguishes snapshots made within
        // the same second. It is stable for this snapshot and contains no hash
        // or other derivation of device names, identifiers or private payloads.
        let suffix = String(exportID.uuidString.prefix(8)).lowercased()
        suggestedFilename = "WatchLink-iOS-v\(appVersion ?? "unknown")-b\(appBuild ?? "unknown")-\(timestamp)-\(suffix)"
    }

    private static func safeComponent(_ value: String?, maximumLength: Int) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= maximumLength else { return nil }
        let bytes = Array(value.utf8)
        func alphanumeric(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        guard let first = bytes.first, alphanumeric(first),
              let last = bytes.last, alphanumeric(last),
              bytes.allSatisfy({ alphanumeric($0) || $0 == 45 || $0 == 46 }) else { return nil }
        return value
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty, value.utf8.count <= 64,
              value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func format(_ date: Date, pattern: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private struct Envelope: Decodable {
        let platform: Platform?
        let schemaVersion: Int?
        let generatedAt: String?

        enum CodingKeys: String, CodingKey { case platform, schemaVersion, generatedAt }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            platform = try? values.decode(Platform.self, forKey: .platform)
            schemaVersion = try? values.decode(Int.self, forKey: .schemaVersion)
            generatedAt = try? values.decode(String.self, forKey: .generatedAt)
        }
    }

    private struct Platform: Decodable {
        let appVersion: String?
        let appBuild: String?

        enum CodingKeys: String, CodingKey { case appVersion, appBuild }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            appVersion = try? values.decode(String.self, forKey: .appVersion)
            appBuild = try? values.decode(String.self, forKey: .appBuild)
        }
    }
}
