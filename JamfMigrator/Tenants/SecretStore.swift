//
//  SecretStore.swift
//  JamfMigrator
//
//  Client secrets live in the Keychain, never on disk.
//

import Foundation
import Security

/// Stores one secret string per account. Backed by the Keychain in the app
/// and by a dictionary in tests.
protocol SecretStore: Sendable {
    func secret(for account: String) -> String?
    /// Passing nil deletes the entry.
    func setSecret(_ secret: String?, for account: String)
}

/// Generic-password Keychain items under one service name.
struct KeychainSecretStore: SecretStore {
    var service = "JamfMigrator-tenant"

    private func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    func secret(for account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                WriteToLog.shared.message("[KeychainSecretStore] lookup for \(account) failed: \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func setSecret(_ secret: String?, for account: String) {
        guard let secret, let data = secret.data(using: .utf8) else {
            SecItemDelete(baseQuery(account: account) as CFDictionary)
            return
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
    }
}

/// Test double: keeps secrets in memory.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets = [String: String]()

    func secret(for account: String) -> String? {
        lock.withLock { secrets[account] }
    }

    func setSecret(_ secret: String?, for account: String) {
        lock.withLock { secrets[account] = secret }
    }
}
