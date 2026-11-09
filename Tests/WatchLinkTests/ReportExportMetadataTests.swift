import Foundation
import XCTest
@testable import WatchLink

final class ReportExportMetadataTests: XCTestCase {
    private let exportID = UUID(uuidString: "12345678-1234-5678-1234-567812345678")!
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let utc = TimeZone(secondsFromGMT: 0)!

    func testOldReportKeepsItsActualVersionAndOriginalGenerationTime() throws {
        let report = try data(version: "0.2.0", build: "2", schema: 2,
                              generatedAt: "2026-11-09T06:11:32Z")
        let metadata = ReportExportMetadata(snapshot: report, exportID: exportID, timeZone: shanghai)
        XCTAssertEqual(metadata.appVersion, "0.2.0")
        XCTAssertEqual(metadata.appBuild, "2")
        XCTAssertEqual(metadata.schemaVersion, 2)
        XCTAssertEqual(metadata.versionSummary, "报告版本：0.2.0 · 构建 2 · schema 2")
        XCTAssertEqual(metadata.generatedAtSummary, "生成于 2026-11-09 14:11:32（UTC+08:00）")
        XCTAssertEqual(metadata.suggestedFilename, "WatchLink-iOS-v0.2.0-b2-20261109-141132-12345678")
        XCTAssertFalse(metadata.suggestedFilename.contains("0.4.1"))
    }

    func testFilenameRemainsStableForOneSnapshotAndDistinctAcrossSameSecondExports() throws {
        let report = try data()
        let first = ReportExportMetadata(snapshot: report, exportID: exportID, timeZone: utc)
        let same = ReportExportMetadata(snapshot: report, exportID: exportID, timeZone: utc)
        let anotherID = UUID(uuidString: "87654321-1234-5678-1234-567812345678")!
        let second = ReportExportMetadata(snapshot: report, exportID: anotherID, timeZone: utc)
        XCTAssertEqual(first.suggestedFilename, same.suggestedFilename)
        XCTAssertNotEqual(first.suggestedFilename, second.suggestedFilename)
        XCTAssertEqual(first.suggestedFilename, "WatchLink-iOS-v0.4.1-b6-20261109-101500-12345678")
    }

    func testMalformedOrMissingMetadataNeverInventsCurrentAppOrTime() throws {
        let invalidCases = [Data("invalid JSON".utf8), Data("[]".utf8), Data("{}".utf8),
                            try JSONSerialization.data(withJSONObject: [
                                "platform": ["appVersion": 41, "appBuild": true],
                                "schemaVersion": true, "generatedAt": 12345
                            ])]
        for report in invalidCases {
            let metadata = ReportExportMetadata(snapshot: report, exportID: exportID, timeZone: utc)
            XCTAssertNil(metadata.appVersion)
            XCTAssertNil(metadata.appBuild)
            XCTAssertNil(metadata.schemaVersion)
            XCTAssertNil(metadata.generatedAt)
            XCTAssertEqual(metadata.versionSummary, "报告版本：未知 · 构建 未知 · schema 未知")
            XCTAssertEqual(metadata.generatedAtSummary, "生成时间未知 · 报告未包含可识别的时间")
            XCTAssertEqual(metadata.suggestedFilename, "WatchLink-iOS-vunknown-bunknown-date-unknown-12345678")
        }
    }

    func testValidMetadataFieldsSurviveOtherMissingOrInvalidMetadata() throws {
        let report = try JSONSerialization.data(withJSONObject: [
            "platform": ["appVersion": "0.4.1"],
            "schemaVersion": 6, "generatedAt": "not-a-date"
        ])
        let metadata = ReportExportMetadata(snapshot: report, exportID: exportID, timeZone: utc)
        XCTAssertEqual(metadata.appVersion, "0.4.1")
        XCTAssertNil(metadata.appBuild)
        XCTAssertEqual(metadata.schemaVersion, 6)
        XCTAssertNil(metadata.generatedAt)
        XCTAssertEqual(metadata.suggestedFilename, "WatchLink-iOS-v0.4.1-bunknown-date-unknown-12345678")
    }

    func testFilenameRejectsUnsafeOrUnboundedVersionComponents() throws {
        for invalid in ["../device", "..", "0.4.1\n", "private device", "手表", String(repeating: "1", count: 40)] {
            let report = try data(version: invalid, build: invalid)
            let metadata = ReportExportMetadata(snapshot: report, exportID: exportID, timeZone: utc)
            XCTAssertNil(metadata.appVersion)
            XCTAssertNil(metadata.appBuild)
            XCTAssertTrue(metadata.suggestedFilename.hasPrefix("WatchLink-iOS-vunknown-bunknown-"))
            XCTAssertTrue(metadata.suggestedFilename.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0)
            })
        }
        let valid = ReportExportMetadata(snapshot: try data(version: "0.4.1-beta.2", build: "6"),
                                         exportID: exportID, timeZone: utc)
        XCTAssertEqual(valid.appVersion, "0.4.1-beta.2")
        XCTAssertEqual(valid.appBuild, "6")
    }

    func testExplicitOffsetAndFractionalSecondsDescribeSameInstantInChosenZone() throws {
        let report = try data(generatedAt: "2026-11-09T18:15:00.123+08:00")
        let local = ReportExportMetadata(snapshot: report, exportID: exportID, timeZone: shanghai)
        let universal = ReportExportMetadata(snapshot: report, exportID: exportID, timeZone: utc)
        XCTAssertEqual(local.generatedAt, universal.generatedAt)
        XCTAssertEqual(local.generatedAtSummary, "生成于 2026-11-09 18:15:00（UTC+08:00）")
        XCTAssertEqual(universal.generatedAtSummary, "生成于 2026-11-09 10:15:00（UTC+00:00）")
        XCTAssertTrue(local.suggestedFilename.contains("20261109-181500"))
        XCTAssertTrue(universal.suggestedFilename.contains("20261109-101500"))
    }

    func testDeviceAndPrivateDataNeverParticipateInFilenameOrMetadataLabels() throws {
        let original = try data()
        var changed = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        changed["selectedDevice"] = ["name": "PRIVATE-WATCH", "anonymousID": "secret-device-id"]
        changed["vendorProtocol"] = ["privatePayload": "DO-NOT-USE-FOR-FILENAME"]
        let changedBytes = try JSONSerialization.data(withJSONObject: changed)
        let first = ReportExportMetadata(snapshot: original, exportID: exportID, timeZone: utc)
        let second = ReportExportMetadata(snapshot: changedBytes, exportID: exportID, timeZone: utc)
        XCTAssertEqual(first.suggestedFilename, second.suggestedFilename)
        XCTAssertEqual(first.versionSummary, second.versionSummary)
        XCTAssertEqual(first.generatedAtSummary, second.generatedAtSummary)
    }

    private func data(version: String = "0.4.1", build: String = "6", schema: Int = 6,
                      generatedAt: String = "2026-11-09T10:15:00Z") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "platform": ["appVersion": version, "appBuild": build],
            "schemaVersion": schema, "generatedAt": generatedAt
        ])
    }
}
