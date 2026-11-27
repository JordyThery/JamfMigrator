//
//  StopAndResumeTests.swift
//  JamfMigratorTests
//
//  A run ended with Stop before its last checked row is a stopped run: the
//  plan and the journal stay and Resume Run carries on (copy and delete
//  mode). A delete run that ends with objects still waiting for a retry
//  reports them with Jamf's reason.
//

import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import JamfMigrator

private func categories(_ pairs: [(String, String)]) -> MockHTTP.Reply {
    MockHTTP.Reply(status: 200, data: MockHTTP.json(
        ["totalCount": pairs.count, "results": pairs.map { ["id": $0.0, "name": $0.1] }]))
}

private func category(_ id: String, _ name: String) -> MockHTTP.Reply {
    MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": id, "name": name, "priority": 9]))
}

private func postedName(_ body: Data?) -> String? {
    (body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["name"] as? String
}

struct StoppedEngineTests {

    @Test("Stop before the last checked row: the copy report says stopped, 1 of 2 done")
    func copyStoppedBeforeTheEnd() async throws {
        let engineBox = Locked<MigrationEngine?>(nil)
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/pro/v1/categories"): return categories([("1", "One"), ("2", "Two")])
            case ("src", "GET", "/pro/v1/categories/1"): return category("1", "One")
            case ("src", "GET", "/pro/v1/categories/2"): return category("2", "Two")
            case ("dst", "POST", "/pro/v1/categories"):
                let engine = engineBox.value
                Task { await engine?.cancel() }
                Thread.sleep(forTimeInterval: 0.3)
                return MockHTTP.Reply(status: 201, data: MockHTTP.json(["id": "11"]))
            default: return nil
            }
        }
        let engine = MigrationEngine(source: gateway.source, dest: gateway.dest, journal: makeJournal())
        engineBox.value = engine
        let plan = await MigrationPlanner(source: gateway.source, dest: gateway.dest).plan(typeKeys: ["categories"])
        let report = await engine.run(plan, including: plan.runnableIds)
        #expect(report.wasStopped)
        #expect(report.checkedCount == 2)
        #expect(report.doneOfChecked == "1 of 2")
    }

    @Test("Stop during the last checked row's write: the run finished")
    func stopDuringTheLastWriteIsFinished() async throws {
        let engineBox = Locked<MigrationEngine?>(nil)
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/pro/v1/categories"): return categories([("1", "One")])
            case ("src", "GET", "/pro/v1/categories/1"): return category("1", "One")
            case ("dst", "POST", "/pro/v1/categories"):
                let engine = engineBox.value
                Task { await engine?.cancel() }
                Thread.sleep(forTimeInterval: 0.3)
                return MockHTTP.Reply(status: 201, data: MockHTTP.json(["id": "11"]))
            default: return nil
            }
        }
        let engine = MigrationEngine(source: gateway.source, dest: gateway.dest, journal: makeJournal())
        engineBox.value = engine
        let plan = await MigrationPlanner(source: gateway.source, dest: gateway.dest).plan(typeKeys: ["categories"])
        let report = await engine.run(plan, including: plan.runnableIds)
        #expect(!report.wasStopped)
        #expect(report.doneOfChecked == "1 of 1")
    }

    @Test("Delete: Stop with an object waiting for its retry reports it with Jamf's reason")
    func deleteStoppedWithAHeldObject() async throws {
        let engineBox = Locked<DeleteEngine?>(nil)
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("dst", "GET", "/pro/v1/categories"): return categories([("5", "Held"), ("6", "Free"), ("7", "Later")])
            case ("dst", "DELETE", "/pro/v1/categories/5"):
                return MockHTTP.Reply(status: 422, data: MockHTTP.json(["httpStatus": 422, "errors": [["code": "HAS_DEPENDENCIES"]]]))
            case ("dst", "DELETE", "/pro/v1/categories/6"):
                let engine = engineBox.value
                Task { await engine?.cancel() }
                Thread.sleep(forTimeInterval: 0.3)
                return MockHTTP.Reply(status: 204)
            default: return nil
            }
        }
        let plan = await MigrationPlanner(source: gateway.dest, dest: gateway.dest).planDeletion(typeKeys: ["categories"])
        let journal = makeJournal(mode: .delete)
        let engine = DeleteEngine(client: gateway.dest, journal: journal)
        engineBox.value = engine
        let report = await engine.run(plan, including: plan.runnableIds)

        #expect(report.wasStopped)
        #expect(report.doneOfChecked == "1 of 3")
        let held = try #require(report.entries.first { $0.objectName == "Held" })
        guard case .failed(let reason) = held.status else {
            Issue.record("Held isn't reported as failed: \(held.status)")
            return
        }
        #expect(reason.hasPrefix("Refused, and not tried again"), "\(reason)")
        #expect(reason.contains("422"), "Jamf's reason is lost: \(reason)")
        #expect(await journal.status(type: "categories", objectId: "5") == held.status)
        #expect(!report.entries.contains { $0.objectName == "Later" }, "Later was never tried")
    }

    @Test("Delete: an object still refused after every retry keeps Jamf's own reason")
    func stillRefusedKeepsTheReason() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("dst", "GET", "/pro/v1/categories"): return categories([("5", "Busy")])
            case ("dst", "DELETE", "/pro/v1/categories/5"):
                return MockHTTP.Reply(status: 409, data: MockHTTP.json(["httpStatus": 409, "errors": [["description": "Locked by another admin"]]]))
            default: return nil
            }
        }
        let plan = await MigrationPlanner(source: gateway.dest, dest: gateway.dest).planDeletion(typeKeys: ["categories"])
        let report = await DeleteEngine(client: gateway.dest, journal: makeJournal(mode: .delete))
            .run(plan, including: plan.runnableIds)
        #expect(!report.wasStopped)
        guard case .failed(let reason)? = report.entries.first?.status else {
            Issue.record("expected .failed, got \(String(describing: report.entries.first?.status))")
            return
        }
        #expect(reason.hasPrefix("Still refused after every retry"), "\(reason)")
        #expect(reason.contains("409"), "Jamf's reason is lost: \(reason)")
    }

    @Test("A stopped run's report file says how far it got and that Resume Run carries on")
    func stoppedReportText() {
        var report = RunReport()
        report.entries = [RunReportEntry(type: "categories", objectId: "1", objectName: "One", status: .created(destId: "11"))]
        report.checkedCount = 3
        report.wasStopped = true
        let text = RunReportFile(report: report, mode: .copy, sourceName: "A", destinationName: "B",
                                 started: .now, finished: .now, wasStopped: true).text
        #expect(text.contains("(1 of 3 done)"))
        #expect(text.contains("Resume Run carries on"))
    }
}

@MainActor
final class StoppedAppTests {

    private let suites = Locked<[String]>([])

    deinit {
        for name in suites.value { RegressionTests.removeDefaults(named: name) }
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(30),
                           _ what: String = "Timed out") async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else {
                Issue.record(Comment(rawValue: what))
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// An app whose two tenants (Platform API) are answered by `server`.
    private func app(_ server: TwoTenantServer) throws -> AppState {
        let name = "jamfmigrator-stop-\(UUID().uuidString)"
        suites.withLock { $0.append(name) }
        let defaults = UserDefaults(suiteName: name)!
        let mode = DemoMode(key: "demoMode", defaults: defaults, arguments: ["app", "-JTKitSandbox", "YES"])
        let secrets = InMemorySecretStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Stop-\(UUID().uuidString)")
        let store = TenantStore(directory: directory, secrets: secrets, log: nil, session: server.session, demo: mode,
                                storage: InMemoryConnectionStorage<Tenant>(), savedTenantGuard: nil)
        let source = Tenant(connection: Connection(name: "A", service: .jamfPlatform, region: .us,
                                                   environmentID: TestEnvironment.source, clientID: "a"))
        let dest = Tenant(connection: Connection(name: "B", service: .jamfPlatform, region: .us,
                                                 environmentID: TestEnvironment.destination, clientID: "b"))
        try store.connections.save(source, secrets: [.main: "secret-a"])
        try store.connections.save(dest, secrets: [.main: "secret-b"])
        let app = AppState(tenantStore: store, secretStore: InMemorySecretStore(), demo: mode, defaults: defaults)
        app.sourceTenantID = source.id
        app.destTenantID = dest.id
        return app
    }

    @Test("A stopped copy keeps its plan and journal; Resume Run writes only what's left")
    func stoppedCopyResumes() async throws {
        let appBox = Locked<AppState?>(nil)
        let stopOnce = Locked(true)
        let server = TwoTenantServer { env, method, path, body in
            switch (env, method, path) {
            case ("src", "GET", "/pro/v1/categories"): return categories([("1", "Alpha"), ("2", "Beta")])
            case ("src", "GET", "/pro/v1/categories/1"): return category("1", "Alpha")
            case ("src", "GET", "/pro/v1/categories/2"): return category("2", "Beta")
            case ("dst", "POST", "/pro/v1/categories"):
                if stopOnce.value {
                    stopOnce.withLock { $0 = false }
                    let app = appBox.value
                    Task { @MainActor in app?.cancel() }
                    Thread.sleep(forTimeInterval: 0.3)
                }
                return MockHTTP.Reply(status: 201, data: MockHTTP.json(["id": postedName(body) == "Alpha" ? "11" : "12"]))
            default: return nil
            }
        }
        let app = try app(server)
        appBox.withLock { $0 = app }
        app.selectedTypeKeys = ["categories"]
        app.preview()
        try await waitUntil { !app.isPlanning }
        #expect(app.run())
        try await waitUntil({ !app.isRunning }, "The run didn't stop")

        #expect(app.report?.wasStopped == true)
        #expect(app.report?.doneOfChecked == "1 of 2")
        #expect(app.plan != nil, "A stopped run discarded its plan")
        #expect(app.canResume)
        #expect(app.canRun)
        #expect(app.runConfirmationMessage.contains("is skipped"))

        #expect(app.run())
        try await waitUntil({ !app.isRunning }, "Resume Run didn't end")
        let posts = server.writes("dst").map { postedName($0.body) }
        #expect(posts == ["Alpha", "Beta"], "Resume Run wrote again what the stopped run did: \(posts)")
        #expect(app.report?.wasStopped == false)
        #expect(app.plan == nil, "A finished run keeps its plan")
        #expect(!app.canResume)
    }

    @Test("A stopped wipe keeps its plan, so Resume Run is offered")
    func stoppedDeleteResumes() async throws {
        let appBox = Locked<AppState?>(nil)
        let server = TwoTenantServer { env, method, path, _ in
            switch (env, method, path) {
            case ("dst", "GET", "/pro/v1/categories"): return categories([("5", "One"), ("6", "Two")])
            case ("dst", "DELETE", "/pro/v1/categories/5"):
                let app = appBox.value
                Task { @MainActor in app?.cancel() }
                Thread.sleep(forTimeInterval: 0.3)
                return MockHTTP.Reply(status: 204)
            case ("dst", "DELETE", "/pro/v1/categories/6"):
                return MockHTTP.Reply(status: 204)
            default: return nil
            }
        }
        let app = try app(server)
        appBox.withLock { $0 = app }
        app.mode = .delete
        app.selectedTypeKeys = ["categories"]
        app.preview()
        try await waitUntil { !app.isPlanning }
        #expect(app.run())
        try await waitUntil({ !app.isRunning }, "The run didn't stop")
        #expect(app.report?.wasStopped == true)
        #expect(app.report?.doneOfChecked == "1 of 2")
        #expect(app.canResume)
        #expect(app.wipeGatesPass(typedName: "B", backupSkipped: true), "the plan is still there to resume")
        #expect(server.writes("dst").map(\.path) == ["/pro/v1/categories/5"])
    }

    @Test("A tenant edited after Preview turns Run off, also when no window saw the edit (C6)")
    func editedTenantTurnsRunOff() async throws {
        let server = TwoTenantServer { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/pro/v1/categories"): return categories([("1", "Alpha")])
            case ("src", "GET", "/pro/v1/categories/1"): return category("1", "Alpha")
            default: return nil
            }
        }
        let app = try app(server)
        app.selectedTypeKeys = ["categories"]
        app.preview()
        try await waitUntil { !app.isPlanning }
        #expect(app.canRun)

        // Settings › Connections: the destination's client changes; no
        // ContentView is there to clear the plan
        var edited = try #require(app.destTenant)
        edited.clientId = "another-client"
        try app.tenantStore.connections.save(edited, secrets: [.main: "secret-c"])
        #expect(app.plan != nil)
        #expect(!app.canRun, "a plan for the old connection could run")
        #expect(app.runBlockedReason?.hasPrefix("The tenants or how they connect changed since Preview") == true)
        #expect(!app.run())
        #expect(server.writes("dst").isEmpty)
    }
}
