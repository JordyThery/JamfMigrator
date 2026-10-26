//
//  SignInTests.swift
//  JamfMigratorTests
//
//  Signing in through JTKit as JamfMigrator uses it: one client per tenant,
//  rebuilt after an edit, every request in the activity log under the
//  tenant's name, and failed sign-in messages redacted.
//

import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import JamfMigrator

@MainActor
struct SignInTests {

    /// A tenant store on a fake gateway that counts sign-ins per client ID.
    @MainActor
    private struct Harness {
        let store: TenantStore
        let secrets: InMemorySecretStore
        let log: ActivityLog
        let signIns: Locked<[String]>
        let directory: URL

        init(tokenReply: MockHTTP.Reply? = nil) {
            let signIns = Locked<[String]>([])
            let session = MockHTTP.session { request in
                if request.url?.path == "/auth/token" {
                    let form = String(decoding: request.bodyData ?? Data(), as: UTF8.self)
                    let clientID = form.split(separator: "&")
                        .first { $0.hasPrefix("client_id=") }?.dropFirst("client_id=".count) ?? ""
                    signIns.withLock { $0.append(String(clientID)) }
                    return tokenReply ?? MockHTTP.tokenJSON()
                }
                return MockHTTP.Reply(status: 200, data: Data("{}".utf8))
            }
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("SignIn-\(UUID().uuidString)", isDirectory: true)
            secrets = InMemorySecretStore()
            log = ActivityLog()
            store = TenantStore(directory: directory, secrets: secrets, log: log, session: session)
            self.signIns = signIns
        }

        /// Each test client's Environment ID.
        static let environments = ["prod": "a0000000-0000-4000-8000-00000000000a",
                                   "test": "b0000000-0000-4000-8000-00000000000b"]

        func add(_ name: String, clientId: String, secret: String = "s3cr3t-value") throws -> Tenant {
            let tenant = Tenant(name: name, environmentId: Harness.environments[clientId] ?? TestEnvironment.id, clientId: clientId)
            try store.connections.save(tenant)
            _ = secrets.setSecret(secret, for: tenant.id.uuidString)
            return tenant
        }
    }

    @Test func aTenantKeepsItsClientAndToken() async throws {
        let harness = Harness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let tenant = try harness.add("Prod", clientId: "prod")

        _ = try await harness.store.client(for: tenant).send(.get, "pro/v1/sites")
        _ = try await harness.store.client(for: tenant).send(.get, "pro/v1/buildings")

        #expect(harness.signIns.value == ["prod"])
    }

    @Test func sourceAndDestinationSignInSeparately() async throws {
        let harness = Harness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let source = try harness.add("Prod", clientId: "prod")
        let destination = try harness.add("Test", clientId: "test")

        let sourceClient = harness.store.client(for: source)
        let destinationClient = harness.store.client(for: destination)
        _ = try await sourceClient.send(.get, "pro/v1/sites")
        _ = try await destinationClient.send(.get, "pro/v1/sites")
        _ = try await sourceClient.send(.get, "pro/v1/sites")

        #expect(harness.signIns.value == ["prod", "test"])
        #expect(sourceClient.scope == .environment(Harness.environments["prod"]!))
        #expect(destinationClient.scope == .environment(Harness.environments["test"]!))
    }

    @Test func anEditedTenantGetsANewClient() async throws {
        let harness = Harness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        var tenant = try harness.add("Prod", clientId: "prod")
        _ = try await harness.store.client(for: tenant).send(.get, "pro/v1/sites")

        tenant.clientId = "prod-2"
        try harness.store.connections.save(tenant)
        _ = try await harness.store.client(for: tenant).send(.get, "pro/v1/sites")

        #expect(harness.signIns.value == ["prod", "prod-2"])
    }

    @Test func aDeletedTenantDropsItsClient() async throws {
        let harness = Harness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let tenant = try harness.add("Prod", clientId: "prod")
        _ = try await harness.store.client(for: tenant).send(.get, "pro/v1/sites")

        harness.store.forgetClient(for: tenant.id)
        _ = try await harness.store.client(for: tenant).send(.get, "pro/v1/sites")

        #expect(harness.signIns.value == ["prod", "prod"])
    }

    @Test func testConnectionUsesAOneOffClient() async throws {
        let harness = Harness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let tenant = try harness.add("Prod", clientId: "prod")
        let kept = harness.store.client(for: tenant)
        _ = try await kept.send(.get, "pro/v1/sites")

        _ = try await harness.store.testClient(for: tenant, secretOverride: "typed").send(.get, "pro/v1/sites")
        _ = try await kept.send(.get, "pro/v1/sites")

        // the test signed in on its own; the kept client still has its token
        #expect(harness.signIns.value == ["prod", "prod"])
    }

    @Test func requestsAreLoggedUnderTheTenantWithoutSecrets() async throws {
        let harness = Harness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let tenant = try harness.add("Prod", clientId: "prod")
        _ = try await harness.store.client(for: tenant).send(.get, "pro/v1/sites")

        let entries = harness.log.entries
        #expect(entries.map(\.category) == ["Sign-in", "API"])
        #expect(entries.allSatisfy { $0.connection == "Prod" })
        #expect(entries.allSatisfy { $0.service == "Jamf Platform API" })
        let everything = entries.map { "\($0.detail) \($0.request.map { "\($0)" } ?? "")" }.joined()
        #expect(!everything.contains("s3cr3t-value"))
        #expect(!everything.contains("test-token"))
    }

    @Test func aFailedSignInMessageIsRedacted() async throws {
        let body = #"{"error":"invalid_client","client_secret":"s3cr3t-value","note":"try Bearer abc.def.ghi"}"#
        let harness = Harness(tokenReply: MockHTTP.Reply(status: 401, headers: ["Content-Type": "application/json"],
                                                         data: Data(body.utf8)))
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let tenant = try harness.add("Prod", clientId: "prod")

        await #expect {
            _ = try await harness.store.client(for: tenant).send(.get, "pro/v1/sites")
        } throws: { error in
            guard let error = error as? JamfPlatformError, case .signIn(let status, _, _) = error.kind else { return false }
            let message = error.message()
            return status == 401
                && message.hasPrefix("Sign-in failed: HTTP 401")
                && message.contains("invalid_client")
                && !message.contains("s3cr3t-value")
                && !message.contains("abc.def.ghi")
        }
    }

    @Test func everyErrorMessageIsRedacted() {
        let answer = HTTPResponse(status: 400, data: Data(#"<password>hunter2</password> token=abc123"#.utf8))
        let error = JamfPlatformError(HTTPError.status(answer, method: "GET", path: "/pro/v1/sites", duringSignIn: false))
        let message = error.errorDescription ?? ""
        #expect(message.hasPrefix("HTTP 400"))
        #expect(!message.contains("hunter2"))
        #expect(!message.contains("abc123"))
    }

    @Test func aTenantWithoutASecretSaysWhereToEnterIt() async throws {
        let harness = Harness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let tenant = try harness.add("Prod", clientId: "prod", secret: "")

        await #expect {
            _ = try await harness.store.client(for: tenant).send(.get, "pro/v1/sites")
        } throws: { error in
            error is MissingSecret && error.localizedDescription.contains("Settings › Connections")
        }
        #expect(harness.signIns.value.isEmpty)
    }
}
