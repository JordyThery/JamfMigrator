//
//  UnderTestTests.swift
//  JamfMigratorTests
//
//  The test-only "only these objects" limit, and the guard that keeps the
//  app away from saved tenants while it runs under tests.
//

import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import JamfMigrator

struct OnlyObjectsTests {

    /// Two source categories; only "Keep" (id 5) is in the limit.
    private func gateway() -> FakeGateway {
        FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(
                    ["totalCount": 2, "results": [["id": "5", "name": "Keep"], ["id": "6", "name": "Other"]]]))
            case ("src", "GET", "/pro/v1/categories/5"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "5", "name": "Keep", "priority": 9]))
            case ("src", "GET", "/pro/v1/categories/6"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "6", "name": "Other", "priority": 9]))
            case ("dst", "POST", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 201, data: MockHTTP.json(["id": "77"]))
            default:
                return nil
            }
        }
    }

    @Test func previewRunAndVerifyTakeOnlyTheNamedObjects() async throws {
        let gateway = gateway()
        let only = OnlyObjects(testing: ["categories": ["5"]])

        let plan = await MigrationPlanner(source: gateway.source, dest: gateway.dest)
            .plan(typeKeys: ["categories"], only: only)
        #expect(plan.entries.map(\.objectId) == ["5"])

        let report = await MigrationEngine(source: gateway.source, dest: gateway.dest, journal: makeJournal())
            .migrate(typeKeys: ["categories"], only: only)
        #expect(report.entries.map(\.objectId) == ["5"])
        #expect(gateway.writes(to: "dst").map(\.path) == ["/pro/v1/categories"])
        // the other object's detail is never read
        #expect(!gateway.requests.value.contains { $0.path == "/pro/v1/categories/6" })

        let verify = await Verifier.verify(source: gateway.source, dest: gateway.dest,
                                           typeKeys: ["categories"], only: only)
        #expect(verify.types.first?.discrepancies == ["Keep: missing on the destination"])
    }

    @Test func anEmptyLimitTakesNothing() async throws {
        let gateway = gateway()
        let report = await MigrationEngine(source: gateway.source, dest: gateway.dest, journal: makeJournal())
            .migrate(typeKeys: ["categories"], only: OnlyObjects(testing: [:]))
        #expect(report.entries.isEmpty)
        #expect(gateway.writes(to: "dst").isEmpty)
    }

    @Test func withoutALimitEverythingTakesPart() async throws {
        let gateway = gateway()
        let plan = await MigrationPlanner(source: gateway.source, dest: gateway.dest).plan(typeKeys: ["categories"])
        #expect(Set(plan.entries.map(\.objectId)) == ["5", "6"])
    }
}

@MainActor
struct SavedTenantGuardTests {

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UnderTestTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theUnitTestHostRunsUnderTests() {
        #expect(TestRun.isActive)
    }

    /// The app's own state in the test host: sandbox, so the saved tenants
    /// aren't loaded and no update check runs.
    @Test func theTestHostsAppStateHoldsNoSavedTenants() {
        let state = AppState.forLaunch()
        #expect(state.demo.isSandbox)
        #expect(!state.demo.isOn)
        #expect(state.tenantStore.tenants.isEmpty)
    }

    /// A store of saved tenants refuses and records the sign-in and the
    /// request; nothing reaches the network (the session would answer).
    @Test func aSavedTenantIsRefusedAndRecorded() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorded = SavedTenantGuard(fileURL: folder.appendingPathComponent("attempts.jsonl"))
        let reached = Locked(0)
        let session = MockHTTP.session { _ in
            reached.withLock { $0 += 1 }
            return MockHTTP.tokenJSON()
        }
        let secrets = InMemorySecretStore()
        let store = TenantStore(directory: folder, secrets: secrets, log: nil, session: session,
                                savedTenantGuard: recorded)
        let tenant = Tenant(name: "Saved", region: .eu, environmentId: TestEnvironment.source, clientId: "client")
        _ = secrets.setSecret("secret", for: tenant.id.uuidString)

        await #expect(throws: (any Error).self) {
            _ = try await store.client(for: tenant).send(.get, "pro/v1/categories")
        }
        await #expect(throws: (any Error).self) {
            _ = try await store.testClient(for: tenant, secretOverride: "typed").send(.get, "pro/v1/categories")
        }
        #expect(reached.value == 0)
        let attempts = recorded.attempts()
        #expect(attempts.count >= 2)
        #expect(attempts.allSatisfy { $0.what.hasPrefix("tenant …" + tenant.id.uuidString.suffix(4) + ": ") })
    }

    /// The tests' own stores (temporary folder, in-memory secrets) are not
    /// guarded: the live checks and the networking tests reach their fakes.
    @Test func aTestStoreIsNotGuarded() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = MockHTTP.session { request in
            request.url?.path == "/auth/token"
                ? MockHTTP.tokenJSON()
                : MockHTTP.Reply(status: 200, data: Data(#"{"totalCount":0,"results":[]}"#.utf8))
        }
        let secrets = InMemorySecretStore()
        let store = TenantStore(directory: folder, secrets: secrets, log: nil, session: session)
        let tenant = Tenant(name: "Test", region: .eu, environmentId: TestEnvironment.source, clientId: "client")
        _ = secrets.setSecret("secret", for: tenant.id.uuidString)
        _ = try await store.client(for: tenant).send(.get, "pro/v1/categories")
    }

    /// What counts as the saved tenants: the real folder, or the real
    /// Keychain items; a temporary folder with in-memory secrets doesn't.
    @Test func whatCountsAsSavedTenants() throws {
        let real = URL(fileURLWithPath: AppInfo.appSupportPath, isDirectory: true)
        let temporary = try folder()
        defer { try? FileManager.default.removeItem(at: temporary) }
        #expect(TenantStore.holdsSavedTenants(directory: real, storage: nil, secrets: InMemorySecretStore()))
        #expect(TenantStore.holdsSavedTenants(directory: temporary, storage: nil, secrets: TenantStore.keychain()))
        #expect(!TenantStore.holdsSavedTenants(directory: temporary, storage: nil, secrets: InMemorySecretStore()))
        #expect(!TenantStore.holdsSavedTenants(directory: real, storage: InMemoryConnectionStorage<Tenant>(),
                                               secrets: InMemorySecretStore()))
    }
}
