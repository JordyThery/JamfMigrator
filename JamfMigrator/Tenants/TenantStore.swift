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
@MainActor
@Observable
final class TenantStore {

    /// The Keychain items of tenants and service secrets. Builds before 1.0.1
    /// wrote to the data-protection keychain; such items move over on read.
    nonisolated static func keychain() -> KeychainSecretStore {
        KeychainSecretStore(service: "JamfMigrator-tenant",
                            accessibility: .afterFirstUnlock,
                            movesItemsFromDataProtectionKeychain: true,
                            log: { WriteToLog.shared.message($0) })
    }

    let connections: ConnectionStore<Tenant>
    /// The same items `connections` uses, read directly at token time, off
    /// the main actor.
    @ObservationIgnored private let secrets: any SecretStore

    init(directory: URL = URL(fileURLWithPath: AppInfo.appSupportPath, isDirectory: true),
         secrets: any SecretStore = TenantStore.keychain()) {
        self.secrets = secrets
        connections = ConnectionStore(
            storage: JSONFileConnectionStorage<Tenant>(fileURL: directory.appendingPathComponent("tenants.json")),
            secrets: [.main: SecretLocation(store: secrets)],
            log: { WriteToLog.shared.message("[TenantStore] \($0)") })
    }

    var tenants: [Tenant] { connections.records }

    func tenant(id: Tenant.ID) -> Tenant? {
        connections.record(id: id)
    }

    // MARK: Clients

    /// A client for the tenant. The secret (or password) is read from the
    /// Keychain at token time, so it can be corrected without rebuilding the
    /// client. `secretOverride` uses a secret typed in Settings instead, to
    /// test values that aren't saved yet.
    func client(for tenant: Tenant, secretOverride: String? = nil) -> PlatformClient {
        let secrets = secrets
        let account = tenant.id.uuidString
        let clientId = tenant.clientId

        @Sendable func storedSecret() throws -> String {
            guard let secret = secretOverride ?? secrets.secret(for: account), !secret.isEmpty else {
                throw GatewayError.tokenFailure(
                    status: 0,
                    detail: "No client secret or password is stored for this tenant. Enter it in Settings › Connections.")
            }
            return secret
        }

        if !tenant.usesGateway {
            // tenant.usesGateway alone decides the connection kind; a server
            // URL that fails to parse surfaces as an error at token time
            // rather than silently falling back to the gateway
            let serverURLString = tenant.serverURL ?? ""
            let serverURL = URL(string: serverURLString)
            let username = (tenant.username ?? "").trimmingCharacters(in: .whitespaces)
            let provider = TokenProvider(credentials: {
                guard let serverURL else {
                    throw GatewayError.invalidURL(serverURLString)
                }
                let tokenURL = serverURL.appendingPathComponent(username.isEmpty ? "api/oauth/token" : "api/v1/auth/token")
                let method: TokenProvider.Credentials.Method = username.isEmpty
                    ? .oauthClient(clientId: clientId, clientSecret: try storedSecret())
                    : .userPassword(username: username, password: try storedSecret())
                return TokenProvider.Credentials(tokenURL: tokenURL, method: method)
            })
            return PlatformClient(serverURL: serverURL ?? URL(fileURLWithPath: "/dev/null"),
                                  tokenProvider: provider)
        }

        let tokenURL = tenant.region.tokenURL
        let provider = TokenProvider(credentials: {
            TokenProvider.Credentials(tokenURL: tokenURL, clientId: clientId, clientSecret: try storedSecret())
        })
        return PlatformClient(region: tenant.region,
                              environmentId: tenant.environmentId,
                              tokenProvider: provider)
    }
}
