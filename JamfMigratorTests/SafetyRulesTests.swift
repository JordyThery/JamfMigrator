//
//  SafetyRulesTests.swift
//  JamfMigratorTests
//
//  The rules that keep a run safe and its secrets private: Settings ›
//  Secrets never reach an export, a diff or a report; Wipe never removes the
//  accounts that keep a tenant reachable; a run keeps its tenants and mode;
//  references are resolved, not dropped; a list without its list is an error.
//

import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import JamfMigrator

private func jsonBody(_ outcome: TransformOutcome) throws -> [String: Any] {
    guard case .write(let object) = outcome else {
        Issue.record("expected .write, got \(outcome)")
        throw NotAWrite()
    }
    return try JSONSerialization.jsonObject(with: object.body) as! [String: Any]
}

// MARK: - Secrets

struct SecretsStayPrivateTests {

    private let ldapPassword = "Bind-Pa55word-Example"

    /// An LDAP server on the source only, with Settings › Secrets' LDAP
    /// password, run with exports on.
    @Test func exportsNeverHoldASecretValue() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/proclassic/ldapservers"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["ldap_servers": [["id": 1, "name": "Corp LDAP"]]]))
            case ("src", "GET", "/proclassic/ldapservers/id/1"):
                return MockHTTP.Reply(status: 200, data: Data("""
                <ldap_server><connection><id>1</id><name>Corp LDAP</name><hostname>ldap.example.test</hostname>\
                <account><distinguished_username>cn=bind</distinguished_username>\
                <password_sha256 since="9.23">0f0e0d0c0b0a</password_sha256></account></connection></ldap_server>
                """.utf8))
            case ("dst", "POST", "/proclassic/ldapservers/id/0"):
                return MockHTTP.Reply(status: 201, data: Data("<ldap_server><id>7</id></ldap_server>".utf8))
            default:
                return nil
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExportSecrets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = MigrationEngine(source: gateway.source, dest: gateway.dest, journal: makeJournal(),
                                     export: ExportWriter(root: root), secrets: ["ldap": ldapPassword])
        let report = await engine.migrate(typeKeys: ["ldapservers"])
        #expect(report.entries.first?.status == .created(destId: "7"))

        // the request itself carries the password; the exported copy doesn't
        let sent = String(decoding: gateway.writes(to: "dst").first?.body ?? Data(), as: UTF8.self)
        #expect(sent.contains(ldapPassword))
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath })
        #expect(files.count == 2)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains(ldapPassword), "\(file.lastPathComponent) holds the password")
            #expect(!text.contains("0f0e0d0c0b0a"), "\(file.lastPathComponent) holds the password hash")
            #expect(text.contains("Corp LDAP"))
        }
    }

    @Test func exportRedactionHidesKnownValuesAndSerials() {
        let body = Data(#"{"name":"Office","serial":"ABCD-1234-EFGH","readWritePassword":"x"}"#.utf8)
        let text = String(decoding: ExportWriter.redacted(body, hiding: ["ABCD-1234-EFGH"]), as: UTF8.self)
        #expect(!text.contains("ABCD-1234-EFGH"))
        #expect(!text.contains(#""x""#))
        #expect(text.contains("Office"))
    }

    /// Recovery Lock on at the source, off at the destination: the diff
    /// says the field differs but never shows the value.
    @Test func aDiffNeverShowsASecretValue() {
        let type = ObjectRegistry.type("computerprestages")!
        let secret = "Recovery-Lock-Example-9"
        let source: [String: Any] = ["id": "1", "displayName": "Macs", "enableRecoveryLock": true,
                                     "recoveryLockPasswordType": "MANUAL", "siteId": "-1"]
        let destination: [String: Any] = ["id": "8", "displayName": "Macs", "enableRecoveryLock": false,
                                          "siteId": "-1", "versionLock": 1]
        let plan = MigrationPlanner.compare(
            type, ref: ObjectRef(id: "1", name: "Macs"), sourcePayload: .json(source), destId: "8",
            destPayload: .json(destination),
            inputs: MigrationPlanner.ComparisonInputs(destIdsByName: [:], destNamesById: [:], sourceNamesById: [:],
                                                      plannedCreates: [:], secrets: ["recoverylock": secret],
                                                      included: ["computerprestages"], mappings: TenantMappings()))
        #expect(plan.diff.contains { $0.path == "recoveryLockPassword" && $0.source == Redaction.placeholder })
        #expect(!plan.diff.contains { ($0.source ?? "").contains(secret) || ($0.destination ?? "").contains(secret) })
        #expect(!plan.warnings.joined().contains(secret))
    }

    @Test func hidingSecretsKeepsOtherFields() {
        let entries = [DiffEntry(path: "general/name", source: "A", destination: "B"),
                       DiffEntry(path: "account/password", source: "p", destination: nil),
                       DiffEntry(path: "general/notes", source: "has value-123 inside", destination: nil)]
        let hidden = PayloadDiff.hidingSecrets(entries, values: ["value-123"])
        #expect(hidden[0] == entries[0])
        #expect(hidden[1] == DiffEntry(path: "account/password", source: Redaction.placeholder, destination: nil))
        #expect(hidden[2].source == Redaction.placeholder)
    }

    /// A refused write that echoes a Settings › Secrets value keeps it out
    /// of the reason.
    @Test func aFailureReasonNeverHoldsASecretValue() {
        let reason = MigrationEngine.blankingOut(["short", "short-and-longer"], in: "Bad value short-and-longer")
        #expect(reason == "Bad value \(Redaction.placeholder)")
    }
}

// MARK: - References

struct ReferencesAreResolvedTests {

    private var context: TransformContext {
        var context = TransformContext()
        context.sourceNamesById = ["categories": ["4": "Browsers"], "sites": ["2": "HQ"],
                                   "policies": ["12": "Install Chrome"]]
        context.destIdsByName = ["categories": ["Browsers": "40"], "sites": ["HQ": "20"],
                                 "policies": ["Install Chrome": "120"]]
        return context
    }

    /// App Installer details carry ids only: category and site are kept.
    @Test func appInstallerKeepsCategoryAndSiteFromIds() throws {
        let type = ObjectRegistry.type("appinstallers")!
        let out = try jsonBody(ProTransformer.transform(type: type, json: [
            "id": "3", "name": "Chrome", "categoryId": "4", "siteId": "2", "smartGroupId": "-1",
        ], context: context))
        #expect(out["categoryId"] as? String == "40")
        #expect(out["siteId"] as? String == "20")
    }

    @Test func appInstallerWarnsWhenACategoryCantBeKept() throws {
        let type = ObjectRegistry.type("appinstallers")!
        let outcome = ProTransformer.transform(type: type, json: ["name": "Chrome", "categoryId": "99", "siteId": "-1"],
                                               context: context)
        guard case .write(let object) = outcome else { Issue.record("expected .write"); return }
        #expect(object.warnings.contains { $0.contains("category") })
    }

    @Test func onboardingItemsPointAtTheDestinationsObjects() throws {
        let type = ObjectRegistry.type("onboarding")!
        let out = try jsonBody(ProTransformer.transform(type: type, json: [
            "id": "1", "enabled": true,
            "onboardingItems": [["id": "5", "entityId": "12", "selfServiceEntityType": "OS_X_POLICY", "priority": 1]],
        ], context: context))
        let item = try #require((out["onboardingItems"] as? [[String: Any]])?.first)
        #expect(item["entityId"] as? String == "120")
        #expect(item["id"] == nil)
    }

    @Test func anOnboardingItemThatIsntOnTheDestinationBlocks() {
        let type = ObjectRegistry.type("onboarding")!
        let outcome = ProTransformer.transform(type: type, json: [
            "enabled": true,
            "onboardingItems": [["entityId": "77", "selfServiceEntityType": "OS_X_POLICY", "priority": 1]],
        ], context: context)
        guard case .blocked = outcome else { Issue.record("expected .blocked, got \(outcome)"); return }
    }

    /// SSO switched off at the destination stays off; one already on stays on.
    @Test func ssoIsNeverSwitchedOnAtTheDestination() throws {
        let type = ObjectRegistry.type("sso")!
        var context = TransformContext()
        context.action = .update(destId: "singleton")
        context.destEnabledFlags = ["ssoForEnrollmentEnabled"]
        let outcome = ProTransformer.transform(type: type, json: [
            "ssoEnabled": true, "ssoForEnrollmentEnabled": true, "configurationType": "SAML",
        ], context: context)
        let out = try jsonBody(outcome)
        #expect(out["ssoEnabled"] as? Bool == false)
        #expect(out["ssoForEnrollmentEnabled"] as? Bool == true)
        guard case .write(let object) = outcome else { return }
        #expect(object.warnings.contains { $0.contains("ssoEnabled") })
    }

    /// A Blueprint scoped to a device group the same run creates is
    /// planned, not Blocked, and depends on that group.
    @Test func aBlueprintCanUseADeviceGroupTheRunCreates() {
        let type = ObjectRegistry.type("blueprints")!
        let plan = MigrationPlanner.compare(
            type, ref: ObjectRef(id: "B1", name: "Baseline"),
            sourcePayload: .json(["id": "B1", "name": "Baseline", "scope": ["deviceGroups": ["SRC-UUID"]]]),
            destId: nil, destPayload: nil,
            inputs: MigrationPlanner.ComparisonInputs(
                destIdsByName: [:], destNamesById: [:],
                sourceNamesById: [platformGroupsKey: ["SRC-UUID": "Laptops"]],
                plannedCreates: ["staticcomputergroups": ["Laptops"]], secrets: [:],
                included: ["staticcomputergroups", "blueprints"], mappings: TenantMappings()))
        #expect(plan.change == .create)
        #expect(plan.plannedDependencies == [PlannedDependency(typeKey: "staticcomputergroups", name: "Laptops")])
    }
}

// MARK: - Lists

struct ListAnswersTests {

    @Test(arguments: ["patchsoftwaretitles", "sites", "jamfgroups"])
    func aListAnswerWithoutItsListIsAnError(typeKey: String) async {
        let type = ObjectRegistry.type(typeKey)!
        let gateway = FakeGateway { _, method, path, _ in
            method == "GET" && path == "/" + type.api.listPath
                ? MockHTTP.Reply(status: 200, data: Data(#"{"unexpected": true}"#.utf8)) : nil
        }
        await #expect(throws: JamfPlatform.APIError.self) {
            _ = try await ObjectLister.list(type, on: gateway.dest)
        }
    }

    @Test func anEmptyListIsStillEmpty() async throws {
        let gateway = FakeGateway { _, _, _, _ in nil }
        #expect(try await ObjectLister.list(ObjectRegistry.type("sites")!, on: gateway.dest).isEmpty)
        #expect(try await ObjectLister.list(ObjectRegistry.type("jamfgroups")!, on: gateway.dest).isEmpty)
    }
}

// MARK: - Wipe

struct WipeKeepsAccessTests {

    /// Three Jamf Pro accounts and two groups on the tenant.
    private var gateway: FakeGateway {
        FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("dst", "GET", "/pro/v1/accounts"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 3, "results": [
                    ["id": "1", "username": "admin"], ["id": "2", "username": "migrator"], ["id": "3", "username": "helpdesk"],
                ]]))
            case ("dst", "GET", "/pro/v1/accounts/1"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(
                    ["id": "1", "username": "admin", "accessLevel": "FullAccess", "privilegeLevel": "ADMINISTRATOR"]))
            case ("dst", "GET", "/pro/v1/accounts/2"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(
                    ["id": "2", "username": "migrator", "accessLevel": "FullAccess", "privilegeLevel": "CUSTOM"]))
            case ("dst", "GET", "/pro/v1/accounts/3"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(
                    ["id": "3", "username": "helpdesk", "accessLevel": "SiteAccess", "privilegeLevel": "CUSTOM"]))
            case ("dst", "GET", "/proclassic/accounts"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["accounts": ["users": [Any](), "groups": [
                    ["id": 7, "name": "Admins"], ["id": 8, "name": "Auditors"],
                ]]]))
            case ("dst", "GET", "/proclassic/accounts/groupid/7"):
                return MockHTTP.Reply(status: 200, data: Data(
                    "<group><id>7</id><name>Admins</name><access_level>Full Access</access_level><privilege_set>Administrator</privilege_set></group>".utf8))
            case ("dst", "GET", "/proclassic/accounts/groupid/8"):
                return MockHTTP.Reply(status: 200, data: Data(
                    "<group><id>8</id><name>Auditors</name><access_level>Full Access</access_level><privilege_set>Auditor</privilege_set></group>".utf8))
            default:
                return nil
            }
        }
    }

    @Test func wipeNeverDeletesTheSignedInOrAnAdministratorAccount() async {
        let gateway = gateway
        let plan = await MigrationPlanner(source: gateway.dest, dest: gateway.dest)
            .planDeletion(typeKeys: ["jamfusers", "jamfgroups"], signedInUsername: "Migrator")
        func change(_ name: String) -> PlannedChange? { plan.entries.first { $0.name == name }?.change }

        if case .keep = change("admin") {} else { Issue.record("admin: \(String(describing: change("admin")))") }
        if case .keep = change("migrator") {} else { Issue.record("migrator: \(String(describing: change("migrator")))") }
        if case .keep = change("Admins") {} else { Issue.record("Admins: \(String(describing: change("Admins")))") }
        #expect(change("helpdesk") == .delete)
        #expect(change("Auditors") == .delete)

        // and Run deletes only the Delete rows
        let report = await DeleteEngine(client: gateway.dest, journal: makeJournal(mode: .delete))
            .run(plan, including: plan.runnableIds)
        #expect(Set(gateway.requests.value.filter { $0.method == "DELETE" }.map(\.path))
                == ["/pro/v1/accounts/3", "/proclassic/accounts/groupid/8"])
        #expect(report.deletedCount <= 2)
    }

    @Test func anAccountWhoseAccessIsUnknownIsKept() {
        #expect(MigrationPlanner.isFullAdministrator(accessLevel: nil, privilegeSet: "ADMINISTRATOR") != nil)
        #expect(MigrationPlanner.isFullAdministrator(accessLevel: "Full Access", privilegeSet: "Administrator") != nil)
        #expect(MigrationPlanner.isFullAdministrator(accessLevel: "Site Access", privilegeSet: "Administrator") == nil)
    }
}

// MARK: - Run reports

struct RunReportRowsTests {

    @Test func rowsAreUniqueAcrossTypes() {
        var report = RunReport()
        report.add(type: ObjectRegistry.type("scripts")!, ref: ObjectRef(id: "-", name: "(all objects)"), status: .failed(reason: "x"))
        report.add(type: ObjectRegistry.type("policies")!, ref: ObjectRef(id: "-", name: "(all objects)"), status: .failed(reason: "y"))
        report.add(type: ObjectRegistry.type("categories")!, ref: ObjectRef(id: "5", name: "A"), status: .deleted)
        report.add(type: ObjectRegistry.type("sites")!, ref: ObjectRef(id: "5", name: "B"), status: .blocked(reason: "z"))
        #expect(Set(report.entries.map(\.id)).count == 4)
        #expect(report.deletedCount == 1)
    }
}

// MARK: - Stop

struct StopTests {

    /// Stop during a write lets that write finish and be recorded as done;
    /// the next object isn't started.
    @Test func stopFinishesTheObjectBeingWritten() async throws {
        let engineBox = Locked<MigrationEngine?>(nil)
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(
                    ["totalCount": 2, "results": [["id": "1", "name": "One"], ["id": "2", "name": "Two"]]]))
            case ("src", "GET", "/pro/v1/categories/1"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "1", "name": "One", "priority": 9]))
            case ("src", "GET", "/pro/v1/categories/2"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "2", "name": "Two", "priority": 9]))
            case ("dst", "POST", "/pro/v1/categories"):
                // Stop arrives while the first write is on its way
                let engine = engineBox.value
                Task { await engine?.cancel() }
                Thread.sleep(forTimeInterval: 0.3)
                return MockHTTP.Reply(status: 201, data: MockHTTP.json(["id": "11"]))
            default:
                return nil
            }
        }
        let engine = MigrationEngine(source: gateway.source, dest: gateway.dest, journal: makeJournal())
        engineBox.value = engine
        let plan = await MigrationPlanner(source: gateway.source, dest: gateway.dest).plan(typeKeys: ["categories"])
        let report = await engine.run(plan, including: plan.runnableIds)

        #expect(report.entries.map(\.status) == [.created(destId: "11")])
        #expect(gateway.writes(to: "dst").count == 1)
    }
}

// MARK: - The app during a run

@MainActor
struct RunKeepsItsTenantsTests {

    private func app() throws -> (AppState, Tenant, Tenant, Tenant) {
        let defaults = UserDefaults(suiteName: "jamfmigrator-safety-\(UUID().uuidString)")!
        let mode = DemoMode(key: "demoMode", defaults: defaults, arguments: ["app", "-JTKitSandbox", "YES"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Safety-\(UUID().uuidString)")
        let store = TenantStore(directory: directory, secrets: InMemorySecretStore(), log: nil, demo: mode,
                                storage: InMemoryConnectionStorage<Tenant>())
        let a = Tenant(name: "Tenant A", environmentId: TestEnvironment.source, clientId: "a")
        let b = Tenant(name: "Tenant B", environmentId: TestEnvironment.destination, clientId: "b")
        let c = Tenant(name: "Tenant C", serverURL: "https://c.example.test")
        for tenant in [a, b, c] { try store.connections.save(tenant) }
        let app = AppState(tenantStore: store, secretStore: InMemorySecretStore(), demo: mode, defaults: defaults)
        app.sourceTenantID = a.id
        app.destTenantID = b.id
        return (app, a, b, c)
    }

    private var plan: MigrationPlan {
        MigrationPlan(mode: .copy, entries: [ObjectPlan(typeKey: "categories", objectId: "5", name: "Tools", change: .create)],
                      typeKeys: ["categories"])
    }

    @Test func theTenantsAndModeCantChangeDuringARun() throws {
        let (app, a, b, c) = try app()
        app.plan = plan
        app.includedObjectIds = plan.runnableIds
        app.isRunning = true
        #expect(!app.canChangeTenants)

        app.destTenantID = c.id
        app.sourceTenantID = c.id
        app.mode = .delete
        #expect(app.destTenantID == b.id)
        #expect(app.sourceTenantID == a.id)
        #expect(app.mode == .copy)
        // a change from elsewhere (a demo tenant chosen in the menu) waits for the run
        app.tenantsChanged(demoSwitched: false)
        #expect(app.plan != nil)

        app.isRunning = false
        app.destTenantID = c.id
        #expect(app.destTenantID == c.id)
        #expect(app.plan == nil)
    }

    /// An edited server URL, region or Environment ID is another tenant pair.
    @Test func editingATenantsConnectionChangesThePair() throws {
        var (app, _, b, _) = try app()
        let before = app.tenantPairKey
        b.environmentId = "e0000000-0000-4000-8000-00000000000e"
        try app.tenantStore.connections.save(b)
        #expect(app.tenantPairKey != before)
        _ = app
    }

    /// Wipe's delete button stays off when Run itself can't run: after the
    /// selection changed since Preview.
    @Test func wipeNeedsARunnablePlan() throws {
        let (app, _, b, _) = try app()
        app.mode = .delete
        app.selectedTypeKeys = ["categories"]
        app.plan = MigrationPlan(mode: .delete, entries: [ObjectPlan(typeKey: "categories", objectId: "5", name: "Tools", change: .delete)],
                                 typeKeys: ["categories"])
        app.includedObjectIds = app.plan!.runnableIds
        #expect(app.wipeGatesPass(typedName: b.name, backupSkipped: true))
        #expect(!app.wipeGatesPass(typedName: "Tenant", backupSkipped: true))
        #expect(!app.wipeGatesPass(typedName: b.name, backupSkipped: false))
        app.selectedTypeKeys.insert("scripts")
        #expect(!app.wipeGatesPass(typedName: b.name, backupSkipped: true))
    }

    /// The menu's Clone Tenant… and Wipe Tenant… follow the toolbar buttons:
    /// each in its own mode, never during a run.
    @Test func theWizardCommandsFollowTheMode() throws {
        let (app, _, _, _) = try app()
        #expect(app.canClone && !app.canWipe)
        app.mode = .delete
        #expect(!app.canClone && app.canWipe)
        app.isRunning = true
        #expect(!app.canWipe)
    }

    /// The wizard's and the toolbar's confirmation name the same count.
    @Test func theConfirmationButtonNamesTheCount() throws {
        let (app, _, _, _) = try app()
        app.plan = plan
        app.includedObjectIds = plan.runnableIds
        #expect(app.runConfirmationButton == "Copy 1 Change")
        app.includedObjectIds = [:]
        #expect(app.runConfirmationButton == "Copy 0 Changes")
    }

    /// The tour's "seen" flag lives in the app's settings, never the real
    /// defaults in a sandbox run.
    @Test func theTourUsesTheAppsSettings() throws {
        let (app, _, _, _) = try app()
        let real = UserDefaults.standard.object(forKey: "hasSeenGuidedTour") as? Bool
        app.tour.startOnFirstLaunch()
        #expect(UserDefaults.standard.object(forKey: "hasSeenGuidedTour") as? Bool == real)
        app.tour.end()
    }

    @Test func pluralsMatchTheCount() {
        #expect(Plural.count(1, "object") == "1 object")
        #expect(Plural.count(2, "object") == "2 objects")
        #expect(Plural.count(0, "Change") == "0 Changes")
    }
}
