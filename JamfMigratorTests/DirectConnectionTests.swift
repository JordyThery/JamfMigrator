//
//  DirectConnectionTests.swift
//  JamfMigratorTests
//
//  Direct Jamf Pro connections for MSP tenants: canonical paths map onto the
//  instance, no X-Environment-Id is sent, platform-only namespaces refuse,
//  and user/password authentication mints a bearer token.
//

import Foundation
import Testing
@testable import JamfMigrator

private func directClient(session: URLSession) -> PlatformClient {
    PlatformClient(serverURL: URL(string: "https://msp.jamfcloud.com")!,
                   tokenProvider: TokenProvider(
                       credentials: { .init(tokenURL: URL(string: "https://msp.jamfcloud.com/api/oauth/token")!,
                                            clientId: "id", clientSecret: "secret") },
                       session: session),
                   session: session,
                   configuration: .init(writeInterval: .zero))
}

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
            guard case .invalidURL(let message) = error as? GatewayError else { return false }
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
        let provider = TokenProvider(
            credentials: { .init(tokenURL: URL(string: "https://msp.jamfcloud.com/api/v1/auth/token")!,
                                 method: .userPassword(username: "admin", password: "hunter2")) },
            session: session)

        let token = try await provider.validToken()
        #expect(token == "user-token")

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
        let client = PlatformClient(region: .us, environmentId: "env-9",
                                    tokenProvider: TokenProvider(
                                        credentials: { .init(tokenURL: Region.us.tokenURL, clientId: "i", clientSecret: "s") },
                                        session: session),
                                    session: session)
        #expect(client.supportsPlatformEndpoints)
        _ = try await client.send(.get, "pro/v1/sites")
        #expect(seen.value == "env-9")
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

        let store = await TenantStore(directory: directory, secrets: InMemorySecretStore())
        var tenant = Tenant(name: "MSP customer")
        tenant.serverURL = "https://msp.jamfcloud.com"
        tenant.clientId = "client-1"
        await store.upsert(tenant)

        let client = await store.client(for: tenant)
        #expect(!client.supportsPlatformEndpoints)
        #expect(client.baseURL.absoluteString == "https://msp.jamfcloud.com")
        #expect(client.environmentId.isEmpty)
    }
}
