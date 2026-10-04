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

    func setSecret(_ secret: String?, for tenant: Tenant) {
        secrets.setSecret(secret, for: tenant.id.uuidString)
    }

    // MARK: Clients

    /// A client for the tenant. The secret (or password) is read from the
    /// Keychain at token time, so it can be corrected without rebuilding the
    /// client.
    func client(for tenant: Tenant) -> PlatformClient {
        let secrets = secrets
        let account = tenant.id.uuidString

        if !tenant.usesGateway, let serverURL = URL(string: tenant.serverURL ?? "") {
            let username = (tenant.username ?? "").trimmingCharacters(in: .whitespaces)
            let tokenURL = serverURL.appendingPathComponent(username.isEmpty ? "api/oauth/token" : "api/v1/auth/token")
            let clientId = tenant.clientId
            let provider = TokenProvider(credentials: {
                guard let secret = secrets.secret(for: account), !secret.isEmpty else {
                    throw GatewayError.tokenFailure(status: 0, detail: "no client secret stored for this tenant")
                }
                let method: TokenProvider.Credentials.Method = username.isEmpty
                    ? .oauthClient(clientId: clientId, clientSecret: secret)
                    : .userPassword(username: username, password: secret)
                return TokenProvider.Credentials(tokenURL: tokenURL, method: method)
            })
            return PlatformClient(serverURL: serverURL, tokenProvider: provider)
        }

        let tokenURL = tenant.region.tokenURL
        let clientId = tenant.clientId
        let provider = TokenProvider(credentials: {
            guard let secret = secrets.secret(for: account), !secret.isEmpty else {
                throw GatewayError.tokenFailure(status: 0, detail: "no client secret stored for this tenant")
            }
            return TokenProvider.Credentials(tokenURL: tokenURL, clientId: clientId, clientSecret: secret)
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
            WriteToLog.shared.message("[TenantStore] could not read \(fileURL.path): \(error.localizedDescription)")
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
