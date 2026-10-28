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

    // MARK: Helpers

    private func toolbarButton(_ label: String) -> XCUIElement {
        app.toolbars.buttons[label].firstMatch
    }

    /// The wizard's "Continue" (or "Continue anyway"), not "Continue to Verify".
    private func continueButton(in wizard: XCUIElement) -> XCUIElement {
        wizard.buttons.matching(NSPredicate(format: "(label == 'Continue' OR label == 'Continue anyway') AND isEnabled == true"))
            .firstMatch
    }
}
