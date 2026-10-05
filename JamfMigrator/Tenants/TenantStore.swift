//
//  TenantStore.swift
//  JamfMigrator
//
//  Persists the configured tenants and vends platform clients for them.
//

import Foundation
import Observation

/// The list of configured tenants. Tenants are saved as JSON in Application
/// Support; each tenant's client secret goes to the Keychain keyed by its id.
@MainActor
@Observable
final class TenantStore {

    private(set) var tenants: [Tenant] = []

    private let fileURL: URL
    private let secrets: any SecretStore

    init(directory: URL = URL(fileURLWithPath: AppInfo.appSupportPath, isDirectory: true),
         secrets: any SecretStore = KeychainSecretStore()) {
        self.fileURL = directory.appendingPathComponent("tenants.json")
        self.secrets = secrets
        load()
    }

    // MARK: Tenants

    func tenant(id: Tenant.ID) -> Tenant? {
        tenants.first { $0.id == id }
    }

    /// Adds a new tenant or updates the stored one with the same id.
    func upsert(_ tenant: Tenant) {
        if let index = tenants.firstIndex(where: { $0.id == tenant.id }) {
            tenants[index] = tenant
        } else {
            tenants.append(tenant)
        }
        save()
    }

    /// Removes the tenant and its Keychain secret.
    func remove(_ tenant: Tenant) {
        tenants.removeAll { $0.id == tenant.id }
        secrets.setSecret(nil, for: tenant.id.uuidString)
        save()
    }

    // MARK: Secrets

    func secret(for tenant: Tenant) -> String? {
        secrets.secret(for: tenant.id.uuidString)
    }

    @discardableResult
    func setSecret(_ secret: String?, for tenant: Tenant) -> Bool {
        secrets.setSecret(secret, for: tenant.id.uuidString)
    }

    // MARK: Clients

    /// A client for the tenant. The secret (or password) is read from the
    /// Keychain at token time, so it can be corrected without rebuilding the
    /// client.
    func client(for tenant: Tenant) -> PlatformClient {
        let secrets = secrets
        let account = tenant.id.uuidString
        let clientId = tenant.clientId

        @Sendable func storedSecret() throws -> String {
            guard let secret = secrets.secret(for: account), !secret.isEmpty else {
                throw GatewayError.tokenFailure(
                    status: 0,
                    detail: "No client secret or password is stored for this tenant. Enter it in Settings › Tenants.")
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

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            tenants = try JSONDecoder().decode([Tenant].self, from: data)
        } catch {
            // move the unreadable file aside so a later save can't overwrite it
            let aside = fileURL.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            WriteToLog.shared.message("[TenantStore] could not read \(fileURL.path): \(error.localizedDescription); moved it to \(aside.lastPathComponent)")
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try encoder.encode(tenants).write(to: fileURL, options: .atomic)
        } catch {
            WriteToLog.shared.message("[TenantStore] could not save \(fileURL.path): \(error.localizedDescription)")
        }
    }
}
