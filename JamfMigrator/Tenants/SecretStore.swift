//
//  SecretStore.swift
//  JamfMigrator
//
//  Client secrets live in the Keychain, never on disk.
//

import Foundation
import Security

/// Stores one secret string per account. Backed by the Keychain in the app
/// and by a dictionary in tests (see InMemorySecretStore in the test target).
protocol SecretStore: Sendable {
    func secret(for account: String) -> String?
    /// Passing nil deletes the entry. Returns false when the write failed.
    @discardableResult
    func setSecret(_ secret: String?, for account: String) -> Bool
}

/// Generic-password items in the login (file-based) keychain, under one
/// service name.
///
/// Not the data-protection keychain: on macOS that needs an
/// application-identifier entitlement, which only a provisioning profile
/// provides. A Developer ID build has none, so every write failed with
/// errSecMissingEntitlement (-34018) while Xcode-run builds — signed with a
/// development profile — worked (found in 1.0, 2026-10-05).
struct KeychainSecretStore: SecretStore {
    var service = "JamfMigrator-tenant"

    private func baseQuery(account: String, dataProtection: Bool = false) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    func secret(for account: String) -> String? {
        if let value = read(baseQuery(account: account), account: account) {
            return value
        }
        // builds before 1.0.1 wrote to the data-protection keychain, which
        // only development-signed builds could reach; move such an item over
        // so it survives the switch
        let legacy = baseQuery(account: account, dataProtection: true)
        guard let value = read(legacy, account: account, logMisses: false) else { return nil }
        if setSecret(value, for: account) {
            SecItemDelete(legacy as CFDictionary)
        }
        return value
    }

    @discardableResult
    func setSecret(_ secret: String?, for account: String) -> Bool {
        guard let secret, let data = secret.data(using: .utf8) else {
            let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        var attributes = baseQuery(account: account)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecValueData as String] = data

        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(baseQuery(account: account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        }
        if status != errSecSuccess {
            WriteToLog.shared.message("[KeychainSecretStore] save for \(account) failed: \(status)")
        }
        return status == errSecSuccess
    }

    private func read(_ base: [String: Any], account: String, logMisses: Bool = true) -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if logMisses && status != errSecItemNotFound {
                WriteToLog.shared.message("[KeychainSecretStore] lookup for \(account) failed: \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
