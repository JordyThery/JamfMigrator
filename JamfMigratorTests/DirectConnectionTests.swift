//
//  DirectConnectionTests.swift
//  JamfMigratorTests
//
//  Direct Jamf Pro connections for MSP tenants: canonical paths map onto the
//  instance, no X-Environment-Id is sent, platform-only namespaces refuse,
//  and user/password authentication mints a bearer token.
//

import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import JamfMigrator

private func directClient(session: URLSession) -> JamfPlatform.Client {
    JamfPlatform.Client.fakeDirect(session: session)
}

@MainActor
struct DirectConnectionTests {

    @Test func proAndClassicPathsMapOntoTheInstance() async throws {
        let requests = Locked<[URLRequest]>([])
        let session = MockHTTP.session { request in
            if request.url?.path == "/api/oauth/token" { return MockHTTP.tokenJSON() }
            requests.withLock { $0.append(request) }
            if request.url?.path.hasPrefix("/JSSResource") == true {
                return MockHTTP.Reply(status: 200, data: Data("<sites/>".utf8))
            }
            return MockHTTP.Reply(status: 200, data: Data("{}".utf8))
        }
        let client = directClient(session: session)

        _ = try await client.send(.get, "pro/v1/jamf-pro-version")
        _ = try await client.send(.get, "proclassic/sites", accept: "application/xml")

        let urls = requests.value.map { $0.url!.absoluteString }
        #expect(urls == ["https://msp.jamfcloud.com/api/v1/jamf-pro-version",
                         "https://msp.jamfcloud.com/JSSResource/sites"])
        #expect(requests.value.allSatisfy { $0.value(forHTTPHeaderField: "X-Environment-Id") == nil })
        #expect(requests.value.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
    }

    @Test func platformOnlyNamespacesRefuse() async throws {
        let session = MockHTTP.session { _ in MockHTTP.tokenJSON() }
        let client = directClient(session: session)
        #expect(!client.supportsPlatformEndpoints)

        await #expect {
            _ = try await client.send(.get, "blueprints/v1/blueprints")
        } throws: { error in
            guard let error = error as? JamfPlatform.APIError, case .invalidResponse(let message) = error.kind else { return false }
            return message.contains("Platform API gateway")
        }
    }

    @Test func userPasswordAuthMintsABearerToken() async throws {
        let tokenRequests = Locked<[URLRequest]>([])
        let session = MockHTTP.session { request in
            if request.url?.path == "/api/v1/auth/token" {
                tokenRequests.withLock { $0.append(request) }
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(
                    ["token": "user-token", "expires": "2026-10-04T12:00:00.000Z"]))
            }
            return MockHTTP.Reply(status: 200, data: Data("{}".utf8))
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectUser-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = InMemorySecretStore()
        let store = TenantStore(directory: directory, secrets: secrets, log: nil, session: session)
        var tenant = Tenant(name: "MSP customer")
        tenant.serverURL = "https://msp.jamfcloud.com"
        tenant.username = "admin"
        try store.connections.save(tenant)
        _ = secrets.setSecret("hunter2", for: tenant.id.uuidString)

        _ = try await store.client(for: tenant).send(.get, "pro/v1/sites")

        let request = try #require(tokenRequests.value.first)
        #expect(request.httpMethod == "POST")
        let expectedBasic = "Basic " + Data("admin:hunter2".utf8).base64EncodedString()
        #expect(request.value(forHTTPHeaderField: "Authorization") == expectedBasic)
        #expect(request.bodyData == nil || request.bodyData?.isEmpty == true)
    }

    @Test func gatewayClientsStillSendTheEnvironmentHeader() async throws {
        let seen = Locked<String?>(nil)
        let session = MockHTTP.session { request in
            if request.url?.path == "/auth/token" { return MockHTTP.tokenJSON() }
            seen.value = request.value(forHTTPHeaderField: "X-Environment-Id")
            return MockHTTP.Reply(status: 200, data: Data("{}".utf8))
        }
        let client = JamfPlatform.Client.fake(session: session)
        #expect(client.supportsPlatformEndpoints)
        _ = try await client.send(.get, "pro/v1/sites")
        #expect(seen.value == TestEnvironment.id)
    }

    /// tenants.json written before serverURL/username existed still decodes.
    @Test func oldTenantJSONStillDecodes() throws {
        let json = """
        [{"id":"AAAAAAAA-0000-0000-0000-000000000001","name":"Sandbox","region":"us",
          "environmentId":"env-a","clientId":"client-a","isProtected":true}]
        """
        let tenants = try JSONDecoder().decode([Tenant].self, from: Data(json.utf8))
        #expect(tenants.first?.usesGateway == true)
        #expect(tenants.first?.serverURL == nil)
        #expect(tenants.first?.username == nil)
    }

    @Test func directTenantBuildsADirectClient() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectTenant-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = TenantStore(directory: directory, secrets: InMemorySecretStore(), log: nil)
        var tenant = Tenant(name: "MSP customer")
        tenant.serverURL = "https://msp.jamfcloud.com"
        tenant.clientId = "client-1"
        try store.connections.save(tenant)

        let client = store.client(for: tenant)
        #expect(!client.supportsPlatformEndpoints)
        #expect(client.baseURL.absoluteString == "https://msp.jamfcloud.com")
        #expect(client.scope == .organization)
        #expect(client.server == .jamfPro)
    }

    /// A refused request on a direct tenant points to Jamf Pro's API roles,
    /// not to Jamf Account.
    @Test func aMissingPrivilegePointsToJamfPro() async throws {
        let session = MockHTTP.session { request in
            request.url?.path == "/api/oauth/token"
                ? MockHTTP.tokenJSON()
                : MockHTTP.Reply(status: 403, data: MockHTTP.json(["httpStatus": 403, "errors": [["code": "INVALID_PRIVILEGE"]]]))
        }
        let client = directClient(session: session)

        await #expect {
            _ = try await client.send(.get, "pro/v1/sites")
        } throws: { error in
            let message = error.localizedDescription
            return message.contains("Settings › API Roles and Clients") && !message.contains("Jamf Account")
        }
    }
}
