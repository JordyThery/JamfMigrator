//
//  Tenant.swift
//  JamfMigrator
//
//  One Jamf tenant reached through the platform API gateway.
//

import Foundation
import JTKit

/// A tenant as stored on disk. The client secret is not part of this model;
/// it lives in the Keychain, keyed by `id` (see `TenantStore`).
///
/// The Codable keys are the property names and must stay as they are: they
/// are what tenants.json has always contained.
struct Tenant: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var region: Region = .us
    /// The environment UUID sent as X-Environment-Id.
    var environmentId: String = ""
    /// The API integration's client ID.
    var clientId: String = ""
    /// A direct Jamf Pro server URL (https://tenant.jamfcloud.com) for
    /// tenants without Platform API access. Empty or nil = platform gateway.
    var serverURL: String?
    /// For direct connections: a Jamf Pro username instead of an API client.
    /// Non-empty = user/password auth; the password sits in the same Keychain
    /// slot as the client secret.
    var username: String?
    /// A protected tenant can never be wiped. Recommended for the source tenant.
    var isProtected = false

    /// Whether this tenant connects through the platform gateway.
    var usesGateway: Bool {
        (serverURL ?? "").isEmpty
    }
}

/// How JTKit's shared connections list and editor see a tenant. A gateway
/// tenant is a Jamf Platform API connection; a tenant with a server URL is a
/// Jamf Pro connection, signing in with an API client or, when it has a
/// username, with username and password.
extension Tenant: ConnectionRecord {

    init(connection: Connection) {
        self.init(id: connection.id, name: connection.name)
        self.connection = connection
    }

    var connection: Connection {
        get {
            Connection(id: id,
                       name: name,
                       service: usesGateway ? .jamfPlatform : .jamfPro,
                       signIn: !usesGateway && !(username ?? "").isEmpty ? .usernamePassword : .apiClient,
                       serverURL: serverURL ?? "",
                       region: JamfRegion(rawValue: region.rawValue) ?? .us,
                       environmentID: environmentId,
                       clientID: clientId,
                       username: username ?? "")
        }
        set {
            // Only fields that changed are written, so setting back what was
            // read leaves the tenant exactly as it was.
            if name != newValue.name { name = newValue.name }
            if let newRegion = Region(rawValue: newValue.region.rawValue), newRegion != region { region = newRegion }
            if environmentId != newValue.environmentID { environmentId = newValue.environmentID }
            if clientId != newValue.clientID { clientId = newValue.clientID }
            switch newValue.service {
            case .jamfPro:
                // an empty URL would read back as a gateway tenant, so a new
                // Jamf Pro tenant starts at "https://", as the old editor did
                let url = newValue.serverURL.isEmpty ? "https://" : newValue.serverURL
                if serverURL != url { serverURL = url }
                if newValue.signIn == .usernamePassword {
                    if (username ?? "") != newValue.username { username = newValue.username }
                } else if !(username ?? "").isEmpty {
                    username = nil
                }
            default:
                // the gateway ignores serverURL and username; only clear the URL
                if !(serverURL ?? "").isEmpty { serverURL = nil }
            }
        }
    }

    var listBadge: (systemImage: String, help: String)? {
        isProtected ? ("lock.fill", "Protected: this tenant can never be wiped.") : nil
    }
}
