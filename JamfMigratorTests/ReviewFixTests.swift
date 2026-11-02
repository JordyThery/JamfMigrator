//
//  ReviewFixTests.swift
//  JamfMigratorTests
//
//  The 1.2.0 review's findings: Stop and the waits before a retry (1–4),
//  Settings › Secrets saving only a change (5), icon redirects (6), Run and
//  Verify saying why they didn't start (7), a stale mapping load (8), and
//  tests that leave no preferences behind (10). Finding 9 is in
//  RegressionTests (changedMappingsTurnRunOff).
//

import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import JamfMigrator

/// A server for both tenants on one mocked session, told apart by the
/// X-Environment-Id header ("src", "dst"); a GET it doesn't answer is an
/// empty list. Every request is noted.
private final class TwoTenantServer: @unchecked Sendable {
    let requests = Locked<[(env: String, method: String, path: String, body: Data?)]>([])
    let session: URLSession

    init(_ handler: @escaping @Sendable (_ env: String, _ method: String, _ path: String, _ body: Data?) -> MockHTTP.Reply?) {
        let requests = requests
        session = MockHTTP.session { request in
            let path = request.url?.path ?? ""
            if path == "/auth/token" { return MockHTTP.tokenJSON() }
            let env = switch request.value(forHTTPHeaderField: "X-Environment-Id") {
            case TestEnvironment.source?: "src"
            case TestEnvironment.destination?: "dst"
            default: ""
            }
            let method = request.httpMethod ?? ""
            requests.withLock { $0.append((env, method, path, request.bodyData)) }
            if let reply = handler(env, method, path, request.bodyData) { return reply }
            if method == "GET" {
                return MockHTTP.Reply(status: 200, data: FakeGateway.emptyList(at: path)
                                      ?? (path.hasPrefix("/proclassic/") ? Data("{}".utf8) : Data(#"{"totalCount":0,"results":[]}"#.utf8)))
            }
            return MockHTTP.Reply(status: 404)
        }
    }

    /// A client that really waits before a retry, shown in `waits`.
    func waitingClient(_ environment: String, waits: RequestWaits) -> JamfPlatform.Client {
        let recorder = RequestRecorder(session: session, log: nil, service: "Jamf Platform API", waits: waits)
        let tokens = JamfPlatform.TokenProvider(tokenURL: JamfRegion.us.gatewayURL.appending(path: "auth/token"),
                                                method: .apiClient(clientID: "id"), secret: { "secret" }, recorder: recorder)
        // the Environment IDs tests use are UUIDs, so this can't throw
        return try! JamfPlatform.Client(baseURL: JamfRegion.us.gatewayURL, scope: .environment(environment),
                                        tokens: tokens, recorder: recorder)
    }

    func writes(_ env: String) -> [(method: String, path: String, body: Data?)] {
        requests.value.filter { $0.env == env && $0.method != "GET" }.map { ($0.method, $0.path, $0.body) }
    }
}

/// "Jamf asked to wait 50 s": a 429 with Retry-After.
private let rateLimited = MockHTTP.Reply(status: 429, headers: ["Retry-After": "50"])

/// A Keychain that can be locked during a test.
private final class LockableKeychain: SecretStore, @unchecked Sendable {
    let isLocked = Locked(false)
    let values = Locked<[String: String]>([:])
    let writes = Locked(0)
    func secret(for account: String) -> String? { values.value[account] }
    func readSecret(for account: String) throws -> String? {
        if isLocked.value { throw SecretStoreError(status: errSecInteractionNotAllowed) }
        return values.value[account]
    }
    func setSecret(_ secret: String?, for account: String) -> Bool {
        writes.withLock { $0 += 1 }
        values.withLock { $0[account] = secret }
        return true
    }
}

@MainActor
final class ReviewFixTests {

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

    /// An app whose two tenants (Platform API, source and destination) are
    /// answered by `server`, with the app's own tenant store: its clients
    /// really wait before a retry, in `tenantStore.waits`.
    private func app(_ server: TwoTenantServer, serviceSecrets: any SecretStore = InMemorySecretStore()) throws -> AppState {
        let name = "jamfmigrator-review-\(UUID().uuidString)"
        suites.withLock { $0.append(name) }
        let defaults = UserDefaults(suiteName: name)!
        let mode = DemoMode(key: "demoMode", defaults: defaults, arguments: ["app", "-JTKitSandbox", "YES"])
        let secrets = InMemorySecretStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Review-\(UUID().uuidString)")
        let store = TenantStore(directory: directory, secrets: secrets, log: nil, session: server.session, demo: mode,
                                storage: InMemoryConnectionStorage<Tenant>(), savedTenantGuard: nil)
        let source = Tenant(connection: Connection(name: "A", service: .jamfPlatform, region: .us,
                                                   environmentID: TestEnvironment.source, clientID: "a"))
        let dest = Tenant(connection: Connection(name: "B", service: .jamfPlatform, region: .us,
                                                 environmentID: TestEnvironment.destination, clientID: "b"))
        try store.connections.save(source, secrets: [.main: "secret-a"])
        try store.connections.save(dest, secrets: [.main: "secret-b"])
        let app = AppState(tenantStore: store, secretStore: serviceSecrets, demo: mode, defaults: defaults)
        app.sourceTenantID = source.id
        app.destTenantID = dest.id
        return app
    }

    // MARK: Finding 1 (and 10: a real wait)

    @Test("Stop ends the app's real wait, stays clickable, and ends a wait that begins after it")
    func stopEndsWaitsThatBeginLater() async throws {
        let server = TwoTenantServer { env, method, path, _ in
            env == "dst" && method == "GET" && path == "/pro/v1/categories" ? rateLimited : nil
        }
        let app = try app(server)
        let client = app.tenantStore.client(for: try #require(app.destTenant))
        app.isRunning = true
        defer { app.isRunning = false }

        let firstDone = Locked(false)
        let first = Task { _ = try? await client.send(.get, "pro/v1/categories"); firstDone.withLock { $0 = true } }
        try await waitUntil({ !app.tenantStore.waits.current.isEmpty }, timeout: .seconds(10), "The first request didn't wait")
        #expect(app.tenantStore.waits.statusText == "Jamf asked to wait 50 s")

        app.cancel()
        #expect(app.isStopping)
        #expect(app.canStop, "Stop is off while the run stops")
        try await waitUntil({ firstDone.value }, timeout: .seconds(5), "Stop didn't end the wait")

        // the object being written retries after Stop: its wait ends at once
        let secondDone = Locked(false)
        let second = Task { _ = try? await client.send(.get, "pro/v1/categories"); secondDone.withLock { $0 = true } }
        try await waitUntil({ secondDone.value }, timeout: .seconds(5), "A wait that began after Stop wasn't ended")
        #expect(app.tenantStore.waits.current.isEmpty)
        first.cancel()
        second.cancel()
    }

    // MARK: Finding 2

    @Test("Stop tells the engine before it ends the waits: the next object isn't written")
    func stopTellsTheEngineFirst() async throws {
        let server = TwoTenantServer { env, method, path, body in
            switch (env, method, path) {
            case ("src", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 2, "results": [
                    ["id": "5", "name": "Alpha"], ["id": "6", "name": "Beta"]]]))
            case ("src", "GET", "/pro/v1/categories/5"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "5", "name": "Alpha", "priority": 9]))
            case ("src", "GET", "/pro/v1/categories/6"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "6", "name": "Beta", "priority": 9]))
            case ("dst", "POST", "/pro/v1/categories"):
                let name = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["name"] as? String
                return name == "Alpha" ? rateLimited : MockHTTP.Reply(status: 201, data: MockHTTP.json(["id": "77"]))
            default:
                return nil
            }
        }
        let app = try app(server)
        app.selectedTypeKeys = ["categories"]
        app.preview()
        try await waitUntil { !app.isPlanning }
        #expect(app.canRun)
        #expect(app.run())
        try await waitUntil({ !app.tenantStore.waits.current.isEmpty }, timeout: .seconds(10), "Alpha's write didn't wait")
        app.cancel()
        try await waitUntil({ !app.isRunning }, timeout: .seconds(10), "The run didn't stop")

        let posts = server.writes("dst").compactMap { $0.body }
            .compactMap { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["name"] as? String }
        #expect(posts == ["Alpha"], "Stop wrote another object after the current one: \(posts)")
        let entries = app.report?.entries ?? []
        #expect(entries.map(\.objectName) == ["Alpha"])
        #expect(entries.first?.status == .failed(reason: MigrationEngine.stoppedDuringWait))
    }

    @Test("Stop's order: the waits end only once every engine knows it stopped")
    func stopOrder() async {
        let steps = Locked<[String]>([])
        await AppState.stop(cancelEngines: {
            // an engine busy for a moment before it takes the Stop
            try? await Task.sleep(for: .milliseconds(100))
            steps.withLock { $0.append("engines") }
        }, endWaits: {
            steps.withLock { $0.append("waits") }
        })
        #expect(steps.value == ["engines", "waits"])
    }

    // MARK: Finding 3

    @Test("Delete mode: Stop during a wait says so, not a raw CancellationError")
    func deleteStoppedDuringAWait() async throws {
        let server = TwoTenantServer { env, method, path, _ in
            switch (env, method, path) {
            case ("dst", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 1, "results": [["id": "5", "name": "Tools"]]]))
            case ("dst", "DELETE", "/pro/v1/categories/5"):
                return rateLimited
            default:
                return nil
            }
        }
        let waits = RequestWaits()
        let client = server.waitingClient(TestEnvironment.destination, waits: waits)
        let plan = await MigrationPlanner(source: client, dest: client).planDeletion(typeKeys: ["categories"])
        let engine = DeleteEngine(client: client, journal: makeJournal(mode: .delete))
        let run = Task { await engine.run(plan, including: plan.runnableIds) }
        try await waitUntil({ !waits.current.isEmpty }, timeout: .seconds(10), "The delete didn't wait")
        await engine.cancel()
        waits.cancelAll()
        let report = await run.value
        #expect(report.entries.map(\.objectName) == ["Tools"])
        #expect(report.entries.first?.status == .failed(reason: DeleteEngine.stoppedDuringWait))
    }

    // MARK: Finding 4

    @Test("A benchmark Replace stopped during the recreate's wait still says it was deleted")
    func benchmarkReplaceStoppedDuringTheRecreate() async throws {
        let server = TwoTenantServer { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/compliance-benchmarks/v1/benchmarks"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["benchmarks": [["id": "C1", "title": "CIS Level 1"]]]))
            case ("src", "GET", "/compliance-benchmarks/v1/benchmarks/C1"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(
                    ["id": "C1", "title": "CIS Level 1", "baselineId": "cis-l1", "rules": [["id": "r1", "enabled": true]]]))
            case ("dst", "GET", "/compliance-benchmarks/v1/benchmarks"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["benchmarks": [["id": "C9", "title": "CIS Level 1"]]]))
            case ("dst", "DELETE", "/compliance-benchmarks/v1/benchmarks/C9"):
                return MockHTTP.Reply(status: 204)
            case ("dst", "POST", "/compliance-benchmarks/v1/benchmarks"):
                return rateLimited
            default:
                return nil
            }
        }
        let waits = RequestWaits()
        let source = JamfPlatform.Client.fake(environmentId: TestEnvironment.source, session: server.session)
        let dest = server.waitingClient(TestEnvironment.destination, waits: waits)
        let engine = MigrationEngine(source: source, dest: dest, journal: makeJournal())
        let run = Task { await engine.migrate(typeKeys: ["compliancebenchmarks"]) }
        try await waitUntil({ !waits.current.isEmpty }, timeout: .seconds(10), "The recreate didn't wait")
        await engine.cancel()
        waits.cancelAll()
        let report = await run.value
        guard case .failed(let reason)? = report.entries.first?.status else {
            Issue.record("expected .failed, got \(String(describing: report.entries.first?.status))")
            return
        }
        #expect(reason.hasPrefix("Deleted on the destination"), "\(reason)")
    }

    // MARK: Finding 5

    @Test("Settings › Secrets saves only a changed value: opening the tab writes nothing")
    func secretsSaveOnlyAChange() throws {
        let keychain = LockableKeychain()
        keychain.values.withLock { $0["service-ldap"] = "hunter2" }
        let app = try app(TwoTenantServer { _, _, _, _ in nil }, serviceSecrets: keychain)
        var stored: String? = try app.serviceSecret("ldap")
        #expect(app.saveServiceSecretIfChanged("hunter2", for: "ldap", stored: &stored) == nil)
        #expect(keychain.writes.value == 0, "Showing the stored value saved it")
        #expect(app.saveServiceSecretIfChanged("hunter3", for: "ldap", stored: &stored) == true)
        #expect(keychain.writes.value == 1 && stored == "hunter3")
        // a value that couldn't be read is saved once something is typed
        var unread: String? = nil
        #expect(app.saveServiceSecretIfChanged("", for: "bind", stored: &unread) == nil)
        #expect(app.saveServiceSecretIfChanged("s3cret", for: "bind", stored: &unread) == true)
    }

    // MARK: Finding 6

    @Test("An icon whose address redirects over https, also to another host, is downloaded; http is refused")
    func iconRedirects() async throws {
        let session = MockHTTP.session { request in
            switch request.url?.absoluteString {
            case "https://icons.example.test/icon/hash_1":
                return MockHTTP.Reply(status: 302, headers: ["Location": "https://cdn.example.test/icon/1.png"])
            case "https://cdn.example.test/icon/1.png":
                return MockHTTP.Reply(status: 200, data: Data("PNG".utf8))
            case "https://icons.example.test/icon/hash_2":
                return MockHTTP.Reply(status: 302, headers: ["Location": "http://cdn.example.test/icon/2.png"])
            case "https://icons.example.test/icon/loop":
                return MockHTTP.Reply(status: 302, headers: ["Location": "https://icons.example.test/icon/loop"])
            default:
                return MockHTTP.Reply(status: 404)
            }
        }
        let recorder = RequestRecorder(session: session, log: nil)
        let data = try await IconMigrator.download(URL(string: "https://icons.example.test/icon/hash_1")!, recorder: recorder)
        #expect(String(decoding: data, as: UTF8.self) == "PNG")
        await #expect(throws: (any Error).self) {
            _ = try await IconMigrator.download(URL(string: "https://icons.example.test/icon/hash_2")!, recorder: recorder)
        }
        await #expect(throws: (any Error).self) {
            _ = try await IconMigrator.download(URL(string: "https://icons.example.test/icon/loop")!, recorder: recorder)
        }
    }

    // MARK: Finding 7

    @Test("Run and Verify say they didn't start when Settings › Secrets can't be read")
    func runAndVerifyReportAKeychainError() async throws {
        let server = TwoTenantServer { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 1, "results": [["id": "5", "name": "Tools"]]]))
            case ("src", "GET", "/pro/v1/categories/5"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "5", "name": "Tools", "priority": 9]))
            default:
                return nil
            }
        }
        let keychain = LockableKeychain()
        let app = try app(server, serviceSecrets: keychain)
        app.selectedTypeKeys = ["categories"]
        app.preview()
        try await waitUntil { !app.isPlanning }
        #expect(app.canRun)
        keychain.isLocked.withLock { $0 = true }
        #expect(app.run() == false, "Run says it started")
        #expect(!app.isRunning)
        #expect(app.lastError?.contains("Keychain couldn’t be read") == true, "\(app.lastError ?? "")")
        app.lastError = nil
        #expect(app.verify() == false, "Verify says it started")
        #expect(!app.isVerifying && app.lastError != nil)
        #expect(server.writes("dst").isEmpty)
    }

    // MARK: Finding 8

    @Test("A mapping load for tenants changed since is dropped, not applied to the new pair")
    func staleMappingLoadIsDropped() async throws {
        let name = "jamfmigrator-review-\(UUID().uuidString)"
        suites.withLock { $0.append(name) }
        let defaults = UserDefaults(suiteName: name)!
        let mode = DemoMode(key: "demoMode", defaults: defaults, arguments: ["app", "-JTKitSandbox", "YES", "-JTKitDemo", "YES"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Review-\(UUID().uuidString)")
        let store = TenantStore(directory: directory, secrets: InMemorySecretStore(), log: nil, demo: mode,
                                storage: InMemoryConnectionStorage<Tenant>())
        let app = AppState(tenantStore: store, secretStore: InMemorySecretStore(), demo: mode, defaults: defaults)
        #expect(app.demo.isOn)

        app.loadMappingCandidates()
        // the Connection menu, while Prepare loads: another source
        app.sourceDemo.selectedID = Connection.demoJamfProDestination.id
        try await waitUntil { !app.isLoadingMappings }
        #expect(app.mappings.adeInstances.isEmpty, "The old pair's proposal became the new pair's: \(app.mappings.adeInstances)")

        // a load for the pair as it is now still applies
        app.sourceDemo.selectedID = Connection.demoJamfProSource.id
        app.loadMappingCandidates()
        try await waitUntil { !app.isLoadingMappings }
        #expect(app.mappings.adeInstances == ["1": "4"])
    }

    // MARK: Finding 10

    @Test("A test's preference suite is removed when the test ends")
    func preferenceSuitesAreRemoved() {
        let name = "jamfmigrator-review-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(true, forKey: "check")
        #expect(UserDefaults.standard.persistentDomain(forName: name)?["check"] as? Bool == true)
        RegressionTests.removeDefaults(named: name)
        #expect((UserDefaults.standard.persistentDomain(forName: name) ?? [:]).isEmpty)
        #expect(UserDefaults(suiteName: name)?.object(forKey: "check") == nil)
    }
}

/// Jamf Pro 11.34.x drops a macOS profile's Self Service notification
/// settings on save (decided by Jordy on 2026-11-02): Preview and the run
/// report say so once, on that profile only, for an 11.34.x destination only.
struct SelfServiceNotificationWarningTests {

    private static let profile = """
        <os_x_configuration_profile><general><id>3</id><name>Wi-Fi</name><uuid>SRC-UUID</uuid></general>\
        <self_service><notification>false</notification><notification>Self Service</notification>\
        <notification_subject>Wi-Fi</notification_subject><notification_message/></self_service>\
        <payloads>PayloadUUID SRC-UUID</payloads></os_x_configuration_profile>
        """

    private static let plainProfile = """
        <os_x_configuration_profile><general><id>3</id><name>Wi-Fi</name><uuid>SRC-UUID</uuid></general>\
        <self_service><self_service_display_name>Wi-Fi</self_service_display_name></self_service>\
        <payloads>PayloadUUID SRC-UUID</payloads></os_x_configuration_profile>
        """

    private func gateway(_ xml: String) -> FakeGateway {
        FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/proclassic/osxconfigurationprofiles"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["os_x_configuration_profiles": [["id": 3, "name": "Wi-Fi"]]]))
            case ("src", "GET", "/proclassic/osxconfigurationprofiles/id/3"):
                return MockHTTP.Reply(status: 200, data: Data(xml.utf8))
            case ("dst", "POST", "/proclassic/osxconfigurationprofiles/id/0"):
                return MockHTTP.Reply(status: 201, data: Data("<os_x_configuration_profile><id>13</id></os_x_configuration_profile>".utf8))
            default:
                return nil
            }
        }
    }

    private let warning = ClassicTransformer.selfServiceNotificationsWarning

    @Test("An 11.34.x destination: one warning on the profile's row and in the run report")
    func warnsForJamfPro1134() async throws {
        for version in ["11.34.0-t1793383479089", "11.34.0-b.1.t1791987365570", "11.34.2"] {
            let gateway = gateway(Self.profile)
            let plan = await MigrationPlanner(source: gateway.source, dest: gateway.dest, destinationVersion: version)
                .plan(typeKeys: ["osxconfigurationprofiles"])
            let entry = try #require(plan.entries.first { $0.typeKey == "osxconfigurationprofiles" })
            #expect(entry.warnings.filter { $0 == warning }.count == 1, "\(version): \(entry.warnings)")

            let report = await MigrationEngine(source: gateway.source, dest: gateway.dest, journal: makeJournal(),
                                               destinationVersion: version)
                .run(plan, including: plan.runnableIds)
            #expect(report.entries.first?.status == .created(destId: "13"))
            #expect(report.entries.first?.warnings.filter { $0 == warning }.count == 1, "\(version): \(report.entries.first?.warnings ?? [])")
        }
    }

    @Test("No warning for another version, an unknown one, or a profile without notification settings")
    func noWarningOtherwise() async throws {
        for (xml, version) in [(Self.profile, "11.33.3-t1793127642444"), (Self.profile, "11.35.0"), (Self.profile, nil),
                               (Self.plainProfile, "11.34.0-t1793383479089")] as [(String, String?)] {
            let gateway = gateway(xml)
            let plan = await MigrationPlanner(source: gateway.source, dest: gateway.dest, destinationVersion: version)
                .plan(typeKeys: ["osxconfigurationprofiles"])
            let entry = try #require(plan.entries.first { $0.typeKey == "osxconfigurationprofiles" })
            #expect(!entry.warnings.contains(warning), "\(String(describing: version)): \(entry.warnings)")
        }
    }
}
