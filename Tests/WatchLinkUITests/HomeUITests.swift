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
        XCTAssertTrue(reportText.contains("TRANSPORT_CAPABILITY_QUERY_ONLY"))
        XCTAssertTrue(reportText.contains("NOT_OBSERVABLE_VIA_PUBLIC_CORE_BLUETOOTH_API"))

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "WatchLink-first-report-snapshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
