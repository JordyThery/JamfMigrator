//
//  RegressionTests.swift
//  JamfMigratorTests
//
//  What 1.1.0 changed by accident, fixed in 1.2.0: the Clone wizard's
//  mappings, Run's check before writing, Stop during a wait, Onboarding's
//  dependency lists and Wipe's backup.
//

import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import JamfMigrator

@MainActor
final class RegressionTests {

    /// The preference suites this test made, removed when it ends, so no
    /// test leaves a preferences file behind.
    private let suites = Locked<[String]>([])

    deinit {
        for name in suites.value { RegressionTests.removeDefaults(named: name) }
    }

    /// A fresh preference suite for one test.
    private func testDefaults() -> UserDefaults {
        let name = "jamfmigrator-regression-\(UUID().uuidString)"
        suites.withLock { $0.append(name) }
        return UserDefaults(suiteName: name)!
    }

    nonisolated static func removeDefaults(named name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }

    /// An app on a fresh sandbox, in demo mode: the two demo tenants, which
    /// connect directly to Jamf Pro and have ADE instances and distribution points.
    private func demoApp() -> AppState {
        let defaults = testDefaults()
        let mode = DemoMode(key: "demoMode", defaults: defaults, arguments: ["app", "-JTKitSandbox", "YES", "-JTKitDemo", "YES"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Regression-\(UUID().uuidString)")
        let store = TenantStore(directory: directory, secrets: InMemorySecretStore(), log: nil, demo: mode,
                                storage: InMemoryConnectionStorage<Tenant>())
        return AppState(tenantStore: store, secretStore: InMemorySecretStore(), demo: mode, defaults: defaults)
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(30)) async throws {
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

    // MARK: #2 Clone Tenant's mappings

    @Test("Preview waits until the mappings proposed for the pair have loaded")
    func previewWaitsForTheMappings() async throws {
        let app = demoApp()
        #expect(app.demo.isOn)
        app.selectedTypeKeys = ["categories"]
        app.loadMappingCandidates()
        #expect(app.isLoadingMappings)
        #expect(!app.canPreview, "Preview would use mappings that are about to change")
        try await waitUntil { !app.isLoadingMappings }
        #expect(app.mappings.adeInstances == ["1": "4"], "the proposal is applied before Preview")
        #expect(app.canPreview)

        app.preview()
        try await waitUntil { !app.isPlanning }
        #expect(app.canRun)
        app.run()
        try await waitUntil { !app.isRunning }
        #expect(app.report?.stopReason == nil, "the mappings are the ones Preview used")
    }

    @Test("A mapping changed after Preview turns Run off at once; Back and Preview Again turn it on")
    func changedMappingsTurnRunOff() async throws {
        let app = demoApp()
        app.selectedTypeKeys = ["categories"]
        app.loadMappingCandidates()
        try await waitUntil { !app.isLoadingMappings }
        app.preview()
        try await waitUntil { !app.isPlanning }
        #expect(app.canRun)
        // review finding 9: Back to Prepare, a mapping changed
        app.mappings.adeInstances["1"] = nil
        #expect(!app.canRun, "Run stays on with mappings Preview didn't use")
        #expect(app.runBlockedReason?.contains("mappings changed since Preview") == true, "\(app.runBlockedReason ?? "")")
        #expect(app.run() == false)

        // the Run step offers Preview Again; Back goes to Preview too
        #expect(CloneWizard.previous(of: .run) == .preview)
        #expect(CloneWizard.previous(of: .connect) == nil)
        #expect(app.canPreview)
        app.preview()
        try await waitUntil { !app.isPlanning }
        #expect(app.runBlockedReason == nil && app.canRun)
    }

    // MARK: #4 Run's check before writing

    @Test("Run's digest treats as equal what Preview's comparison does")
    func digestFollowsPayloadDiff() {
        let previewed: [String: Any] = ["name": "Tools", "notes": "", "enabled": true, "priority": 9, "items": [["id": 1]]]
        let now: [String: Any] = ["name": "Tools", "enabled": "true", "priority": "9", "items": [["id": "1"]]]
        #expect(PayloadDiff.diff(source: previewed, destination: now).isEmpty)
        #expect(MigrationPlanner.digest(previewed) == MigrationPlanner.digest(now))

        var planned = ObjectPlan(typeKey: "categories", objectId: "5", name: "Tools", change: .update(destId: "71"))
        planned.sourceDigest = MigrationPlanner.digest(previewed)
        var again = planned
        again.sourceDigest = MigrationPlanner.digest(now)
        #expect(MigrationEngine.changeSincePreview(planned: planned, now: again) == nil)

        // a real difference still stops the run
        for changed: [String: Any] in [["name": "Tools", "priority": 10], ["name": "Tools", "priority": 9, "items": []],
                                        ["name": "Tools", "priority": 9, "items": [["id": 1], ["id": 2]]]] {
            #expect(!PayloadDiff.diff(source: previewed, destination: changed).isEmpty)
            #expect(MigrationPlanner.digest(previewed) != MigrationPlanner.digest(changed))
        }
    }

    @Test("A field Jamf answers differently between Preview and Run, but Preview treats as equal, doesn't stop the run")
    func reserializedFieldDoesNotStopTheRun() async throws {
        let reads = Locked(0)
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 1, "results": [["id": "5", "name": "Tools"]]]))
            case ("src", "GET", "/pro/v1/categories/5"):
                // Preview reads a number, Run a string
                let first = reads.withLock { count -> Bool in count += 1; return count == 1 }
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "5", "name": "Tools", "priority": first ? 9 : "9"] as [String: Any]))
            case ("dst", "POST", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 201, data: MockHTTP.json(["id": "77"]))
            default:
                return nil
            }
        }
        let report = await MigrationEngine(source: gateway.source, dest: gateway.dest, journal: makeJournal())
            .migrate(typeKeys: ["categories"])
        #expect(report.stopReason == nil)
        #expect(report.entries.first?.status == .created(destId: "77"))
    }

    // MARK: #6 Stop

    @Test("Stop ends a wait before a retry at once; the request isn't sent again")
    func stopEndsARetryWait() async throws {
        let posts = Locked(0)
        let session = MockHTTP.session { request in
            let path = request.url?.path ?? ""
            if path == "/auth/token" { return MockHTTP.tokenJSON() }
            let source = request.value(forHTTPHeaderField: "X-Environment-Id") == TestEnvironment.source
            switch (source, request.httpMethod ?? "", path) {
            case (true, "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 1, "results": [["id": "5", "name": "Tools"]]]))
            case (true, "GET", "/pro/v1/categories/5"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "5", "name": "Tools", "priority": 9]))
            case (false, "POST", "/pro/v1/categories"):
                posts.withLock { $0 += 1 }
                return MockHTTP.Reply(status: 429, headers: ["Retry-After": "50"])
            case (_, "GET", _):
                return MockHTTP.Reply(status: 200, data: FakeGateway.emptyList(at: path) ?? Data(#"{"totalCount":0,"results":[]}"#.utf8))
            default:
                return MockHTTP.Reply(status: 404)
            }
        }
        let waits = RequestWaits()
        let source = JamfPlatform.Client.fake(environmentId: TestEnvironment.source, session: session)
        let recorder = RequestRecorder(session: session, log: nil, service: "Jamf Platform API", waits: waits)
        let tokens = JamfPlatform.TokenProvider(tokenURL: JamfRegion.us.gatewayURL.appending(path: "auth/token"),
                                                method: .apiClient(clientID: "id"), secret: { "secret" }, recorder: recorder)
        let dest = try JamfPlatform.Client(baseURL: JamfRegion.us.gatewayURL, scope: .environment(TestEnvironment.destination),
                                           tokens: tokens, recorder: recorder)
        let plan = await MigrationPlanner(source: source, dest: dest).plan(typeKeys: ["categories"])
        let engine = MigrationEngine(source: source, dest: dest, journal: makeJournal())
        let run = Task { await engine.run(plan, including: plan.runnableIds) }

        try await waitUntil { !waits.current.isEmpty }
        #expect(waits.statusText == "Jamf asked to wait 50 s")
        let stopped = ContinuousClock.now
        await engine.cancel()
        waits.cancelAll()
        let report = await run.value
        #expect(ContinuousClock.now - stopped < .seconds(5), "Stop didn't wait out the 50 s")
        #expect(posts.value == 1, "the write isn't sent again")
        #expect(report.entries.first?.status == .failed(reason: MigrationEngine.stoppedDuringWait))
    }

    @Test("Stop ends a Blueprint's deploy watch at once, after the write")
    func stopEndsADeployWatch() async throws {
        let deployed = Locked(false)
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/blueprints/v1/blueprints"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 1, "results": [["id": "B1", "name": "Baseline"]]]))
            case ("src", "GET", "/blueprints/v1/blueprints/B1"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(
                    ["id": "B1", "name": "Baseline", "deploymentState": ["state": "DEPLOYED"], "steps": []]))
            case ("dst", "POST", "/blueprints/v1/blueprints"):
                return MockHTTP.Reply(status: 201, data: MockHTTP.json(["id": "B7"]))
            case ("dst", "POST", "/blueprints/v1/blueprints/B7/deploy"):
                deployed.withLock { $0 = true }
                return MockHTTP.Reply(status: 202)
            case ("dst", "GET", "/blueprints/v1/blueprints/B7"):
                // the deployment never confirms
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(
                    ["id": "B7", "name": "Baseline", "deploymentState": ["state": "NOT_DEPLOYED"]]))
            case ("dst", "GET", "/blueprints/v1/blueprints/B7/report"):
                return MockHTTP.Reply(status: 404)
            default:
                return nil
            }
        }
        let engine = MigrationEngine(source: gateway.source, dest: gateway.dest, journal: makeJournal())
        let run = Task { await engine.migrate(typeKeys: ["blueprints"]) }
        try await waitUntil { deployed.value }
        try await Task.sleep(for: .milliseconds(200))
        let stopped = ContinuousClock.now
        await engine.cancel()
        let report = await run.value
        #expect(ContinuousClock.now - stopped < .seconds(5), "Stop didn't wait out the 60 s watch")
        #expect(report.entries.first?.status == .created(destId: "B7"), "the write itself finished")
        #expect(report.entries.first?.warnings.first?.hasSuffix(MigrationEngine.watchStopped) == true,
                "\(report.entries.first?.warnings ?? [])")
    }

    // stopShowsStopping and the other Stop tests of the 1.2.0 review are in
    // ReviewFixTests below.

    // MARK: #7 Onboarding

    /// Onboarding on both tenants, the source's with `items`; the
    /// destination's policies list is refused.
    private func onboardingGateway(items: [[String: Any]]) -> FakeGateway {
        FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/pro/v1/onboarding"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["enabled": true, "onboardingItems": items]))
            case ("dst", "GET", "/pro/v1/onboarding"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["enabled": false, "onboardingItems": [[String: Any]]()]))
            case (_, "GET", "/proclassic/osxconfigurationprofiles"):
                let id = env == "src" ? 3 : 13
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["os_x_configuration_profiles": [["id": id, "name": "Wi-Fi"]]]))
            case ("dst", "GET", "/proclassic/policies"):
                return MockHTTP.Reply(status: 403, data: Data(#"{"httpStatus":403,"errors":[{"code":"BAD_PERMISSIONS"}]}"#.utf8))
            default:
                return nil
            }
        }
    }

    @Test("A refused dependency list doesn't block Onboarding when no item needs it")
    func onboardingWithoutTheRefusedList() async throws {
        let gateway = onboardingGateway(items: [
            ["entityId": "3", "selfServiceEntityType": "OS_X_CONFIGURATION_PROFILE", "priority": 1],
        ])
        let plan = await MigrationPlanner(source: gateway.source, dest: gateway.dest).plan(typeKeys: ["onboarding"])
        let entry = try #require(plan.entries.first { $0.typeKey == "onboarding" })
        if case .blocked(let reason) = entry.change { Issue.record("Blocked: \(reason)") }
        #expect(plan.entries.count == 1, "not “(all objects)”")

        let report = await MigrationEngine(source: gateway.source, dest: gateway.dest, journal: makeJournal())
            .run(plan, including: plan.runnableIds)
        #expect(report.stopReason == nil)
        let write = try #require(gateway.writes(to: "dst").first)
        let body = try #require(write.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let sent = body["onboardingItems"] as? [[String: Any]]
        #expect(sent?.first?["entityId"] as? String == "13", "matched by name on the destination")
    }

    @Test("An item that needs the refused list blocks Onboarding, naming the list")
    func onboardingItemNeedingTheRefusedList() async throws {
        let gateway = onboardingGateway(items: [
            ["entityId": "3", "selfServiceEntityType": "OS_X_CONFIGURATION_PROFILE", "priority": 1],
            ["entityId": "8", "selfServiceEntityType": "OS_X_POLICY", "entityName": "Install Notes", "priority": 2],
        ])
        let plan = await MigrationPlanner(source: gateway.source, dest: gateway.dest).plan(typeKeys: ["onboarding"])
        let entry = try #require(plan.entries.first { $0.typeKey == "onboarding" })
        guard case .blocked(let reason) = entry.change else {
            Issue.record("Not blocked: \(entry.change)")
            return
        }
        #expect(reason.contains("“Install Notes”") && reason.contains("the list of Policies couldn’t be read"), "\(reason)")
        #expect(entry.name != "(all objects)")
    }

    // MARK: JTKit 1.1.0: a Keychain that can't be read

    /// A Keychain that is locked: every read fails.
    private struct LockedKeychain: SecretStore {
        func secret(for account: String) -> String? { nil }
        func setSecret(_ secret: String?, for account: String) -> Bool { false }
        func readSecret(for account: String) throws -> String? { throw SecretStoreError(status: errSecInteractionNotAllowed) }
    }

    @Test("A tenant secret the Keychain can't read is reported as such, not as “no secret”")
    func tenantSecretKeychainError() async throws {
        let session = MockHTTP.session { _ in MockHTTP.Reply(status: 500) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Regression-\(UUID().uuidString)")
        let store = TenantStore(directory: directory, secrets: LockedKeychain(), log: nil, session: session,
                                storage: InMemoryConnectionStorage<Tenant>(), savedTenantGuard: nil)
        let tenant = Tenant(connection: Connection(name: "Lab", service: .jamfPlatform, region: .eu,
                                                   environmentID: TestEnvironment.destination, clientID: "id"))
        do {
            _ = try await store.client(for: tenant).send(.get, "pro/v1/categories")
            Issue.record("The request was sent")
        } catch {
            #expect(error.localizedDescription.contains("Keychain couldn’t be read"), "\(error.localizedDescription)")
            #expect(!error.localizedDescription.contains("No client secret"))
        }
    }

    @Test("Preview doesn't start when Settings › Secrets can't be read, and says why")
    func serviceSecretKeychainError() throws {
        let defaults = testDefaults()
        let mode = DemoMode(key: "demoMode", defaults: defaults, arguments: ["app", "-JTKitSandbox", "YES"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Regression-\(UUID().uuidString)")
        let store = TenantStore(directory: directory, secrets: InMemorySecretStore(), log: nil, demo: mode,
                                storage: InMemoryConnectionStorage<Tenant>())
        let app = AppState(tenantStore: store, secretStore: LockedKeychain(), demo: mode, defaults: defaults)
        let source = Tenant(connection: Connection(name: "A", service: .jamfPlatform, region: .eu,
                                                   environmentID: TestEnvironment.source, clientID: "a"))
        let dest = Tenant(connection: Connection(name: "B", service: .jamfPlatform, region: .eu,
                                                 environmentID: TestEnvironment.destination, clientID: "b"))
        try store.connections.save(source)
        try store.connections.save(dest)
        app.sourceTenantID = source.id
        app.destTenantID = dest.id
        app.selectedTypeKeys = ["categories"]
        #expect(app.canPreview)
        #expect(throws: SecretStoreError.self) { try app.serviceSecret("ldap") }
        app.preview()
        #expect(!app.isPlanning)
        #expect(app.lastError?.contains("Keychain couldn’t be read") == true, "\(app.lastError ?? "")")
    }

    // MARK: #11 (JTKit 1.1.0): server addresses

    @Test("A direct tenant saved without a scheme gets https://; an http:// one says to use https")
    func serverAddresses() async throws {
        let session = MockHTTP.session { _ in MockHTTP.Reply(status: 500) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Regression-\(UUID().uuidString)")
        let saved = [
            Tenant(connection: Connection(name: "Bare", service: .jamfPro, signIn: .usernamePassword,
                                          serverURL: "jamf.example.test", username: "admin")),
            Tenant(connection: Connection(name: "Clear", service: .jamfPro, signIn: .usernamePassword,
                                          serverURL: "http://jamf.example.test", username: "admin")),
        ]
        let store = TenantStore(directory: directory, secrets: InMemorySecretStore(), log: nil, session: session,
                                storage: InMemoryConnectionStorage<Tenant>(saved), savedTenantGuard: nil)
        let bare = try #require(store.tenants.first { $0.name == "Bare" })
        #expect(bare.serverURL == "https://jamf.example.test")
        let clear = try #require(store.tenants.first { $0.name == "Clear" })
        do {
            _ = try await store.client(for: clear).send(.get, "pro/v1/categories")
            Issue.record("The request was sent")
        } catch {
            #expect(error.localizedDescription.contains(Connection.httpAddressProblem), "\(error.localizedDescription)")
        }
    }

    // MARK: #8 Wipe's backup

    @Test("Wipe's backup uses the types Preview plans, not gateway-only ones a direct tenant can't reach")
    func backupUsesPreviewTypes() async throws {
        let app = demoApp()
        app.mode = .delete
        #expect(app.selectedTypeKeys.contains("blueprints"), "all types selected")
        #expect(!app.previewTypeKeys.contains("blueprints"))
        app.backup()
        try await waitUntil({ !app.isBackingUp }, timeout: .seconds(120))
        let result = try #require(app.backupResult)
        #expect(result.isComplete, "\(result.errors)")
        #expect(!result.errors.contains { $0.contains("gateway") })
        try? FileManager.default.removeItem(at: result.root)
    }
}
