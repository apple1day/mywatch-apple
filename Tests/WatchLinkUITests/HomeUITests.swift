import XCTest

final class HomeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testHomeExplainsConnectionLimitsAndOffersActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        XCTAssertTrue(app.staticTexts["homeTitle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["compatibilityNotice"].exists)
        XCTAssertTrue(app.buttons["scanButton"].exists)
        XCTAssertTrue(app.buttons["exportReportButton"].exists)
        XCTAssertTrue(app.buttons["exportReportButton"].isEnabled)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "WatchLink-iPhone-home"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        // Recovery instructions must be reachable without a successful BLE
        // connection, including when the system rejects the initial attempt.
        app.buttons["guideButton"].tap()
        XCTAssertTrue(app.staticTexts["pairingRecoveryGuide"].waitForExistence(timeout: 5))
        let recoveryScreenshot = XCTAttachment(screenshot: app.screenshot())
        recoveryScreenshot.name = "WatchLink-system-pairing-recovery-guide"
        recoveryScreenshot.lifetime = .keepAlways
        add(recoveryScreenshot)
    }

    func testFirstReportContainsSnapshotAndExplicitUnsupportedStages() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let exportButton = app.buttons["exportReportButton"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 10))
        exportButton.tap()
        XCTAssertTrue(app.buttons["saveJSONButton"].waitForExistence(timeout: 5))

        let disclosure = app.buttons["reportDisclosure"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        XCTAssertTrue(disclosure.isHittable)
        disclosure.tap()
        let expanded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "已展开"), object: disclosure)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed)

        // Read the native text view's complete, displayed report once. The
        // human accessibility label is deliberately separate from its content.
        let preview = app.textViews
            .matching(NSPredicate(format: "identifier == %@", "reportJSONPreview")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let reportText = try XCTUnwrap(preview.value as? String,
                                      "The report text view must expose its actual JSON text.")
        XCTAssertTrue(reportText.contains("schemaVersion"))
        XCTAssertTrue(reportText.contains("UNAVAILABLE_VIA_PUBLIC_IOS_API"))
        XCTAssertTrue(reportText.contains("NOT_IMPLEMENTED"))
        XCTAssertTrue(reportText.contains("TRANSPORT_IDENTITY_AND_INITIAL_SETUP"))
        XCTAssertTrue(reportText.contains("NOT_OBSERVABLE_VIA_PUBLIC_CORE_BLUETOOTH_API"))
        XCTAssertTrue(reportText.contains("EXPERIMENTAL_PROTOCOL_3_TO_5"))
        // Native preview must expose a complete JSON snapshot, not an excerpt.
        let reportData = try XCTUnwrap(reportText.data(using: .utf8))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: reportData) as? [String: Any])
        XCTAssertEqual(report["schemaVersion"] as? Int, 7)
        let platform = try XCTUnwrap(report["platform"] as? [String: Any])
        let appVersion = try XCTUnwrap(platform["appVersion"] as? String)
        let appBuild = try XCTUnwrap(platform["appBuild"] as? String)
        XCTAssertEqual(appVersion, "0.4.2")
        XCTAssertEqual(appBuild, "7")
        // The visible export identity must describe these exact snapshot bytes.
        // It must not relabel an older report with the running app's version.
        let versionMetadata = app.staticTexts["reportVersionMetadata"]
        XCTAssertTrue(versionMetadata.exists)
        XCTAssertEqual(versionMetadata.label, "报告版本：\(appVersion) · 构建 \(appBuild) · schema 7")
        let generatedAt = try XCTUnwrap(report["generatedAt"] as? String)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: generatedAt))
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timeMetadata = app.staticTexts["reportGeneratedAtMetadata"]
        XCTAssertTrue(timeMetadata.exists)
        XCTAssertTrue(timeMetadata.label.contains(dateFormatter.string(from: date)))
        XCTAssertTrue(timeMetadata.label.contains("UTC"))
        let capabilities = try XCTUnwrap(report["capabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["initialSetup"] as? String, "EXPERIMENTAL_START_AND_STATE_OBSERVATION")
        let vendor = try XCTUnwrap(report["vendorProtocol"] as? [String: Any])
        XCTAssertEqual(vendor["businessSessionState"] as? String, "NOT_ESTABLISHED")
        XCTAssertEqual(vendor["accountBinding"] as? String, "NOT_IMPLEMENTED")
        let setup = try XCTUnwrap(vendor["initialSetup"] as? [String: Any])
        XCTAssertEqual(setup["status"] as? String, "NOT_STARTED")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "WatchLink-first-report-snapshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
