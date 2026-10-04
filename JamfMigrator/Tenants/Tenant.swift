//
//  Tenant.swift
//  JamfMigrator
//
//  One Jamf tenant reached through the platform API gateway.
//

import Foundation

/// A tenant as stored on disk. The client secret is not part of this model;
/// it lives in the Keychain, keyed by `id` (see `TenantStore`).
struct Tenant: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var region: Region = .us
    /// The environment UUID sent as X-Environment-Id.
    var environmentId: String = ""
    /// The API integration's client ID.
    var clientId: String = ""
    /// A direct Jamf Pro server URL (https://tenant.jamfcloud.com) for MSP
    /// tenants without Platform API access. Empty or nil = platform gateway.
    var serverURL: String?
    /// For direct connections: a Jamf Pro username instead of an API client.
    /// Non-empty = user/password auth; the password sits in the same Keychain
    /// slot as the client secret.
    var username: String?
    /// A protected tenant can never be wiped. On by default for the golden master.
    var isProtected = false

    /// Whether this tenant connects through the platform gateway.
    var usesGateway: Bool {
        (serverURL ?? "").isEmpty
    }
}
