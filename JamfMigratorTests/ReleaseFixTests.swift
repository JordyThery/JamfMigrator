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
}
