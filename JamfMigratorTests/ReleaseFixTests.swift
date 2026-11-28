//
//  ReleaseFixTests.swift
//  JamfMigratorTests
//
//  The 1.2.3 fixes: Wipe's backup belongs to one Preview (C3), backups and
//  exports keep object text (C4), the accounts that keep the destination
//  reachable in a copy (C5), and the smaller fixes C6–C15.
//

import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import JamfMigrator

@MainActor
final class ReleaseFixTests {

    private let suites = Locked<[String]>([])

    deinit {
        for name in suites.value { RegressionTests.removeDefaults(named: name) }
    }

    private func testDefaults() -> UserDefaults {
        let name = "jamfmigrator-release-\(UUID().uuidString)"
        suites.withLock { $0.append(name) }
        return UserDefaults(suiteName: name)!
    }

    /// An app on a fresh sandbox, in demo mode.
    private func demoApp() -> AppState {
        let defaults = testDefaults()
        let mode = DemoMode(key: "demoMode", defaults: defaults, arguments: ["app", "-JTKitSandbox", "YES", "-JTKitDemo", "YES"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Release-\(UUID().uuidString)")
        let store = TenantStore(directory: directory, secrets: InMemorySecretStore(), log: nil, demo: mode,
                                storage: InMemoryConnectionStorage<Tenant>())
        return AppState(tenantStore: store, secretStore: InMemorySecretStore(), demo: mode, defaults: defaults)
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(60)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: C3 Wipe's backup

    @Test("Wipe's backup gate: only a complete backup made for this Preview counts")
    func backupBelongsToOnePreview() async throws {
        let app = demoApp()
        app.mode = .delete
        app.selectedTypeKeys = ["categories"]
        let name = try #require(app.destTenant?.name)

        // a backup made before any Preview is for no plan
        app.backup()
        try await waitUntil { !app.isBackingUp }
        app.preview()
        try await waitUntil { !app.isPlanning }
        #expect(app.backupResult == nil, "a new Preview keeps an older backup")
        #expect(!app.wipeGatesPass(typedName: name, backupSkipped: false))

        app.backup()
        try await waitUntil { !app.isBackingUp }
        let plan = try #require(app.plan)
        let result = try #require(app.backupResult)
        defer { try? FileManager.default.removeItem(at: result.root) }
        #expect(result.covers(plan), "\(result.errors)")
        #expect(app.wipeGatesPass(typedName: name, backupSkipped: false))

        // more types selected: the backup no longer counts
        app.selectedTypeKeys = ["categories", "scripts"]
        #expect(app.backupResult == nil)
        #expect(!app.wipeGatesPass(typedName: name, backupSkipped: false))
    }

    @Test("A backup covers a plan only for its own Preview and every type the plan deletes from")
    func backupCoverage() throws {
        var plan = MigrationPlan()
        plan.typeKeys = ["categories", "scripts"]
        var result = BackupResult(root: URL(fileURLWithPath: "/tmp"), typeKeys: ["categories", "scripts"], planId: plan.id)
        #expect(result.covers(plan))
        result.typeKeys = ["categories"]
        #expect(!result.covers(plan), "a type of the plan isn't backed up")
        result.typeKeys = ["categories", "scripts"]
        result.planId = UUID()
        #expect(!result.covers(plan), "a backup for another Preview")
        result.planId = plan.id
        result.errors = ["Scripts: wrote 1 of 2 objects"]
        #expect(!result.covers(plan), "an incomplete backup")
    }

    // MARK: C4 Backups keep object text

    private static let script = """
    #!/bin/zsh
    JAMF_TOKEN=$(get_token)
    API_PASSWORD=$4
    curl -H "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2ln" https://example.test
    """

    @Test("A Pro script's contents stay whole; only secret fields are replaced")
    func jsonScriptStaysWhole() throws {
        let object: [String: Any] = ["name": "Install", "scriptContents": Self.script, "notes": "keep me",
                                     "readWritePassword": "Share-Pa55", "recoveryLockPasswordType": "MANUAL",
                                     "enableRecoveryLock": true, "readOnlyPassword": "",
                                     "nested": ["adminPassword": "Admin-Pa55", "priority": 3]]
        let body = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let data = ExportWriter.redacted(body, hiding: [])
        let out = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(out["scriptContents"] as? String == Self.script, "the script was changed")
        #expect(out["notes"] as? String == "keep me")
        #expect(out["readWritePassword"] as? String == Redaction.placeholder)
        #expect(out["readOnlyPassword"] as? String == "")
        #expect(out["recoveryLockPasswordType"] as? String == "MANUAL")
        #expect(out["enableRecoveryLock"] as? Bool == true)
        let nested = try #require(out["nested"] as? [String: Any])
        #expect(nested["adminPassword"] as? String == Redaction.placeholder)
        #expect(nested["priority"] as? Int == 3)
        #expect(!String(decoding: data, as: UTF8.self).contains("Pa55"))
    }

    @Test("A Classic object's script stays whole; password elements and known values are replaced")
    func xmlScriptStaysWhole() {
        let escaped = ClassicXML.escape(Self.script)
        let xml = """
        <computer_extension_attribute><name>Token check</name>\
        <input_type><type>script</type><script>\(escaped)</script></input_type>\
        <account><password_sha256 since="9.23">0f0e0d0c</password_sha256><password>Plain-Pa55</password>\
        <serial>ABCD-1234</serial></account></computer_extension_attribute>
        """
        let text = String(decoding: ExportWriter.redacted(Data(xml.utf8), hiding: ["ABCD-1234"]), as: UTF8.self)
        #expect(text.contains("<script>\(escaped)</script>"), "the script was changed: \(text)")
        #expect(text.contains(#"<password_sha256 since="9.23"><redacted></password_sha256>"#.replacingOccurrences(of: "<redacted>", with: Redaction.placeholder)))
        #expect(!text.contains("0f0e0d0c"))
        #expect(!text.contains("Plain-Pa55"))
        #expect(!text.contains("ABCD-1234"))
        #expect(text.contains("<name>Token check</name>"))
    }

    @Test("Secret field names", arguments: [
        ("password", true), ("readWritePassword", true), ("password_sha256", true), ("management_password_sha256", true),
        ("recoveryLockPassword", true), ("sharedSecret", true), ("serviceToken", true), ("passcode", true),
        ("recoveryLockPasswordType", false), ("tokenExpiration", false), ("enableRecoveryLock", false),
        ("scriptContents", false), ("name", false), ("notes", false),
    ])
    func secretFieldNames(name: String, isSecret: Bool) {
        #expect(ExportWriter.isSecretField(name) == isSecret)
    }
}

// MARK: - C5 The accounts that keep the destination reachable, in a copy

struct CopyKeepsDestinationReachableTests {

    private static func account(_ id: String, _ name: String, _ access: String, _ privileges: String) -> MockHTTP.Reply {
        MockHTTP.Reply(status: 200, data: MockHTTP.json(
            ["id": id, "username": name, "accessLevel": access, "privilegeLevel": privileges]))
    }

    private static func group(_ id: Int, _ name: String, _ access: String, _ privileges: String) -> MockHTTP.Reply {
        MockHTTP.Reply(status: 200, data: Data(
            "<group><id>\(id)</id><name>\(name)</name><access_level>\(access)</access_level><privilege_set>\(privileges)</privilege_set></group>".utf8))
    }

    /// The same three accounts and two groups on both tenants; on the source
    /// each has less access than on the destination.
    private var gateway: FakeGateway {
        FakeGateway { env, method, path, _ in
            guard method == "GET" else { return nil }
            let list = MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 3, "results": [
                ["id": "1", "username": "admin"], ["id": "2", "username": "migrator"], ["id": "3", "username": "helpdesk"],
            ]]))
            let groups = MockHTTP.Reply(status: 200, data: MockHTTP.json(["accounts": ["users": [Any](), "groups": [
                ["id": 7, "name": "Admins"], ["id": 8, "name": "Auditors"],
            ]]]))
            switch (env, path) {
            case (_, "/pro/v1/accounts"): return list
            case (_, "/proclassic/accounts"): return groups
            case ("src", "/pro/v1/accounts/1"): return Self.account("1", "admin", "FullAccess", "AUDITOR")
            case ("src", "/pro/v1/accounts/2"): return Self.account("2", "migrator", "FullAccess", "AUDITOR")
            case ("src", "/pro/v1/accounts/3"): return Self.account("3", "helpdesk", "FullAccess", "AUDITOR")
            case ("dst", "/pro/v1/accounts/1"): return Self.account("1", "admin", "FullAccess", "ADMINISTRATOR")
            case ("dst", "/pro/v1/accounts/2"): return Self.account("2", "migrator", "FullAccess", "CUSTOM")
            case ("dst", "/pro/v1/accounts/3"): return Self.account("3", "helpdesk", "SiteAccess", "CUSTOM")
            case ("src", "/proclassic/accounts/groupid/7"): return Self.group(7, "Admins", "Full Access", "Auditor")
            case ("src", "/proclassic/accounts/groupid/8"): return Self.group(8, "Auditors", "Full Access", "Custom")
            case ("dst", "/proclassic/accounts/groupid/7"): return Self.group(7, "Admins", "Full Access", "Administrator")
            case ("dst", "/proclassic/accounts/groupid/8"): return Self.group(8, "Auditors", "Full Access", "Auditor")
            default: return nil
            }
        }
    }

    @Test("A copy plans the signed-in account and full-access administrators as Blocked, with the reason")
    func copyBlocksReachabilityAccounts() async throws {
        let gateway = gateway
        let plan = await MigrationPlanner(source: gateway.source, dest: gateway.dest, signedInUsername: "Migrator")
            .plan(typeKeys: ["jamfusers", "jamfgroups"])
        func change(_ name: String) -> PlannedChange? { plan.entries.first { $0.name == name }?.change }

        guard case .blocked(let admin)? = change("admin") else { Issue.record("admin: \(String(describing: change("admin")))"); return }
        #expect(admin.hasPrefix("A full-access administrator on the destination"))
        guard case .blocked(let migrator)? = change("migrator") else { Issue.record("migrator: \(String(describing: change("migrator")))"); return }
        #expect(migrator.hasPrefix("The account the destination’s connection signs in with"))
        guard case .blocked(let admins)? = change("Admins") else { Issue.record("Admins: \(String(describing: change("Admins")))"); return }
        #expect(admins.contains("full-access administrator"))
        if case .update = change("helpdesk") {} else { Issue.record("helpdesk: \(String(describing: change("helpdesk")))") }
        if case .update = change("Auditors") {} else { Issue.record("Auditors: \(String(describing: change("Auditors")))") }

        // Run writes only the other two
        let report = await MigrationEngine(source: gateway.source, dest: gateway.dest, journal: makeJournal(),
                                           signedInUsername: "Migrator").run(plan, including: plan.runnableIds)
        #expect(!plan.runnableIds.values.joined().contains("1"))
        let written = Set(gateway.writes(to: "dst").map(\.path))
        #expect(!written.contains { $0.hasSuffix("/accounts/1") || $0.hasSuffix("/accounts/2") || $0.hasSuffix("groupid/7") },
                "\(written)")
        #expect(report.stopReason == nil)
    }

    @Test("An account whose destination access isn't stated is Blocked in a copy too")
    func unreadableAccessIsBlocked() {
        let type = ObjectRegistry.type("jamfusers")!
        let reason = MigrationPlanner.copyKeepReason(type, name: "x", destPayload: .json(["username": "x"]), signedInUsername: nil)
        #expect(reason?.hasPrefix("Its access on the destination couldn’t be read") == true)
        #expect(MigrationPlanner.copyKeepReason(ObjectRegistry.type("scripts")!, name: "x", destPayload: .json([:]),
                                                signedInUsername: "x") == nil)
    }
}

// MARK: - C8 Kept accounts are checked again right before a delete

struct DeleteRechecksAccountsTests {

    @Test("An account made a full-access administrator after Preview stops the run before its delete")
    func promotedAccountIsNotDeleted() async throws {
        let promoted = Locked(false)
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("dst", "GET", "/pro/v1/accounts"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 1, "results": [["id": "3", "username": "helpdesk"]]]))
            case ("dst", "GET", "/pro/v1/accounts/3"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(
                    ["id": "3", "username": "helpdesk", "accessLevel": "FullAccess",
                     "privilegeLevel": promoted.value ? "ADMINISTRATOR" : "CUSTOM"]))
            case ("dst", "DELETE", _):
                return MockHTTP.Reply(status: 204)
            default:
                return nil
            }
        }
        let plan = await MigrationPlanner(source: gateway.dest, dest: gateway.dest).planDeletion(typeKeys: ["jamfusers"])
        #expect(plan.entries.first?.change == .delete)
        promoted.withLock { $0 = true }
        let report = await DeleteEngine(client: gateway.dest, journal: makeJournal(mode: .delete))
            .run(plan, including: plan.runnableIds)
        #expect(gateway.requests.value.filter { $0.method == "DELETE" }.isEmpty, "the new administrator was deleted")
        #expect(report.stopReason?.contains("changed since Preview. A full-access administrator") == true,
                "\(String(describing: report.stopReason))")
    }

    @Test("The signed-in account is checked again too")
    func signedInAccountIsNotDeleted() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("dst", "GET", "/pro/v1/accounts"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 1, "results": [["id": "3", "username": "helpdesk"]]]))
            case ("dst", "GET", "/pro/v1/accounts/3"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(
                    ["id": "3", "username": "helpdesk", "accessLevel": "SiteAccess", "privilegeLevel": "CUSTOM"]))
            case ("dst", "DELETE", _):
                return MockHTTP.Reply(status: 204)
            default:
                return nil
            }
        }
        let plan = await MigrationPlanner(source: gateway.dest, dest: gateway.dest).planDeletion(typeKeys: ["jamfusers"])
        let report = await DeleteEngine(client: gateway.dest, journal: makeJournal(mode: .delete), signedInUsername: "HelpDesk")
            .run(plan, including: plan.runnableIds)
        #expect(gateway.requests.value.filter { $0.method == "DELETE" }.isEmpty)
        #expect(report.stopReason != nil)
    }
}

// MARK: - C13 Icon file names in the upload header

struct IconFileNameTests {

    @Test("Quotes, backslashes and line breaks never reach the upload header", arguments: [
        (#"my "new" icon.png"#, "my _new_ icon.png"),
        ("a\\b.png", "a_b.png"),
        ("line\r\nbreak.png", "line break.png"),
        ("plain.png", "plain.png"),
        ("\"", "_"),
        ("\n", "icon.png"),
    ])
    func headerSafeNames(name: String, expected: String) {
        #expect(IconMigrator.headerSafe(name) == expected)
    }
}

// MARK: - Review of 1.2.3: serials in backups, profile secrets, lossless JSON

struct ExportRedactionReviewTests {

    @Test("Wipe's backup hides license serial numbers")
    func backupHidesLicenseSerials() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("dst", "GET", "/proclassic/licensedsoftware"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["licensed_software": [["id": 1, "name": "Office"]]]))
            case ("dst", "GET", "/proclassic/licensedsoftware/id/1"):
                return MockHTTP.Reply(status: 200, data: Data("""
                <licensed_software><general><id>1</id><name>Office</name></general><licenses><license>\
                <serial_number_1>SERIAL-EXAMPLE-0001</serial_number_1><serial_number_2>SERIAL-EXAMPLE-0002</serial_number_2>\
                </license></licenses></licensed_software>
                """.utf8))
            default:
                return nil
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackupSerials-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await TenantExporter(client: gateway.dest).backup(typeKeys: ["licensedsoftware"], to: root)
        #expect(result.isComplete, "\(result.errors)")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath })
        #expect(files.count == 1)
        let text = try String(contentsOf: try #require(files.first), encoding: .utf8)
        #expect(!text.contains("SERIAL-EXAMPLE"), "\(text)")
        #expect(text.contains("<name>Office</name>"))
    }

    /// A Wi-Fi payload as Classic XML carries it: an escaped plist.
    private static let wifiProfile: String = {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>PayloadContent</key><array><dict>\
        <key>SSID_STR</key><string>Office &amp; Guests</string>\
        <key>Password</key><string>Wifi-Pa55&amp;word</string>\
        <key>EncryptionType</key><string>WPA2</string>\
        <key>EAPClientConfiguration</key><dict><key>UserPassword</key><string>Eap-Pa55</string>\
        <key>AcceptEAPTypes</key><array><integer>25</integer></array></dict>\
        <key>AutoJoin</key><true/></dict></array>\
        <key>PayloadDisplayName</key><string>Office Wi-Fi</string></dict></plist>
        """
        return "<os_x_configuration_profile><general><name>Wi-Fi</name><payloads>\(ClassicXML.escape(plist))</payloads></general></os_x_configuration_profile>"
    }()

    @Test("A profile's Wi-Fi and 802.1X passwords are replaced; every other byte stays")
    func profilePayloadSecrets() {
        let out = String(decoding: ExportWriter.redacted(Data(Self.wifiProfile.utf8), hiding: []), as: UTF8.self)
        #expect(!out.contains("Pa55"), "\(out)")
        let placeholder = ClassicXML.escape(Redaction.placeholder)
        #expect(out.contains("&lt;key&gt;Password&lt;/key&gt;&lt;string&gt;\(placeholder)&lt;/string&gt;"), "\(out)")
        #expect(out.contains("&lt;key&gt;UserPassword&lt;/key&gt;&lt;string&gt;\(placeholder)&lt;/string&gt;"))
        // everything else is exactly as it was
        let expected = Self.wifiProfile
            .replacingOccurrences(of: "Wifi-Pa55&amp;amp;word", with: placeholder)
            .replacingOccurrences(of: "Eap-Pa55", with: placeholder)
        #expect(out == expected)
    }

    @Test("A VPN shared secret in plain plist XML is replaced too")
    func plainPayloadSecret() {
        let xml = "<p><payloads><key>SharedSecret</key><data>c2VjcmV0</data><key>RemoteAddress</key><string>vpn.example.test</string></payloads></p>"
        let out = String(decoding: ExportWriter.redacted(Data(xml.utf8), hiding: []), as: UTF8.self)
        #expect(!out.contains("c2VjcmV0"))
        #expect(out.contains("vpn.example.test"))
    }

    @Test("JSON keeps its numbers, key order and slashes; hidden values are found inside text")
    func losslessJSON() {
        let body = Data(#"{"zeta":0.1,"alpha":3.0,"url":"https:\/\/example.test\/a","note":"key \"Q-1\" here","readWritePassword":"x"}"#.utf8)
        let out = String(decoding: ExportWriter.redacted(body, hiding: [#"Q-1"#]), as: UTF8.self)
        #expect(out.contains(#""zeta": 0.1"#), "\(out)")
        #expect(out.contains(#""alpha": 3.0"#))
        #expect(out.contains(#""url": "https://example.test/a""#))
        #expect(out.contains(#""note": "key \"\#(Redaction.placeholder)\" here""#), "\(out)")
        #expect(out.range(of: "zeta")!.lowerBound < out.range(of: "alpha")!.lowerBound, "key order changed")
        #expect(!out.contains(#""x""#))
    }
}

struct DeleteRetryReviewTests {

    @Test("An account refused once and made an administrator before its retry is never deleted")
    func retryRechecksTheAccount() async throws {
        let promoted = Locked(false)
        let deletes = Locked(0)
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("dst", "GET", "/pro/v1/accounts"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 1, "results": [["id": "3", "username": "helpdesk"]]]))
            case ("dst", "GET", "/pro/v1/accounts/3"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(
                    ["id": "3", "username": "helpdesk", "accessLevel": "FullAccess",
                     "privilegeLevel": promoted.value ? "ADMINISTRATOR" : "CUSTOM"]))
            case ("dst", "DELETE", "/pro/v1/accounts/3"):
                deletes.withLock { $0 += 1 }
                promoted.withLock { $0 = true }
                return MockHTTP.Reply(status: 422, data: MockHTTP.json(["httpStatus": 422, "errors": [["code": "HAS_DEPENDENCIES"]]]))
            default:
                return nil
            }
        }
        let plan = await MigrationPlanner(source: gateway.dest, dest: gateway.dest).planDeletion(typeKeys: ["jamfusers"])
        let report = await DeleteEngine(client: gateway.dest, journal: makeJournal(mode: .delete))
            .run(plan, including: plan.runnableIds)
        #expect(deletes.value == 1, "the new administrator's delete was tried again")
        #expect(report.stopReason?.contains("changed since Preview. A full-access administrator") == true,
                "\(String(describing: report.stopReason))")
        guard case .failed(let reason)? = report.entries.first?.status else {
            Issue.record("expected .failed, got \(String(describing: report.entries.first?.status))")
            return
        }
        #expect(reason.hasPrefix("Refused, and the run ended before its retries were done"))
    }

    @Test("Resume: a delete a Stop ended during its wait that went through counts as deleted")
    func resumedDeleteThatWentThrough() async throws {
        let gone = Locked(false)
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("dst", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 2, "results":
                    (gone.value ? [] : [["id": "5", "name": "Done"]]) + [["id": "6", "name": "Next"]]]))
            case ("dst", "DELETE", "/pro/v1/categories/6"):
                return MockHTTP.Reply(status: 204)
            default:
                return nil
            }
        }
        let plan = await MigrationPlanner(source: gateway.dest, dest: gateway.dest).planDeletion(typeKeys: ["categories"])
        let journal = makeJournal(mode: .delete)
        await journal.begin(planId: plan.id)
        await journal.record(type: "categories", objectId: "5", status: .failed(reason: DeleteEngine.stoppedDuringWait))
        gone.withLock { $0 = true }
        let report = await DeleteEngine(client: gateway.dest, journal: journal).run(plan, including: plan.runnableIds)
        #expect(report.stopReason == nil, "\(String(describing: report.stopReason))")
        #expect(report.deletedCount == 2)
    }
}
