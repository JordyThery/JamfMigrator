//
//  TenantStore.swift
//  JamfMigrator
//
//  The configured tenants (JTKit's saved connections) and platform clients
//  for them.
//

import Foundation
import JTKit
import Observation

/// The list of configured tenants. JTKit's `ConnectionStore` keeps them where
/// they have always been: tenants.json in Application Support, and each
/// tenant's client secret or password in the Keychain under service
/// "JamfMigrator-tenant", account = the tenant's id.
///
/// It also keeps one JTKit client per tenant, so Source and Destination each
/// have their own sign-in and token, reused by Preview, Run, Backup, Verify
/// and the mappings. A tenant's client is rebuilt after the tenant is edited
/// and dropped when it is deleted.
///
/// Demo mode's two tenants ("Contoso Source (Demo)", "Contoso Destination
/// (Demo)") get their client here too, from JTKit's demo: its private
/// network and a fake secret, never the Keychain or the real network. A
/// saved tenant always gets the real ones, Test Connection included.
@MainActor
@Observable
final class TenantStore {

    /// The Keychain items of tenants and service secrets. Builds before 1.0.1
    /// wrote to the data-protection keychain; such items move over on read.
    nonisolated static func keychain() -> KeychainSecretStore {
        KeychainSecretStore(service: "JamfMigrator-tenant",
                            accessibility: .afterFirstUnlock,
                            movesItemsFromDataProtectionKeychain: true,
                            log: { AppActivity.record($0, category: "Keychain", level: .warning) })
    }

    let connections: ConnectionStore<Tenant>
    /// The same items `connections` uses, read directly at token time, off
    /// the main actor.
    @ObservationIgnored private let secrets: any SecretStore
    /// Where requests are recorded; nil records nothing.
    @ObservationIgnored private let log: ActivityLog?
    @ObservationIgnored private let session: URLSession
    /// Answers demo mode's tenants; nil in tests that don't need it.
    @ObservationIgnored private let demo: DemoMode?
    /// Each tenant's client, with the tenant as it was when the client was made.
    @ObservationIgnored private var clients: [Tenant.ID: (tenant: Tenant, client: JamfPlatform.Client)] = [:]

    init(directory: URL = URL(fileURLWithPath: AppInfo.appSupportPath, isDirectory: true),
         secrets: any SecretStore = TenantStore.keychain(),
         log: ActivityLog? = AppActivity.log,
         session: URLSession = URLSession(configuration: .ephemeral),
         demo: DemoMode? = nil,
         storage: (any ConnectionStorage<Tenant>)? = nil) {
        self.secrets = secrets
        self.log = log
        self.session = session
        self.demo = demo
        connections = ConnectionStore(
            storage: storage ?? JSONFileConnectionStorage<Tenant>(fileURL: directory.appendingPathComponent("tenants.json")),
            secrets: [.main: SecretLocation(store: secrets)],
            log: { AppActivity.record($0, category: "Tenants", level: .warning) })
    }

    var tenants: [Tenant] { connections.records }

    func tenant(id: Tenant.ID) -> Tenant? {
        connections.record(id: id)
    }

    // MARK: Clients

    /// The tenant's client, kept for as long as the tenant stays as it is.
    /// The secret (or password) is read from the Keychain at sign-in, so a
    /// corrected secret is used at the next sign-in.
    func client(for tenant: Tenant) -> JamfPlatform.Client {
        if let kept = clients[tenant.id], kept.tenant == tenant {
            return kept.client
        }
        let client = makeClient(for: tenant, secretOverride: nil)
        clients[tenant.id] = (tenant, client)
        return client
    }

    /// A one-off client for Test Connection in Settings, with the values in
    /// the editor and, if typed, a secret that isn't saved yet.
    /// It always uses the real network, also while demo mode is on.
    func testClient(for tenant: Tenant, secretOverride: String?) -> JamfPlatform.Client {
        makeClient(for: tenant, secretOverride: secretOverride.flatMap { $0.isEmpty ? nil : $0 }, usesDemo: false)
    }

    /// Drops a deleted tenant's client and its token.
    func forgetClient(for id: Tenant.ID) {
        clients[id] = nil
    }

    private func makeClient(for tenant: Tenant, secretOverride: String?, usesDemo: Bool = true) -> JamfPlatform.Client {
        let secrets = secrets
        let account = tenant.id.uuidString
        var connection = tenant.connection
        var recorder = RequestRecorder(session: session,
                                       log: log,
                                       service: connection.service.displayName,
                                       connection: tenant.name)

        @Sendable func storedSecret() throws -> String {
            guard let secret = secretOverride ?? secrets.secret(for: account), !secret.isEmpty else {
                throw MissingSecret()
            }
            return secret
        }
        var secret: @Sendable () throws -> String = storedSecret

        // a demo tenant: JTKit's demo network and fake secret, never the
        // Keychain; a saved tenant never gets a demo source, so it can't
        // reach the demo, nor a demo tenant the real network
        if usesDemo, let source = demo?.source(for: connection) {
            connection = source.connection
            secret = source.secret
            recorder = RequestRecorder(session: source.session, log: log,
                                       service: connection.service.displayName, connection: connection.name)
        }

        do {
            return try JamfPlatform.Client(connection: connection, secret: secret, recorder: recorder,
                                           writeSpacing: JamfPlatform.Client.defaultWriteSpacing)
        } catch {
            // an unusable server URL or Environment ID surfaces at the first
            // request rather than silently falling back to the gateway
            let reason = error as? JamfPlatformError ?? JamfPlatformError(.invalidResponse(error.localizedDescription))
            // organization scope has no Environment ID to check, so this can't throw
            return try! JamfPlatform.Client(baseURL: connection.jamfBaseURL ?? tenant.region.gatewayURL,
                                            scope: .organization,
                                            server: tenant.usesGateway ? .platformAPI : .jamfPro,
                                            tokens: UnusableTokens(error: reason),
                                            recorder: recorder)
        }
    }
}

/// No client secret or password is saved for the tenant.
struct MissingSecret: LocalizedError {
    var errorDescription: String? {
        "No client secret or password is stored for this tenant. Enter it in Settings › Connections."
    }
}

/// The tokens of a tenant whose address can't be used: every request fails
/// with the reason.
private struct UnusableTokens: BearerTokenSource {
    let error: JamfPlatformError

    func token() async throws -> String { throw error }
    func forgetToken() async {}
}
