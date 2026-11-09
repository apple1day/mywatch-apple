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

    func testFirstReportContainsSnapshotAndExplicitUnsupportedStages() {
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

        // Match the Text's actual identifier, rather than asking every element
        // type for all identifier/label/value aliases in the accessibility tree.
        let preview = app.staticTexts
            .matching(NSPredicate(format: "identifier == %@", "reportJSONPreview")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let reportText = preview.label
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
