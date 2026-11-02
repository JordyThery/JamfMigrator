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
        XCTAssertTrue(toolbarButton("Clone Tenant").exists, "The main window has no Clone Tenant")
    }

    func test2About() {
        checkAbout()
    }

    func test3SettingsTabs() {
        checkSettingsTabs(["Connections", "Secrets", "Export", "Updates"])
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

    /// The Clone Tenant wizard from Contoso Source to Contoso Destination:
    /// connect, prepare, Preview, Run (confirmed like the toolbar's Run), and a
    /// clean Verify.
    func test5MainTask() {
        tap(toolbarButton("Clone Tenant"), timeout: 20)
        let wizard = app.sheets.firstMatch
        XCTAssertTrue(wizard.waitForExistence(timeout: 10), "The Clone Tenant wizard did not open")

        // 1 Connect (the wizard tests both connections as it opens)
        let test = wizard.buttons["Test Connections"]
        if test.waitForExistence(timeout: 3), test.isEnabled { test.click() }
        tap(continueButton(in: wizard), timeout: 60)
        // 2 Prepare
        tap(continueButton(in: wizard), timeout: 30)
        // 3 Preview
        tap(wizard.buttons["Preview"], timeout: 10)
        tap(continueButton(in: wizard), timeout: 180)
        // 4 Run
        tap(wizard.buttons["Run"], timeout: 10)
        // the same confirmation as the toolbar's Run, naming the count
        let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Copy ' AND (label ENDSWITH ' Change' OR label ENDSWITH ' Changes')")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "The wizard's Run doesn't confirm")
        confirm.click()
        tap(wizard.buttons["Continue to Verify"], timeout: 300)
        // 5 Verify
        tap(wizard.buttons["Verify"], timeout: 10)
        let clean = anyContaining("Verified: a second run would write nothing.")
        if !clean.waitForExistence(timeout: 180) {
            XCTFail("Verify isn't clean: \(anyContaining("missing").label)")
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

    /// Checked objects are what Run carries out: Preview Categories, uncheck
    /// every object, check one, and Run offers exactly that one change.
    func test8RunTakesOnlyCheckedObjects() {
        previewCategoriesOnly()
        openCategories()
        tap(app.toolbars.menuButtons["Select"].firstMatch, timeout: 10)
        tap(app.menuItems["Uncheck All"].firstMatch, timeout: 5)
        let runButton = toolbarButton("Run")
        XCTAssertTrue(runButton.waitForExistence(timeout: 5))
        XCTAssertFalse(runButton.isEnabled, "Run is on with nothing checked")
        // the first object row that can be checked
        let objectRow = app.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH 'Include ' AND isEnabled == true")).firstMatch
        tap(objectRow, timeout: 10)
        tap(runButton, timeout: 10)
        let copyOne = dialogButton("Copy 1 Change")
        XCTAssertTrue(copyOne.waitForExistence(timeout: 10), "The confirmation doesn't offer exactly the one checked change")
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

    /// Regression #1: an unsaved Protected change asks Save / Discard /
    /// Cancel before Settings closes or another tab opens; saved, the
    /// tenant shows its lock.
    func test10UnsavedProtectedAsks() {
        let settings = openSettings()
        tap(settings.toolbars.buttons["Connections"].firstMatch, timeout: 10)
        let add = settings.buttons["Add Connection"].exists ? settings.buttons["Add Connection"] : settings.menuButtons["Add Connection"]
        tap(add, timeout: 10)
        tap(app.menuItems["Jamf Platform API"].firstMatch)
        let name = "JTKTEST Protected \(Int.random(in: 1000...9999))"
        let nameField = settings.textFields["Name"].firstMatch.waitForExistence(timeout: 3)
            ? settings.textFields["Name"].firstMatch
            : settings.textFields.matching(NSPredicate(format: "value BEGINSWITH 'New '")).firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "The new tenant's editor didn't open")
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText(name)
        let fields = settings.textFields.allElementsBoundByIndex
        if let index = fields.firstIndex(where: { ($0.placeholderValue ?? "") == "From Jamf Account" }) {
            type(UUID().uuidString, into: fields[index])
            if index + 1 < fields.count { type("jtktest-client", into: fields[index + 1]) }
        }
        type("jtktest-secret", into: settings.secureTextFields.firstMatch)
        tap(settings.buttons["Save"], timeout: 5)

        // Protected on, not saved: switching tabs asks
        let protected = protectedToggle(in: settings)
        scrollIntoView(protected)
        tap(protected, timeout: 5)
        tap(settings.toolbars.buttons["Export"].firstMatch, timeout: 5)
        XCTAssertTrue(anyContaining("Save the changes to").waitForExistence(timeout: 5),
                      "Switching tabs with an unsaved Protected change didn't ask")
        let tabQuestion = settings.sheets.firstMatch
        tap(tabQuestion.exists ? tabQuestion.buttons["Cancel"].firstMatch : dialogButton("Cancel"), timeout: 5)
        // closing the window asks too; Save keeps the change
        settings.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(anyContaining("Save the changes to").waitForExistence(timeout: 5),
                      "Closing Settings with an unsaved Protected change didn't ask")
        // the question's Save, not the editor's own Save button
        let question = settings.sheets.firstMatch
        tap(question.exists ? question.buttons["Save"].firstMatch : dialogButton("Save"), timeout: 5)
        XCTAssertTrue(question.waitForNonExistence(timeout: 5), "The question stayed after Save")
        XCTAssertTrue(settings.waitForNonExistence(timeout: 10), "Settings didn't close after Save")

        // reopened: still Protected; then the throwaway tenant goes
        let again = openSettings()
        tap(again.toolbars.buttons["Connections"].firstMatch, timeout: 10)
        let row = again.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", name, name)).firstMatch
        tap(row, timeout: 10)
        let saved = protectedToggle(in: again)
        scrollIntoView(saved)
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        XCTAssertEqual((saved.value as? NSNumber)?.intValue, 1, "Protected wasn't saved")
        tap(again.buttons["Delete Connection"], timeout: 5)
        tap(dialogButton("Delete"))
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "The throwaway tenant wasn't deleted")
        close(again)
    }

    /// Help › Guided Tour replays the tour; Preview is off while it runs.
    func test11GuidedTour() {
        tap(app.menuBars.menuBarItems["Help"])
        tap(app.menuItems["Guided Tour"].firstMatch)
        let skip = app.buttons["Skip Tour"].firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 10), "The tour didn't start")
        XCTAssertFalse(toolbarButton("Preview").isEnabled, "Preview is on during the tour")
        skip.click()
        XCTAssertTrue(skip.waitForNonExistence(timeout: 5), "Skip Tour didn't end the tour")
        XCTAssertTrue(toolbarButton("Preview").isEnabled, "Preview stays off after the tour")
    }

    /// The Connection menu chooses the tenants: the same one for Source and
    /// Destination turns Preview off; another tenant clears the plan.
    func test12ConnectionMenu() {
        previewCategoriesOnly()
        let destinationItems = connectionMenuItems("Contoso Destination (Demo)")
        XCTAssertGreaterThanOrEqual(destinationItems.count, 2, "Contoso Destination isn't offered for Source and Destination")
        destinationItems[0].click()   // as Source
        XCTAssertTrue(anyContaining("No Preview Yet").waitForExistence(timeout: 10), "The plan stayed after the tenants changed")
        XCTAssertFalse(toolbarButton("Preview").isEnabled, "Preview is on with the same tenant twice")
        connectionMenuItems("Contoso Source (Demo)")[0].click()
        XCTAssertTrue(toolbarButton("Preview").isEnabled, "Preview stays off after choosing Contoso Source again")
    }

    /// After Preview the sidebar shows the permission check: both versions
    /// and that the destination isn't empty.
    func test13PreflightSummary() {
        previewCategoriesOnly()
        XCTAssertTrue(anyContaining(" → ").waitForExistence(timeout: 10), "No versions in the sidebar")
        XCTAssertTrue(anyContaining("The destination isn’t empty.").exists, "The sidebar doesn't say the destination isn't empty")
    }

    /// The object list shows the type's counts; an Update row's differences
    /// are a table that can be sorted by its columns.
    func test14InspectorDiff() {
        previewCategoriesOnly()
        openCategories()
        XCTAssertTrue(anyContaining("to update").waitForExistence(timeout: 10), "The object list shows no counts")
        XCTAssertTrue(anyContaining("checked").exists, "The counts don't say how many are checked")
        let update = app.outlines.cells.containing(NSPredicate(format: "label == 'Contoso Security' OR value == 'Contoso Security'")).firstMatch
        let row = update.exists ? update : app.staticTexts["Contoso Security"].firstMatch
        tap(row, timeout: 10)
        XCTAssertTrue(anyContaining("Differences (source → destination)").waitForExistence(timeout: 10), "No differences for an Update row")
        // the cells can be read by their identifiers (the live UI test records them)
        let fields = app.descendants(matching: .any).matching(identifier: "diff-field").allElementsBoundByIndex
        let destinations = app.descendants(matching: .any).matching(identifier: "diff-destination").allElementsBoundByIndex
        XCTAssertFalse(fields.isEmpty, "The diff's field cells can't be read")
        XCTAssertEqual(fields.count, destinations.count, "Every diff row has a destination cell")
        print("DIFF-CELLS: \(fields.map { ($0.value as? String) ?? $0.label }) / \(destinations.map { ($0.value as? String) ?? $0.label })")
        let field = app.buttons["Field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "The differences have no sortable Field column")
        // a table's column header reports itself as not hittable; its middle is
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        app.buttons["Source"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    /// Delete mode: the banner names the tenant, Run turns into a delete
    /// that confirms with the count, and Switch to Copy leaves it.
    func test15DeleteMode() {
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(anyContaining("Delete mode: a run deletes the checked objects from Contoso Destination (Demo).")
                        .waitForExistence(timeout: 5), "No delete-mode banner naming the tenant")
        XCTAssertTrue(toolbarButton("Wipe Tenant").exists, "Delete mode has no Wipe Tenant")
        previewCategoriesOnly()
        tap(toolbarButton("Run"), timeout: 10)
        let delete = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete ' AND (label ENDSWITH ' Object' OR label ENDSWITH ' Objects')")).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "The delete Run doesn't confirm with its count")
        delete.click()
        XCTAssertTrue(anyContaining("Results").waitForExistence(timeout: 60), "The delete run didn't finish")
        tap(app.buttons["Close"].firstMatch, timeout: 10)
        tap(app.buttons["Switch to Copy"].firstMatch, timeout: 5)
        XCTAssertTrue(toolbarButton("Clone Tenant").waitForExistence(timeout: 5), "Switch to Copy didn't leave delete mode")
    }

    /// Wipe Tenant: the delete button stays off until Preview, the backup
    /// and the typed name all pass; then it wipes the checked objects.
    func test16WipeGates() {
        app.typeKey("d", modifierFlags: .command)
        tap(app.links["Uncheck All"].firstMatch, timeout: 20)
        let categories = app.checkBoxes["Categories"].firstMatch
        scrollIntoView(categories)
        tap(categories, timeout: 10)
        tap(toolbarButton("Wipe Tenant"), timeout: 10)
        let wizard = app.sheets.firstMatch
        XCTAssertTrue(wizard.waitForExistence(timeout: 10), "The Wipe Tenant wizard didn't open")
        XCTAssertTrue(anyContaining("will be deleted").waitForExistence(timeout: 60), "The wizard's Preview didn't finish")
        let wipe = wizard.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete ' AND label CONTAINS ' from '")).firstMatch
        XCTAssertTrue(wipe.exists && !wipe.isEnabled, "The wipe button is on before the backup and the name")
        tap(wizard.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Back Up '")).firstMatch, timeout: 5)
        XCTAssertTrue(anyContaining("Backup complete").waitForExistence(timeout: 60), "The backup didn't complete")
        XCTAssertFalse(wipe.isEnabled, "The wipe button is on before the name is typed")
        type("Contoso Destination (Demo)", into: wizard.textFields.firstMatch)
        XCTAssertTrue(wipe.isEnabled, "The wipe button stays off with every gate passed")
        wipe.click()
        XCTAssertTrue(anyContaining("Wipe finished").waitForExistence(timeout: 60), "The wipe didn't finish")
        tap(wizard.buttons["Done"], timeout: 10)
    }

    /// Clone Tenant: Back returns to the step before, the Prepare step shows
    /// the proposed mappings before Continue, and Close is at the bottom.
    func test17CloneBackAndMappings() {
        tap(toolbarButton("Clone Tenant"), timeout: 20)
        let wizard = app.sheets.firstMatch
        XCTAssertTrue(wizard.waitForExistence(timeout: 10))
        XCTAssertFalse(wizard.buttons["Back"].exists, "Back on the first step")
        tap(continueButton(in: wizard), timeout: 60)
        // 2 Prepare: the ADE instance's picker, once the mappings loaded
        XCTAssertTrue(wizard.popUpButtons.firstMatch.waitForExistence(timeout: 30), "No mapping pickers in Prepare")
        XCTAssertNotEqual(wizard.popUpButtons.firstMatch.value as? String, "Not mapped", "The proposed ADE mapping isn't applied")
        tap(wizard.buttons["Back"], timeout: 5)
        XCTAssertTrue(wizard.buttons["Test Again"].waitForExistence(timeout: 5), "Back didn't return to Connect")
        tap(continueButton(in: wizard), timeout: 30)
        tap(continueButton(in: wizard), timeout: 30)
        XCTAssertTrue(wizard.buttons["Preview"].waitForExistence(timeout: 10), "Not on the Preview step")
        tap(wizard.buttons["Close"], timeout: 5)
        XCTAssertTrue(wizard.waitForNonExistence(timeout: 5), "Close didn't close the wizard")
    }

    /// Demo mode off leaves the demo tenants: with no saved tenant the
    /// sidebar offers to add one; on again, the demo tenants are back.
    func test18DemoModeOff() {
        tap(app.menuBars.menuBarItems["Connection"])
        tap(app.menuItems["Demo Mode"].firstMatch)
        XCTAssertTrue(anyContaining("Add tenants in Settings").waitForExistence(timeout: 10), "Demo mode didn't turn off")
        XCTAssertFalse(toolbarButton("Preview").isEnabled, "Preview is on without tenants")
        tap(app.links["Try Demo Mode"].firstMatch.exists ? app.links["Try Demo Mode"].firstMatch : app.buttons["Try Demo Mode"].firstMatch,
            timeout: 5)
        XCTAssertTrue(toolbarButton("Preview").waitForExistence(timeout: 10))
        let on = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: toolbarButton("Preview"))
        XCTAssertEqual(XCTWaiter.wait(for: [on], timeout: 10), .completed, "Demo mode didn't turn back on")
    }

    // MARK: Helpers

    /// The connection editor's Protected toggle (a checkbox or a switch).
    private func protectedToggle(in settings: XCUIElement) -> XCUIElement {
        settings.descendants(matching: .any).matching(identifier: "tenant-protected").firstMatch
    }

    /// The Connection menu's items with this title, Source's first.
    private func connectionMenuItems(_ title: String) -> [XCUIElement] {
        tap(app.menuBars.menuBarItems["Connection"])
        let items = app.menuBars.menuItems.matching(NSPredicate(format: "title == %@", title))
        _ = items.firstMatch.waitForExistence(timeout: 5)
        return items.allElementsBoundByIndex
    }

    /// Shows the Categories objects (the row, not its checkbox).
    private func openCategories() {
        let row = app.outlines["Sidebar"].outlineRows.containing(.checkBox, identifier: "Categories").firstMatch
        let categoriesRow = row.exists ? row
            : app.outlines["Sidebar"].outlineRows.containing(NSPredicate(format: "label == 'Categories'")).firstMatch
        XCTAssertTrue(categoriesRow.waitForExistence(timeout: 10), "No Categories row")
        categoriesRow.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).click()
    }

    /// Only Categories selected, then Preview until Run can be clicked.
    private func previewCategoriesOnly() {
        tap(app.links["Uncheck All"].firstMatch, timeout: 20)
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

    /// The wizard's "Continue" (or "Continue Anyway"), not "Continue to Verify".
    private func continueButton(in wizard: XCUIElement) -> XCUIElement {
        wizard.buttons.matching(NSPredicate(format: "(label == 'Continue' OR label == 'Continue Anyway') AND isEnabled == true"))
            .firstMatch
    }
}
