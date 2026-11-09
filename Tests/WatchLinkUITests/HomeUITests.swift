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
        XCTAssertEqual(report["schemaVersion"] as? Int, 5)
        let platform = try XCTUnwrap(report["platform"] as? [String: Any])
        XCTAssertEqual(platform["appVersion"] as? String, "0.4.0")
        XCTAssertEqual(platform["appBuild"] as? String, "5")
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
