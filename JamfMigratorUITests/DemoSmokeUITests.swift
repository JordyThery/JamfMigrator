import XCTest
import JTKitUITestSupport

/// The release check's UI smoke tests (JTKit ROADMAP step 11), in demo mode:
/// Contoso's two demo tenants, the same answers every run, no real tenant,
/// nothing saved. Run one at a time by `scripts/release-check.sh`; minutes,
/// not hours.
final class DemoSmokeUITests: JTKitUITestCase {

    override var appName: String { "Jamf Migrator" }

    override func launchApp() {
        launchInDemo()
    }

    override func didLaunch() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "The main window did not open")
        // the guided tour opens on a first launch
        let skip = app.buttons["Skip Tour"].firstMatch
        if skip.waitForExistence(timeout: 3) { skip.click() }
        // room for the sidebar's types and the object list
        if app.windows.firstMatch.frame.height < 700 {
            let zoom = app.menuBars.menuItems["Zoom"].firstMatch
            if zoom.exists { zoom.click() }
        }
    }

    func test1Launch() {
        XCTAssertTrue(toolbarButton("Preview").waitForExistence(timeout: 20), "The main window has no Preview")
        XCTAssertTrue(toolbarButton("Clone tenant").exists, "The main window has no Clone tenant")
    }

    func test2About() {
        checkAbout()
    }

    func test3SettingsTabs() {
        checkSettingsTabs(["General", "Connections", "Secrets", "Export", "Updates"])
    }

    func test4ConnectionsEditor() {
        // Made-up values: the tenant lives only in this run's in-memory list.
        checkConnectionsEditor(service: "Jamf Platform API") { settings in
            let fields = settings.textFields.allElementsBoundByIndex
            guard let index = fields.firstIndex(where: { ($0.placeholderValue ?? "") == "From Jamf Account" }) else {
                return XCTFail("No Environment ID field")
            }
            self.type(UUID().uuidString, into: fields[index])
            if index + 1 < fields.count { self.type("jtktest-client", into: fields[index + 1]) }
            self.type("jtktest-secret", into: settings.secureTextFields.firstMatch)
        }
    }

    /// The Clone tenant wizard from Contoso Source to Contoso Destination:
    /// connect, prepare, Preview, Run, and a clean Verify.
    func test5MainTask() {
        tap(toolbarButton("Clone tenant"), timeout: 20)
        let wizard = app.sheets.firstMatch
        XCTAssertTrue(wizard.waitForExistence(timeout: 10), "The Clone tenant wizard did not open")

        // 1 Connect (the wizard tests both connections as it opens)
        let test = wizard.buttons["Test connections"]
        if test.waitForExistence(timeout: 3), test.isEnabled { test.click() }
        tap(continueButton(in: wizard), timeout: 60)
        // 2 Prepare
        tap(continueButton(in: wizard), timeout: 30)
        // 3 Preview
        tap(wizard.buttons["Preview"], timeout: 10)
        tap(continueButton(in: wizard), timeout: 180)
        // 4 Run
        tap(wizard.buttons["Run"], timeout: 10)
        tap(wizard.buttons["Continue to Verify"], timeout: 300)
        // 5 Verify
        tap(wizard.buttons["Verify"], timeout: 10)
        let clean = anyContaining("Verified: a second run would write nothing.")
        if !clean.waitForExistence(timeout: 180) {
            XCTFail("Verify isn't clean: \(anyContaining("objects differ or are missing").label)")
        }
        tap(wizard.buttons["Done"], timeout: 10)
    }

    func test6ActivityLog() {
        // Preview sends requests to the demo servers first.
        tap(toolbarButton("Preview"), timeout: 20)
        XCTAssertTrue(toolbarButton("Run").waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: toolbarButton("Run"))
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 180), .completed, "Preview didn't finish")
        checkActivityLog()
    }

    func test7DemoTitles() {
        tap(app.menuBars.menuBarItems[appName])
        tap(app.menuItems["About \(appName)"])
        XCTAssertTrue(window(titled: "About \(appName)").waitForExistence(timeout: 10))
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(window(titled: "Activity Log").waitForExistence(timeout: 10))
        openSettings()
        checkDemoTitles()
    }

    /// Ticks are what Run carries out: Preview Categories, untick every
    /// object, tick one, and Run offers exactly that one change.
    func test8RunTakesOnlyTickedObjects() {
        previewCategoriesOnly()
        // show the Categories objects (the row, not its checkbox)
        let row = app.outlines["Sidebar"].outlineRows.containing(.checkBox, identifier: "Categories").firstMatch
        let categoriesRow = row.exists ? row
            : app.outlines["Sidebar"].outlineRows.containing(NSPredicate(format: "label == 'Categories'")).firstMatch
        XCTAssertTrue(categoriesRow.waitForExistence(timeout: 10), "No Categories row")
        categoriesRow.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).click()
        tap(app.toolbars.menuButtons["Select"].firstMatch, timeout: 10)
        tap(app.menuItems["Uncheck all"].firstMatch, timeout: 5)
        let runButton = toolbarButton("Run")
        XCTAssertTrue(runButton.waitForExistence(timeout: 5))
        XCTAssertFalse(runButton.isEnabled, "Run is on with nothing ticked")
        // the first object row that can be ticked
        let objectRow = app.checkBoxes.matching(NSPredicate(format: "label == '' AND isEnabled == true")).firstMatch
        tap(objectRow, timeout: 10)
        tap(runButton, timeout: 10)
        let copyOne = dialogButton("Copy 1 changes")
        XCTAssertTrue(copyOne.waitForExistence(timeout: 10), "The confirmation doesn't offer exactly the one ticked change")
        copyOne.click()
        XCTAssertTrue(anyContaining("Results").waitForExistence(timeout: 60), "The run didn't finish")
        tap(app.buttons["Close"].firstMatch, timeout: 10)
    }

    /// Changing the selected types after Preview turns Run off until a new Preview.
    func test9SelectionChangeNeedsNewPreview() {
        previewCategoriesOnly()
        let scripts = app.checkBoxes["Scripts"].firstMatch
        scrollIntoView(scripts)
        tap(scripts, timeout: 10)
        XCTAssertFalse(toolbarButton("Run").isEnabled, "Run is still on after the selection changed")
        XCTAssertTrue(anyContaining("The selected types changed since Preview").waitForExistence(timeout: 5),
                      "The window doesn't say why Run is off")
    }

    // MARK: Helpers

    /// Only Categories selected, then Preview until Run can be clicked.
    private func previewCategoriesOnly() {
        tap(app.links["Uncheck all"].firstMatch, timeout: 20)
        let categories = app.checkBoxes["Categories"].firstMatch
        scrollIntoView(categories)
        tap(categories, timeout: 10)
        tap(toolbarButton("Preview"), timeout: 10)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: toolbarButton("Run"))
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 120), .completed, "Preview found nothing to copy in Categories")
    }

    private func toolbarButton(_ label: String) -> XCUIElement {
        app.toolbars.buttons[label].firstMatch
    }

    /// The wizard's "Continue" (or "Continue anyway"), not "Continue to Verify".
    private func continueButton(in wizard: XCUIElement) -> XCUIElement {
        wizard.buttons.matching(NSPredicate(format: "(label == 'Continue' OR label == 'Continue anyway') AND isEnabled == true"))
            .firstMatch
    }
}
