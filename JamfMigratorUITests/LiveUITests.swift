import XCTest
import JTKitLiveCheck
import JTKitUITestSupport

/// The real app under JTKit's live-check switch (JTKit 1.1.0), run only by
/// `scripts/release-check.sh` in its live stage. Every request, the app's
/// and the test's, goes through the release check's gateway
/// (`jtkit-live-gateway`), which decides it by the release check's rules
/// (allow-list, ledger, prefix, access levels). The app holds only the
/// release check's connections, never the saved ones.
///
/// 1. jamf-test-a → jamf-test-b: the test code makes a JTKTEST category, a
///    script in it and a policy in it (disabled, scoped to nothing, in Self
///    Service) on jamf-test-a; the app copies just those three through
///    Clone Tenant's Preview and a confirmed Run, and Verify finds nothing
///    left to write. The test code reads them back on jamf-test-b and
///    removes everything from both tenants.
/// 2. A cross-tenant Preview reading the production read role into
///    jamf-test-b: Preview only, no Run; the gateway refuses any write there.
///
/// Delete mode and Wipe never run live.
final class LiveUITests: JTKitUITestCase {
    private let source = "jamf-test-a"
    private let destination = "jamf-test-b"
    private let productionRead = "jamfpro-production"

    override var appName: String { "Jamf Migrator" }
    override var launchesLive: Bool { true }

    override func didLaunch() {
        let main = app.windows.firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 20), "The main window did not open")
        let skip = app.buttons["Skip Tour"].firstMatch
        if skip.waitForExistence(timeout: 3) { skip.click() }
        if main.frame.height < 700 || main.frame.width < 1200 {
            let zoom = app.menuBars.menuItems["Zoom"].firstMatch
            if zoom.exists { zoom.click() }
        }
    }

    // MARK: 1. Copy, run, verify

    func testCopyThroughPreviewRunAndVerify() throws {
        let gateway = try liveGateway()
        let sourceAPI = try LiveJamfPlatformAPI(gateway: gateway, role: source)
        let destinationAPI = try LiveJamfPlatformAPI(gateway: gateway, role: destination)
        let step = { (name: String) in "\(self.source) → \(self.destination): live UI: \(name)" }
        let prefix = livePrefix
        let categoryName = "\(prefix) – Live UI Category"
        let scriptName = "\(prefix) – Live UI Script"
        let policyName = "\(prefix) – Live UI Policy"
        let sourceRaw = try LiveRawAPI(gateway: gateway, role: source)
        let destinationRaw = try LiveRawAPI(gateway: gateway, role: destination)

        // 1. The test's own objects on the source.
        var sourceIDs: [(path: String, id: String)] = []
        defer { removeTestObjects(sourceAPI: sourceAPI, sourceRaw: sourceRaw, sourceIDs: sourceIDs,
                                  destinationAPI: destinationAPI, destinationRaw: destinationRaw,
                                  names: [policyName, scriptName, categoryName], step: step) }
        let categoryID = try liveCall {
            try await sourceAPI.create("pro/v1/categories", json: ["name": categoryName, "priority": 9])
        }
        sourceIDs.append(("pro/v1/categories", categoryID))
        let scriptID = try liveCall {
            try await sourceAPI.create("pro/v1/scripts", json: [
                "name": scriptName, "categoryId": categoryID, "priority": "AFTER",
                "info": "Release check test object; removed after the run", "notes": "",
                "scriptContents": "#!/bin/sh\necho \"JTKTEST\"\n",
            ])
        }
        sourceIDs.insert(("pro/v1/scripts", scriptID), at: 0)
        // a Classic policy in the category: never enabled, scoped to nothing
        let policyID = try liveCall {
            try await sourceRaw.createClassic("policies", xml: Self.policyXML(name: policyName, categoryID: categoryID))
        }
        sourceIDs.insert(("proclassic/policies/id", policyID), at: 0)
        recordLive(step: step("create a category, a script and a policy on the source"), passed: true)

        // 2. The real app with the two test tenants' connections.
        try launchLive(roles: [source, destination])
        chooseTenants(source: "\(source) (Jamf Platform API)", destination: "\(destination) (Jamf Platform API)")
        selectOnly(["Categories", "Scripts", "Policies"])

        // 3. Clone Tenant: Connect, Prepare, Preview; then only the test's
        //    two objects stay checked (the tenants hold others).
        tap(app.toolbars.buttons["Clone Tenant"].firstMatch, timeout: 20)
        var wizard = app.sheets.firstMatch
        XCTAssertTrue(wizard.waitForExistence(timeout: 10), "The Clone Tenant wizard did not open")
        tap(continueButton(in: wizard), timeout: 120)
        tap(continueButton(in: wizard), timeout: 120)   // waits for the mappings
        tap(wizard.buttons["Preview"], timeout: 30)
        XCTAssertTrue(wizard.buttons["Preview Again"].waitForExistence(timeout: 300), "Preview didn't finish")
        waitForNetwork()
        tap(wizard.buttons["Close"], timeout: 10)
        XCTAssertTrue(wizard.waitForNonExistence(timeout: 10))

        let search = app.searchFields.firstMatch
        tap(search, timeout: 10)
        search.typeText(prefix)
        for (type, name) in [("Categories", categoryName), ("Scripts", scriptName), ("Policies", policyName)] {
            openType(type)
            tap(app.toolbars.menuButtons["Select"].firstMatch, timeout: 10)
            tap(app.menuItems["Uncheck All"].firstMatch, timeout: 5)
            tap(app.checkBoxes["Include \(name)"].firstMatch, timeout: 20)
        }
        recordLive(step: step("Preview in the app: the three test objects planned as Create"), passed: true)

        // 4. Run from the wizard, confirmed with exactly the two changes,
        //    then Verify.
        tap(app.toolbars.buttons["Clone Tenant"].firstMatch, timeout: 10)
        wizard = app.sheets.firstMatch
        XCTAssertTrue(wizard.waitForExistence(timeout: 10))
        tap(continueButton(in: wizard), timeout: 120)
        tap(continueButton(in: wizard), timeout: 120)
        tap(continueButton(in: wizard), timeout: 30)    // the plan stays loaded
        tap(wizard.buttons["Run"], timeout: 10)
        let confirm = dialogButton("Copy 3 Changes")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Run doesn't offer exactly the three test objects")
        confirm.click()
        tap(wizard.buttons["Continue to Verify"], timeout: 300)
        waitForNetwork()
        recordLive(step: step("Run in the app: confirmed, finished"), passed: true)
        tap(wizard.buttons["Verify"], timeout: 10)
        let clean = anyContaining("Verified: a second run would write nothing.")
        let verified = clean.waitForExistence(timeout: 300)
        recordLive(step: step("Verify in the app: nothing left to write"), passed: verified)
        XCTAssertTrue(verified, "Verify isn't clean: \(anyContaining("missing").label)")
        tap(wizard.buttons["Done"], timeout: 10)
        waitForNetwork()

        // 5. Read back on the destination: all three there, the script and
        //    the policy in the copied category, the policy still off.
        let created = destinationItems(gateway, names: [categoryName, scriptName, policyName])
        let destinationCategory = created.first { $0.resource == "categories" }?.id
        let destinationScript = created.first { $0.resource == "scripts" }?.id
        let destinationPolicy = created.first { $0.resource == "policies" }?.id
        var readBack = false
        if let destinationCategory, let destinationScript, let destinationPolicy {
            let category = try liveCall { try await destinationAPI.object("pro/v1/categories/\(destinationCategory)") }
            let script = try liveCall { try await destinationAPI.object("pro/v1/scripts/\(destinationScript)") }
            let policy = try liveCall { try await destinationRaw.json("proclassic/policies/id/\(destinationPolicy)") }
            let general = (policy["policy"] as? [String: Any])?["general"] as? [String: Any]
            let policyCategory = general?["category"] as? [String: Any]
            let enabled = "\(general?["enabled"] ?? "")"
            readBack = category["name"] as? String == categoryName && script["name"] as? String == scriptName
                && "\(script["categoryId"] ?? "")" == destinationCategory
                && general?["name"] as? String == policyName && policyCategory?["name"] as? String == categoryName
                && (enabled == "false" || enabled == "0")
        }
        recordLive(step: step("read back on the destination: all three there, in the copied category, the policy off"), passed: readBack)
        XCTAssertTrue(readBack, "The copies on the destination aren't what the source has: \(created)")
    }

    // MARK: 2. Cross-tenant Preview from the production read role

    func testCrossTenantPreviewFromProduction() throws {
        let gateway = try liveGateway()
        guard gateway.launch.connections.contains(where: { $0.role == productionRead }) else {
            throw XCTSkip("\(productionRead) isn't part of this run")
        }
        let step = { (name: String) in "\(self.productionRead) → \(self.destination): live UI: \(name)" }
        try launchLive(roles: [productionRead, destination])
        let sourceName = "\(productionRead) (Jamf Platform API)"
        let destinationName = "\(destination) (Jamf Platform API)"
        chooseTenants(source: sourceName, destination: destinationName)
        selectOnly(["Categories"])
        tap(app.toolbars.buttons["Preview"].firstMatch, timeout: 10)
        let summary = anyContaining("\(sourceName) → \(destinationName)")
        let planned = summary.waitForExistence(timeout: 300)
        waitForNetwork()
        recordLive(step: step("Preview reads production into jamf-test-b; no Run"), passed: planned)
        XCTAssertTrue(planned, "The cross-tenant Preview didn't finish")
        XCTAssertTrue(anyContaining("Categories").exists, "The summary lists no Categories")
        app.terminate()
    }

    // MARK: Helpers

    /// Source and Destination from the Connection menu (its Source section
    /// lists every tenant first, then its Destination section).
    private func chooseTenants(source: String, destination: String) {
        tap(app.menuBars.menuBarItems["Connection"], timeout: 10)
        tap(app.menuBars.menuItems.matching(NSPredicate(format: "title == %@", source)).element(boundBy: 0), timeout: 10)
        tap(app.menuBars.menuBarItems["Connection"], timeout: 10)
        let items = app.menuBars.menuItems.matching(NSPredicate(format: "title == %@", destination))
        _ = items.firstMatch.waitForExistence(timeout: 10)
        tap(items.element(boundBy: items.count > 1 ? 1 : 0), timeout: 10)
        XCTAssertTrue(app.toolbars.buttons["Preview"].firstMatch.waitForExistence(timeout: 10))
    }

    /// Only these object types checked in the sidebar.
    private func selectOnly(_ types: [String]) {
        tap(app.links["Uncheck All"].firstMatch, timeout: 20)
        for type in types {
            let box = app.checkBoxes[type].firstMatch
            scrollIntoView(box)
            tap(box, timeout: 10)
        }
    }

    /// Shows a type's objects (the sidebar row, not its checkbox).
    private func openType(_ type: String) {
        let row = app.outlines["Sidebar"].outlineRows.containing(.checkBox, identifier: type).firstMatch
        let typeRow = row.exists ? row
            : app.outlines["Sidebar"].outlineRows.containing(NSPredicate(format: "label == %@", type)).firstMatch
        XCTAssertTrue(typeRow.waitForExistence(timeout: 10), "No \(type) row")
        typeRow.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).click()
    }

    /// The wizard's "Continue" (or "Continue Anyway"), not "Continue to Verify".
    private func continueButton(in wizard: XCUIElement) -> XCUIElement {
        wizard.buttons.matching(NSPredicate(format: "(label == 'Continue' OR label == 'Continue Anyway') AND isEnabled == true"))
            .firstMatch
    }

    /// What the run's ledger holds on the destination's Platform API under these names.
    private func destinationItems(_ gateway: LiveGatewayClient, names: [String]) -> [Ledger.Item] {
        guard let environmentID = gateway.launch.connections
            .first(where: { $0.role == destination && $0.connection.service == "jamfPlatform" })?.connection.environmentID else { return [] }
        let ledger = Ledger(fileURL: gateway.runFolder.appending(path: "ledger.json"))
        return ledger.items.filter { $0.target == "platform:\(environmentID)" && names.contains($0.name) && !$0.removed }
    }

    /// Removes the copies on the destination (script first), then the
    /// source's objects, and checks the run left nothing.
    private func removeTestObjects(sourceAPI: LiveJamfPlatformAPI, sourceRaw: LiveRawAPI, sourceIDs: [(path: String, id: String)],
                                   destinationAPI: LiveJamfPlatformAPI, destinationRaw: LiveRawAPI,
                                   names: [String], step: (String) -> String) {
        app?.terminate()
        guard let gateway = try? liveGateway() else { return }
        // what refers to the category goes first: the policy, the script, then the category
        let order = ["policies": 0, "scripts": 1, "categories": 2]
        let copies = destinationItems(gateway, names: names).sorted { (order[$0.resource] ?? 3) < (order[$1.resource] ?? 3) }
        let removed = (try? liveCall(timeout: 300) {
            for copy in copies {
                if copy.resource == "policies" {
                    try await destinationRaw.send("DELETE", "proclassic/policies/id/\(copy.id)", accepting: [404])
                } else {
                    try await destinationAPI.send("DELETE", "pro/v1/\(copy.resource)/\(copy.id)", accepting: [404])
                }
            }
            for object in sourceIDs {
                if object.path.hasPrefix("proclassic/") {
                    try await sourceRaw.send("DELETE", "\(object.path)/\(object.id)", accepting: [404])
                } else {
                    try await sourceAPI.send("DELETE", "\(object.path)/\(object.id)", accepting: [404])
                }
            }
            return true
        }) ?? false
        let nothingLeft = (try? requireRunObjectsGone()) != nil
        recordLive(step: step("remove the test objects from both tenants"), passed: removed && nothingLeft)
        XCTAssertTrue(removed && nothingLeft, "The test objects weren't all removed")
    }
}

extension LiveUITests {
    /// A policy that never runs: disabled, scoped to nothing, offered in
    /// Self Service under its own name, in the test's category.
    static func policyXML(name: String, categoryID: String) -> String {
        let escaped = name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return "<policy><general><name>\(escaped)</name><enabled>false</enabled><trigger_checkin>false</trigger_checkin>"
            + "<category><id>\(categoryID)</id></category></general>"
            + "<scope><all_computers>false</all_computers></scope>"
            + "<self_service><use_for_self_service>true</use_for_self_service>"
            + "<self_service_display_name>\(escaped)</self_service_display_name></self_service></policy>"
    }
}

/// Requests a live UI test needs that `LiveJamfPlatformAPI` (JSON only)
/// doesn't send: Classic XML creates and deletes, and Classic reads as JSON.
/// Through the release check's gateway, which decides each by its rules;
/// the secret comes from the gateway, never this runner's environment.
final class LiveRawAPI: @unchecked Sendable {
    private let gateway: LiveGatewayClient
    private let baseURL: URL
    private let environmentID: String
    private let clientID: String
    private let clientSecret: String
    private let lock = NSLock()
    private var token: String?

    struct Failure: Error, CustomStringConvertible {
        let status: Int
        let body: String
        var description: String { "HTTP \(status): \(body.prefix(300))" }
    }

    init(gateway: LiveGatewayClient, role: String) throws {
        guard let connection = gateway.launch.connections.first(where: { $0.role == role && $0.connection.service == "jamfPlatform" })?.connection,
              let secret = try gateway.secretNow(role: role, item: "client-secret"), !secret.isEmpty else {
            throw Failure(status: 0, body: "\(role) has no Jamf Platform API connection or client secret in this run")
        }
        self.gateway = gateway
        baseURL = URL(string: "https://\(connection.region).api.jamfcloud.com")!
        environmentID = connection.environmentID
        clientID = connection.clientID
        clientSecret = secret
    }

    @discardableResult
    func send(_ method: String, _ path: String, body: Data? = nil, contentType: String? = nil,
              accept: String = "application/json", accepting: Set<Int> = []) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(environmentID, forHTTPHeaderField: "X-Environment-Id")
        request.setValue("Bearer \(try await bearer())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await gateway.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 && !accepting.contains(status) {
            throw Failure(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return (status, data)
    }

    /// A Classic create (`proclassic/<resource>/id/0`); returns the new `<id>`.
    func createClassic(_ resource: String, xml: String) async throws -> String {
        let answer = try await send("POST", "proclassic/\(resource)/id/0", body: Data(xml.utf8),
                                    contentType: "application/xml", accept: "application/xml").body
        let text = String(decoding: answer, as: UTF8.self)
        guard let start = text.range(of: "<id>"), let end = text.range(of: "</id>", range: start.upperBound..<text.endIndex) else {
            throw Failure(status: 0, body: "The create answered without an id: \(text.prefix(200))")
        }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    /// A GET, parsed as a JSON object.
    func json(_ path: String) async throws -> [String: Any] {
        let body = try await send("GET", path).body
        return (try JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }

    private func bearer() async throws -> String {
        if let token = lock.withLock({ token }) { return token }
        var request = URLRequest(url: baseURL.appending(path: "auth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "grant_type", value: "client_credentials"),
                           URLQueryItem(name: "client_id", value: clientID),
                           URLQueryItem(name: "client_secret", value: clientSecret)]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await gateway.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["access_token"] as? String else {
            throw Failure(status: status, body: "The sign-in failed")
        }
        lock.withLock { token = value }
        return value
    }
}
