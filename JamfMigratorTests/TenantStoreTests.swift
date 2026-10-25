//
//  TenantStoreTests.swift
//  JamfMigratorTests
//

import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import JamfMigrator

@MainActor
struct TenantStoreTests {

    /// tenants.json as JamfMigrator 1.x writes it (the shape of a real file,
    /// with made-up values): gateway tenants, a direct one with a username,
    /// and a direct one with an API client.
    static let existingFile = """
    [
      {
        "clientId" : "client-a",
        "environmentId" : "11111111-2222-3333-4444-555555555555",
        "id" : "AAAAAAAA-0000-0000-0000-000000000001",
        "isProtected" : true,
        "name" : "Sandbox",
        "region" : "us"
      },
      {
        "clientId" : "client-b",
        "environmentId" : "env-b",
        "id" : "AAAAAAAA-0000-0000-0000-000000000002",
        "isProtected" : false,
        "name" : "Demo",
        "region" : "eu"
      },
      {
        "clientId" : "client-c",
        "environmentId" : "env-c",
        "id" : "AAAAAAAA-0000-0000-0000-000000000003",
        "isProtected" : false,
        "name" : "Demo (direct)",
        "region" : "us",
        "serverURL" : "https:\\/\\/demo.jamfcloud.com",
        "username" : "jssadmin"
      },
      {
        "clientId" : "client-d",
        "environmentId" : "",
        "id" : "E4908A92-FC22-43B0-90CD-646796719708",
        "isProtected" : true,
        "name" : "Sandbox (direct)",
        "region" : "apac",
        "serverURL" : "https:\\/\\/jamf.example.com"
      }
    ]
    """

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TenantStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExistingFile(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("tenants.json")
        try Data(Self.existingFile.utf8).write(to: url)
        return url
    }

    @Test func tenantsSurviveAReload() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sandbox = Tenant(name: "Sandbox", region: .us, environmentId: "env-a", clientId: "client-a", isProtected: true)
        let demo = Tenant(name: "Demo", region: .eu, environmentId: "env-b", clientId: "client-b")

        let store = TenantStore(directory: directory, secrets: InMemorySecretStore())
        try store.connections.save(sandbox)
        try store.connections.save(demo)

        let reloaded = TenantStore(directory: directory, secrets: InMemorySecretStore())
        #expect(reloaded.tenants == [sandbox, demo])
        #expect(reloaded.tenant(id: sandbox.id)?.isProtected == true)
    }

    // MARK: Existing data

    @Test func anExistingFileLoadsAndSavesBackByteForByte() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writeExistingFile(in: directory)

        let store = TenantStore(directory: directory, secrets: InMemorySecretStore())
        #expect(store.connections.problem == nil)
        #expect(store.tenants.map(\.name) == ["Sandbox", "Demo", "Demo (direct)", "Sandbox (direct)"])

        // saving each tenant as the editor would, with nothing changed
        for tenant in store.tenants {
            var edited = tenant
            edited.connection = tenant.connection
            try store.connections.save(edited)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == Self.existingFile)
        // and the first save left the one-time backup
        #expect(try String(contentsOf: url.appendingPathExtension("backup"), encoding: .utf8) == Self.existingFile)
    }

    @Test func eachKindOfTenantIsTheRightConnection() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeExistingFile(in: directory)
        let connections = TenantStore(directory: directory, secrets: InMemorySecretStore()).tenants.map(\.connection)

        #expect(connections[0].service == .jamfPlatform)
        #expect(connections[0].signIn == .apiClient)
        #expect(connections[0].environmentID == "11111111-2222-3333-4444-555555555555")
        #expect(connections[1].region == .eu)
        #expect(connections[2].service == .jamfPro)
        #expect(connections[2].signIn == .usernamePassword)
        #expect(connections[2].username == "jssadmin")
        #expect(connections[2].serverURL == "https://demo.jamfcloud.com")
        #expect(connections[3].service == .jamfPro)
        #expect(connections[3].signIn == .apiClient)
        #expect(connections[3].region == .apac)
    }

    @Test func editingTheConnectionChangesOnlyConnectionFields() {
        var tenant = Tenant(name: "Demo", region: .us, environmentId: "env", clientId: "client", isProtected: true)

        // gateway → Jamf Pro server with a username
        var connection = tenant.connection
        connection.service = .jamfPro
        connection.signIn = .usernamePassword
        connection.serverURL = "https://demo.jamfcloud.com"
        connection.username = "admin"
        tenant.connection = connection
        #expect(tenant.serverURL == "https://demo.jamfcloud.com")
        #expect(tenant.username == "admin")
        #expect(tenant.isProtected)
        #expect(!tenant.usesGateway)

        // back to an API client drops the username, as the old editor did
        connection.signIn = .apiClient
        tenant.connection = connection
        #expect(tenant.username == nil)

        // back to the gateway
        connection.service = .jamfPlatform
        tenant.connection = connection
        #expect(tenant.usesGateway)
        #expect(tenant.serverURL == nil)
        #expect(tenant.environmentId == "env")
    }

    @Test func aNewJamfProTenantStaysAJamfProTenant() {
        let tenant = Tenant(connection: Connection(name: "New tenant", service: .jamfPro))
        #expect(tenant.serverURL == "https://")
        #expect(!tenant.usesGateway)
        #expect(tenant.connection.service == .jamfPro)
    }

    @Test func anUnreadableFileIsKeptAndNotOverwritten() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tenants.json")
        let damaged = #"[{"id":"AAAAAAAA-0000-0000-0000-000000000001","name":"Sandbox"}]"#
        try Data(damaged.utf8).write(to: url)

        let store = TenantStore(directory: directory, secrets: InMemorySecretStore())
        #expect(store.connections.problem != nil)
        #expect(throws: (any Error).self) { try store.connections.save(Tenant(name: "New tenant")) }
        #expect(try String(contentsOf: url, encoding: .utf8) == damaged)
    }

    // MARK: Secrets

    @Test func secretsStayUnderTheTenantIdAndDeletingRemovesThem() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let secrets = InMemorySecretStore()
        let store = TenantStore(directory: directory, secrets: secrets)

        var tenant = Tenant(name: "Sandbox")
        try store.connections.save(tenant, secrets: [.main: "hunter2"])
        #expect(secrets.all == [tenant.id.uuidString: "hunter2"])

        tenant.name = "Golden master"
        try store.connections.save(tenant)
        #expect(store.tenants.count == 1)
        #expect(store.tenants.first?.name == "Golden master")
        #expect(secrets.secret(for: tenant.id.uuidString) == "hunter2")

        try store.connections.delete(id: tenant.id)
        #expect(store.tenants.isEmpty)
        #expect(secrets.all.isEmpty)
    }

    @Test func theKeychainKeepsItsServiceAndAccessibility() {
        let keychain = TenantStore.keychain()
        #expect(keychain.service == "JamfMigrator-tenant")
        #expect(keychain.accessibility == .afterFirstUnlock)
        #expect(keychain.movesItemsFromDataProtectionKeychain)
    }

    @Test func clientWithoutASecretFailsAtTokenTime() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = TenantStore(directory: directory, secrets: InMemorySecretStore())
        let tenant = Tenant(name: "Demo", environmentId: "env-1", clientId: "client-1")
        try store.connections.save(tenant)

        let client = store.client(for: tenant)
        #expect(client.environmentId == "env-1")
        await #expect {
            _ = try await client.send(.get, "pro/v1/sites")
        } throws: { error in
            guard case .tokenFailure(_, let detail) = error as? GatewayError else { return false }
            return detail?.contains("Settings › Connections") == true
        }
    }
}
