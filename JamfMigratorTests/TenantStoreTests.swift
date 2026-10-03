//
//  TenantStoreTests.swift
//  JamfMigratorTests
//

import Foundation
import Testing
@testable import JamfMigrator

@MainActor
struct TenantStoreTests {

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TenantStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func tenantsSurviveAReload() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sandbox = Tenant(name: "Sandbox", region: .us, environmentId: "env-a", clientId: "client-a", isProtected: true)
        let demo = Tenant(name: "Demo", region: .eu, environmentId: "env-b", clientId: "client-b")

        let store = TenantStore(directory: directory, secrets: InMemorySecretStore())
        store.upsert(sandbox)
        store.upsert(demo)

        let reloaded = TenantStore(directory: directory, secrets: InMemorySecretStore())
        #expect(reloaded.tenants == [sandbox, demo])
        #expect(reloaded.tenant(id: sandbox.id)?.isProtected == true)
    }

    @Test func upsertReplacesByIdAndRemoveDeletesTheSecret() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let secrets = InMemorySecretStore()
        let store = TenantStore(directory: directory, secrets: secrets)

        var tenant = Tenant(name: "Sandbox")
        store.upsert(tenant)
        store.setSecret("hunter2", for: tenant)
        #expect(store.secret(for: tenant) == "hunter2")

        tenant.name = "Golden master"
        store.upsert(tenant)
        #expect(store.tenants.count == 1)
        #expect(store.tenants.first?.name == "Golden master")

        store.remove(tenant)
        #expect(store.tenants.isEmpty)
        #expect(secrets.secret(for: tenant.id.uuidString) == nil)
    }

    @Test func clientWithoutASecretFailsAtTokenTime() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = TenantStore(directory: directory, secrets: InMemorySecretStore())
        let tenant = Tenant(name: "Demo", environmentId: "env-1", clientId: "client-1")
        store.upsert(tenant)

        let client = store.client(for: tenant)
        #expect(client.environmentId == "env-1")
        await #expect {
            _ = try await client.send(.get, "pro/v1/sites")
        } throws: { error in
            guard case .tokenFailure(_, let detail) = error as? GatewayError else { return false }
            return detail?.contains("no client secret") == true
        }
    }
}
