//
//  InMemorySecretStore.swift
//  JamfMigratorTests
//
//  Test double for SecretStore: keeps secrets in memory.
//

import Foundation
@testable import JamfMigrator

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
