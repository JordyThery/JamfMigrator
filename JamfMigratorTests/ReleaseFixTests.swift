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
