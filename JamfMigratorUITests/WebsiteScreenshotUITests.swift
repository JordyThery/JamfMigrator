import XCTest
import JTKitUITestSupport

/// The three screenshots on jordythery.be, taken in demo mode from
/// "Contoso Source (Demo)" to "Contoso Destination (Demo)". Not part of the
/// release check (it runs only `DemoSmokeUITests` and `LiveUITests`), and the
/// app's own scheme runs no UI tests, so ⌘U never starts this. Run it by name;
/// the screenshots are kept in the test result as "jamf-migrator-preview",
/// "jamf-migrator-diff" and "jamf-migrator-confirm". Run is never clicked.
final class WebsiteScreenshotUITests: JTKitUITestCase {

    override var appName: String { "Jamf Migrator" }

    override var demoLaunchArguments: [String] {
        ["-checksForUpdates", "NO", "-AppleInterfaceStyle", "Light"]
    }

    override func launchApp() {
        launchInDemo()
    }

    override func setUpWithError() throws {
        try XCTSkipIf(Self.isReleaseCheck, "Website screenshots aren't part of the release check")
        try super.setUpWithError()
    }

    func testWebsiteScreenshots() {
        let main = app.windows.firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 20), "The main window did not open")
        // the guided tour opens on a first launch
        let skip = app.buttons["Skip Tour"].firstMatch
        if skip.waitForExistence(timeout: 3) { skip.click() }
        zoom(main)

        // Preview Categories only: one to create, one to update, one unchanged.
        tap(app.links["Uncheck All"].firstMatch, timeout: 20)
        let categories = app.checkBoxes["Categories"].firstMatch
        scrollIntoView(categories)
        tap(categories, timeout: 10)
        tap(toolbarButton("Preview"), timeout: 10)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: toolbarButton("Run"))
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 120), .completed, "Preview didn't finish")
        openCategories()
        XCTAssertTrue(anyContaining("to update").waitForExistence(timeout: 10), "The object list shows no counts")
        sleep(2)
        keep(main.screenshot(), named: "jamf-migrator-preview")

        // The Update row's field-level differences.
        let update = app.outlines.cells.containing(NSPredicate(format: "label == 'Contoso Security' OR value == 'Contoso Security'")).firstMatch
        tap(update.exists ? update : app.staticTexts["Contoso Security"].firstMatch, timeout: 10)
        XCTAssertTrue(anyContaining("Differences (source → destination)").waitForExistence(timeout: 10), "No differences for the Update row")
        sleep(2)
        keep(main.screenshot(), named: "jamf-migrator-diff")

        // The confirmation before Run, then Cancel: nothing is written.
        tap(toolbarButton("Run"), timeout: 10)
        let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Copy ' AND (label ENDSWITH ' Change' OR label ENDSWITH ' Changes')")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Run doesn't confirm")
        sleep(2)
        keep(main.screenshot(), named: "jamf-migrator-confirm")
        tap(dialogButton("Cancel"), timeout: 5)
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5), "The confirmation stayed after Cancel")
    }

    // MARK: Helpers

    /// Zooms the window to fill the screen (drags don't move or resize it).
    private func zoom(_ window: XCUIElement) {
        let before = window.frame
        tap(app.menuBars.menuBarItems["Window"].firstMatch)
        tap(app.menuItems["Zoom"].firstMatch)
        sleep(1)
        if window.frame.height <= before.height {
            // The window was already zoomed: zooming toggled it back.
            tap(app.menuBars.menuBarItems["Window"].firstMatch)
            tap(app.menuItems["Zoom"].firstMatch)
            sleep(1)
        }
    }

    /// Shows the Categories objects (the row, not its checkbox).
    private func openCategories() {
        let row = app.outlines["Sidebar"].outlineRows.containing(.checkBox, identifier: "Categories").firstMatch
        let categoriesRow = row.exists ? row
            : app.outlines["Sidebar"].outlineRows.containing(NSPredicate(format: "label == 'Categories'")).firstMatch
        XCTAssertTrue(categoriesRow.waitForExistence(timeout: 10), "No Categories row")
        categoriesRow.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).click()
    }

    private func toolbarButton(_ label: String) -> XCUIElement {
        app.toolbars.buttons[label].firstMatch
    }

    private func keep(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
