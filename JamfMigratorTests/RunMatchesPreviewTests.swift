//
//  RunMatchesPreviewTests.swift
//  JamfMigratorTests
//
//  Run carries out exactly the plan Preview showed: only ticked Create,
//  Update, Replace and Delete rows; it stops before writing an object that
//  changed since Preview. Verify never passes a type it couldn't read. And
//  the smaller fixes that came with it (sandbox folders, the export switch,
//  gateway-only types, the run reports' location).
//

import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import JamfMigrator

/// A fake pair of tenants whose answers can change between Preview and Run.
private final class Tenants: @unchecked Sendable {
    let lock = NSLock()
    /// Answers by "env METHOD path"; the default for a GET is an empty list.
    private var answers: [String: MockHTTP.Reply] = [:]
    var gateway: FakeGateway!

    init() {
        gateway = FakeGateway { [unowned self] env, method, path, _ in
            self.lock.withLock { self.answers["\(env) \(method) \(path)"] }
        }
    }

    func answer(_ key: String, _ reply: MockHTTP.Reply) {
        lock.withLock { answers[key] = reply }
    }

    func json(_ key: String, _ value: Any) {
        answer(key, MockHTTP.Reply(status: 200, data: MockHTTP.json(value)))
    }

    func categories(_ env: String, _ items: [(String, String)]) {
        json("\(env) GET /pro/v1/categories", ["totalCount": items.count, "results": items.map { ["id": $0.0, "name": $0.1] }])
    }

    func category(_ env: String, id: String, name: String, priority: Int) {
        json("\(env) GET /pro/v1/categories/\(id)", ["id": id, "name": name, "priority": priority])
    }

    var source: JamfPlatform.Client { gateway.source }
    var dest: JamfPlatform.Client { gateway.dest }

    func writes() -> [String] {
        gateway.writes(to: "dst").map { "\($0.method) \($0.path)" }
    }

    func preview(_ typeKeys: Set<String>) async -> MigrationPlan {
        await MigrationPlanner(source: source, dest: dest).plan(typeKeys: typeKeys)
    }

    func run(_ plan: MigrationPlan, including: [String: Set<String>]? = nil) async -> RunReport {
        await MigrationEngine(source: source, dest: dest, journal: makeJournal())
            .run(plan, including: including ?? plan.runnableIds)
    }
}

/// Source: New (5, not on the destination), Same (6, identical to 71),
/// Older (7, differs from 72).
private func threeCategories() -> Tenants {
    let tenants = Tenants()
    tenants.categories("src", [("5", "New"), ("6", "Same"), ("7", "Older")])
    tenants.category("src", id: "5", name: "New", priority: 9)
    tenants.category("src", id: "6", name: "Same", priority: 9)
    tenants.category("src", id: "7", name: "Older", priority: 9)
    tenants.categories("dst", [("71", "Same"), ("72", "Older")])
    tenants.category("dst", id: "71", name: "Same", priority: 9)
    tenants.category("dst", id: "72", name: "Older", priority: 1)
    tenants.json("dst POST /pro/v1/categories", ["id": "77"])
    tenants.json("dst PUT /pro/v1/categories/72", ["id": "72"])
    return tenants
}

struct RunMatchesPreviewTests {

    @Test func runWritesOnlyThePlannedRows() async throws {
        let tenants = threeCategories()
        let plan = await tenants.preview(["categories"])
        #expect(plan.entries.map(\.change) == [.create, .unchanged(destId: "71"), .update(destId: "72")])
        let report = await tenants.run(plan)
        // the Unchanged category is never written
        #expect(tenants.writes() == ["POST /pro/v1/categories", "PUT /pro/v1/categories/72"])
        #expect(report.entries.map(\.objectName) == ["New", "Older"])
        #expect(report.stopReason == nil)
    }

    @Test func tickedRowsOnly() async throws {
        let tenants = threeCategories()
        let plan = await tenants.preview(["categories"])
        _ = await tenants.run(plan, including: ["categories": ["7"]])
        #expect(tenants.writes() == ["PUT /pro/v1/categories/72"])
    }

    @Test func objectsAddedAfterPreviewAreNotCopied() async throws {
        let tenants = threeCategories()
        let plan = await tenants.preview(["categories"])
        tenants.categories("src", [("5", "New"), ("6", "Same"), ("7", "Older"), ("8", "Added later")])
        tenants.category("src", id: "8", name: "Added later", priority: 9)
        let report = await tenants.run(plan)
        #expect(!report.entries.contains { $0.objectName == "Added later" })
        #expect(tenants.writes().count == 2)
    }

    @Test func runUsesThePreviewedTypes() async throws {
        let tenants = threeCategories()
        tenants.json("src GET /pro/v1/scripts", ["totalCount": 1, "results": [["id": "3", "name": "Not previewed"]]])
        let plan = await tenants.preview(["categories"])
        // the run's types are the plan's, whatever is selected now
        _ = await tenants.run(plan, including: plan.runnableIds.merging(["scripts": ["3"]]) { $1 })
        #expect(!tenants.writes().contains { $0.contains("scripts") })
    }

    @Test func sourceDuplicatesBlockBoth() async throws {
        let tenants = Tenants()
        tenants.categories("src", [("5", "Twin"), ("6", "Twin")])
        let plan = await tenants.preview(["categories"])
        #expect(plan.entries.count == 2)
        #expect(plan.entries.allSatisfy { if case .blocked = $0.change { true } else { false } })
        _ = await tenants.run(plan, including: ["categories": ["5", "6"]])
        #expect(tenants.writes().isEmpty)
    }

    @Test func destinationDuplicatesBlock() async throws {
        let tenants = Tenants()
        tenants.categories("src", [("5", "Twin")])
        tenants.category("src", id: "5", name: "Twin", priority: 9)
        tenants.categories("dst", [("71", "Twin"), ("72", "Twin")])
        let plan = await tenants.preview(["categories"])
        guard case .blocked? = plan.entries.first?.change else {
            Issue.record("expected Blocked: \(plan.entries)")
            return
        }
        _ = await tenants.run(plan, including: ["categories": ["5"]])
        #expect(tenants.writes().isEmpty)
    }

    @Test func stopsWhenTheSourceChanged() async throws {
        let tenants = threeCategories()
        let plan = await tenants.preview(["categories"])
        tenants.category("src", id: "5", name: "New", priority: 3)
        let report = await tenants.run(plan)
        #expect(tenants.writes().isEmpty)
        #expect(report.stopReason?.contains("Categories › \"New\": changed on the source since Preview") == true)
        #expect(report.stopReason?.contains("Preview again") == true)
    }

    @Test func stopsWhenTheDestinationChanged() async throws {
        let tenants = threeCategories()
        let plan = await tenants.preview(["categories"])
        tenants.category("dst", id: "72", name: "Older", priority: 4)
        let report = await tenants.run(plan, including: ["categories": ["7"]])
        #expect(tenants.writes().isEmpty)
        #expect(report.stopReason?.contains("\"Older\": changed on the destination since Preview") == true)
    }

    @Test func stopsWhenACreateNameNowExists() async throws {
        let tenants = threeCategories()
        let plan = await tenants.preview(["categories"])
        tenants.categories("dst", [("71", "Same"), ("72", "Older"), ("73", "New")])
        tenants.category("dst", id: "73", name: "New", priority: 9)
        let report = await tenants.run(plan, including: ["categories": ["5"]])
        #expect(tenants.writes().isEmpty)
        #expect(report.stopReason?.contains("an object with this name now exists on the destination") == true)
    }

    @Test func stopsOnANewDuplicate() async throws {
        let tenants = threeCategories()
        let plan = await tenants.preview(["categories"])
        tenants.categories("dst", [("71", "Same"), ("72", "Older"), ("74", "Older")])
        let report = await tenants.run(plan, including: ["categories": ["7"]])
        #expect(tenants.writes().isEmpty)
        #expect(report.stopReason?.contains("more than one destination object is now named \"Older\"") == true)
    }

    /// A script in a category the same run creates: Preview counted the
    /// category as "will exist", and so does the check before writing.
    @Test func createdThisRunIsNotAChange() async throws {
        let tenants = Tenants()
        tenants.categories("src", [("5", "Tools")])
        tenants.category("src", id: "5", name: "Tools", priority: 9)
        tenants.json("src GET /pro/v1/scripts", ["totalCount": 1, "results": [["id": "3", "name": "Hello"]]])
        tenants.json("src GET /pro/v1/scripts/3", ["id": "3", "name": "Hello", "categoryId": "5", "scriptContents": "echo hi"])
        tenants.json("dst POST /pro/v1/categories", ["id": "77"])
        tenants.json("dst POST /pro/v1/scripts", ["id": "88"])
        let plan = await tenants.preview(["categories", "scripts"])
        #expect(plan.entries.first { $0.typeKey == "scripts" }?.plannedDependencies == [PlannedDependency(typeKey: "categories", name: "Tools")])
        let report = await tenants.run(plan)
        #expect(report.stopReason == nil, "\(report.stopReason ?? "")")
        #expect(tenants.writes() == ["POST /pro/v1/categories", "POST /pro/v1/scripts"])
        let script = try #require(tenants.gateway.writes(to: "dst").last?.body)
        let body = try #require(JSONSerialization.jsonObject(with: script) as? [String: Any])
        #expect("\(body["categoryId"] ?? "")" == "77")
    }

    /// Resume run: the category was created by the interrupted first run of
    /// the same plan; the script that refers to it isn't seen as changed.
    @Test func resumeAfterACreateIsNotAChange() async throws {
        let tenants = Tenants()
        tenants.categories("src", [("5", "Tools")])
        tenants.category("src", id: "5", name: "Tools", priority: 9)
        tenants.json("src GET /pro/v1/scripts", ["totalCount": 1, "results": [["id": "3", "name": "Hello"]]])
        tenants.json("src GET /pro/v1/scripts/3", ["id": "3", "name": "Hello", "categoryId": "5", "scriptContents": "echo hi"])
        tenants.json("dst POST /pro/v1/scripts", ["id": "88"])
        let plan = await tenants.preview(["categories", "scripts"])
        // the first run created the category, then was interrupted
        tenants.categories("dst", [("77", "Tools")])
        tenants.category("dst", id: "77", name: "Tools", priority: 9)
        let journal = makeJournal()
        await journal.record(type: "categories", objectId: "5", status: .created(destId: "77"))
        let report = await MigrationEngine(source: tenants.source, dest: tenants.dest, journal: journal)
            .run(plan, including: plan.runnableIds)
        #expect(report.stopReason == nil, "\(report.stopReason ?? "")")
        #expect(tenants.writes() == ["POST /pro/v1/scripts"])
    }

    /// A planned create that fails: the rows that need it aren't written
    /// with a missing reference; everything else carries on.
    @Test func aFailedCreateStopsTheRowsThatNeedIt() async throws {
        let tenants = Tenants()
        tenants.categories("src", [("5", "Tools"), ("6", "Other")])
        tenants.category("src", id: "5", name: "Tools", priority: 9)
        tenants.category("src", id: "6", name: "Other", priority: 9)
        tenants.json("src GET /pro/v1/scripts", ["totalCount": 2, "results": [["id": "3", "name": "Needs Tools"], ["id": "4", "name": "Free"]]])
        tenants.json("src GET /pro/v1/scripts/3", ["id": "3", "name": "Needs Tools", "categoryId": "5", "scriptContents": "echo hi"])
        tenants.json("src GET /pro/v1/scripts/4", ["id": "4", "name": "Free", "categoryId": "-1", "scriptContents": "echo hi"])
        // every category create fails; scripts are accepted
        tenants.answer("dst POST /pro/v1/categories", MockHTTP.Reply(status: 500))
        tenants.json("dst POST /pro/v1/scripts", ["id": "88"])
        let plan = await tenants.preview(["categories", "scripts"])
        let report = await tenants.run(plan)

        let needsTools = report.entries.first { $0.objectName == "Needs Tools" }
        guard case .failed(let reason)? = needsTools?.status else {
            Issue.record("expected the dependent script not to be written: \(String(describing: needsTools))")
            return
        }
        #expect(reason.contains("Categories › \"Tools\""))
        // only the independent script was written; the dependent one never
        let scripts = tenants.gateway.writes(to: "dst").filter { $0.path == "/pro/v1/scripts" }
        #expect(scripts.count == 1)
        let body = try #require(scripts.first?.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["name"] as? String == "Free")
        // a failed row is retried by Resume run
        #expect(report.retryableFailures.contains { $0.objectName == "Needs Tools" })
    }
}

struct DeleteRunMatchesPreviewTests {

    private func policies() -> Tenants {
        let tenants = Tenants()
        tenants.json("dst GET /proclassic/policies", ["policies": [["id": 31, "name": "Chrome"]]])
        tenants.answer("dst DELETE /proclassic/policies/id/31", MockHTTP.Reply(status: 200, data: Data("<policy><id>31</id></policy>".utf8)))
        tenants.answer("dst DELETE /proclassic/policies/id/32", MockHTTP.Reply(status: 200, data: Data("<policy><id>32</id></policy>".utf8)))
        return tenants
    }

    private func plan(_ tenants: Tenants) async -> MigrationPlan {
        await MigrationPlanner(source: tenants.dest, dest: tenants.dest).planDeletion(typeKeys: ["policies"])
    }

    @Test func deletesOnlyPlannedObjects() async throws {
        let tenants = policies()
        let plan = await plan(tenants)
        tenants.json("dst GET /proclassic/policies", ["policies": [["id": 31, "name": "Chrome"], ["id": 32, "name": "Added later"]]])
        let report = await DeleteEngine(client: tenants.dest, journal: makeJournal(mode: .delete)).run(plan, including: plan.runnableIds)
        #expect(tenants.writes() == ["DELETE /proclassic/policies/id/31"])
        #expect(report.stopReason == nil)
    }

    @Test func stopsWhenADeleteTargetChanged() async throws {
        let tenants = policies()
        let plan = await plan(tenants)
        tenants.json("dst GET /proclassic/policies", ["policies": [["id": 31, "name": "Renamed"]]])
        let report = await DeleteEngine(client: tenants.dest, journal: makeJournal(mode: .delete)).run(plan, including: plan.runnableIds)
        #expect(tenants.writes().isEmpty)
        #expect(report.stopReason?.contains("renamed since Preview") == true)
    }
}

struct VerifyNotCheckedTests {

    @Test func unreadableTypeIsNotChecked() async throws {
        let tenants = Tenants()
        tenants.answer("src GET /pro/v1/scripts", MockHTTP.Reply(status: 403))
        let report = await Verifier.verify(source: tenants.source, dest: tenants.dest, typeKeys: ["scripts"])
        #expect(report.types.first?.notChecked != nil)
        #expect(!report.isClean)
    }

    @Test func anUnreadableDestinationListIsNotChecked() async throws {
        let tenants = Tenants()
        tenants.answer("dst GET /pro/v1/scripts", MockHTTP.Reply(status: 403))
        let report = await Verifier.verify(source: tenants.source, dest: tenants.dest, typeKeys: ["scripts"])
        #expect(report.types.first?.notChecked != nil)
        #expect(report.types.first?.destCount == nil)
        #expect(!report.isClean)
    }

    @Test func notCheckedIsNeverClean() {
        var report = VerifyReport()
        report.types = [VerifyReport.TypeResult(typeKey: "scripts", sourceCount: 0, destCount: nil, notChecked: "403")]
        #expect(!report.isClean)
        #expect(report.notCheckedCount == 1)
    }
}

@MainActor
struct RunRulesInTheAppTests {

    /// An app on a fresh sandbox: in-memory tenants, its own settings.
    private func app(demo: Bool = false) -> AppState {
        let defaults = UserDefaults(suiteName: "jamfmigrator-run-\(UUID().uuidString)")!
        let arguments = ["app", "-JTKitSandbox", "YES"] + (demo ? ["-JTKitDemo", "YES"] : [])
        let mode = DemoMode(key: "demoMode", defaults: defaults, arguments: arguments)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RunRules-\(UUID().uuidString)")
        let store = TenantStore(directory: directory, secrets: InMemorySecretStore(), log: nil, demo: mode,
                                storage: InMemoryConnectionStorage<Tenant>())
        return AppState(tenantStore: store, secretStore: InMemorySecretStore(), demo: mode, defaults: defaults)
    }

    /// A category and a script in it, both to be created.
    private func plan(typeKeys: Set<String>) -> MigrationPlan {
        var script = ObjectPlan(typeKey: "scripts", objectId: "3", name: "Hello", change: .create)
        script.plannedDependencies = [PlannedDependency(typeKey: "categories", name: "Tools")]
        return MigrationPlan(mode: .copy, entries: [
            ObjectPlan(typeKey: "categories", objectId: "5", name: "Tools", change: .create), script,
        ], typeKeys: typeKeys)
    }

    @Test func untickedDependencyBlocksRun() {
        let app = app()
        app.selectedTypeKeys = ["categories", "scripts"]
        app.plan = plan(typeKeys: ["categories", "scripts"])
        app.includedObjectIds = ["scripts": ["3"]]
        #expect(app.runBlockedReason?.contains("needs Categories › \"Tools\"") == true)
        #expect(app.waitingOn(app.plan!.entries[0]).map(\.name) == ["Hello"])
        app.setIncluded(true, app.plan!.entries[0])
        #expect(app.runBlockedReason == nil)
    }

    @Test func changingTheSelectionNeedsANewPreview() {
        let app = app()
        app.selectedTypeKeys = ["categories", "scripts"]
        app.plan = plan(typeKeys: ["categories", "scripts"])
        app.includedObjectIds = app.plan!.runnableIds
        #expect(app.runBlockedReason == nil)
        app.selectedTypeKeys.insert("policies")
        #expect(app.runBlockedReason == "The selected types changed since Preview. Preview again.")
    }

    @Test func checkAllAndUncheckAll() {
        let app = app()
        app.plan = plan(typeKeys: ["categories", "scripts"])
        app.setAllIncluded(true, typeKey: "scripts")
        #expect(app.includedObjectIds["scripts"] == ["3"])
        app.setAllIncluded(false, typeKey: "scripts")
        #expect(app.includedObjectIds["scripts"] == [])
    }

    /// Only a digest of each value is compared; the words never carry one.
    @Test func secretsChangedSincePreview() {
        let atPreview = AppState.digests(of: ["bind": "first-value"])
        #expect(!atPreview.values.contains("first-value"))
        let reason = AppState.inputChange(secrets: ["bind": "second-value"], mappings: TenantMappings(), mode: .copy,
                                          previewDigests: atPreview, previewMappings: TenantMappings())
        #expect(reason == "Secrets changed since Preview.")
        #expect(AppState.inputChange(secrets: ["bind": "first-value"], mappings: TenantMappings(), mode: .copy,
                                     previewDigests: atPreview, previewMappings: TenantMappings()) == nil)
        var report = RunReport()
        report.stopReason = (reason ?? "") + " Nothing was written; Preview again."
        let text = RunReportFile(report: report, mode: .copy, sourceName: "S", destinationName: "D",
                                 started: .now, finished: .now, wasStopped: false).text
        #expect(text.contains("Secrets changed since Preview."))
        #expect(!text.contains("first-value") && !text.contains("second-value"))
    }

    @Test func sandboxRunUsesATemporaryFolder() {
        let app = app()
        let real = URL(fileURLWithPath: AppInfo.appSupportPath).standardizedFileURL.path
        #expect(!app.dataDirectory.standardizedFileURL.path.hasPrefix(real))
        #expect(app.dataDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(app.runReportsLocation.contains("sandbox"))
    }

    @Test func exportSwitchUsesTheAppsSettings() {
        let app = app()
        let real = UserDefaults.standard.object(forKey: "exportOnRun") as? Bool
        app.exportOnRun = !(real ?? false)
        #expect(app.exportOnRun == !(real ?? false))
        #expect(UserDefaults.standard.object(forKey: "exportOnRun") as? Bool == real)
    }

    @Test func gatewayTypesAreNotPlannedOnDirectTenants() {
        // demo mode's tenants connect directly to Jamf Pro
        let app = app(demo: true)
        app.selectedTypeKeys = ["categories", "blueprints"]
        #expect(app.previewTypeKeys == ["categories"])
        #expect(app.selectedTypeKeys.contains("blueprints"))
        #expect(app.runReportsLocation.contains("demo mode"))
    }
}
