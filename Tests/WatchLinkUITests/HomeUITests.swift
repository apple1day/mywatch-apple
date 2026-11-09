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

        let disclosure = app.descendants(matching: .any)
            .matching(identifier: "reportDisclosure").firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        disclosure.tap()

        let preview = app.descendants(matching: .any)
            .matching(identifier: "reportJSONPreview").firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.label.contains("schemaVersion"))
        XCTAssertTrue(preview.label.contains("UNAVAILABLE_VIA_PUBLIC_IOS_API"))
        XCTAssertTrue(preview.label.contains("NOT_IMPLEMENTED"))

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "WatchLink-first-report-snapshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
