//
//  Region.swift
//  JamfMigrator
//
//  The Jamf platform API gateway regions.
//

import Foundation

/// A Jamf platform API gateway region. Every tenant is reached through one of
/// these gateways using client credentials and an X-Environment-Id header.
enum Region: String, Codable, CaseIterable, Identifiable, Sendable {
    case us
    case eu
    case apac

    var id: String { rawValue }

    /// The gateway root, e.g. https://us.api.jamfcloud.com
    var gatewayURL: URL {
        URL(string: "https://\(rawValue).api.jamfcloud.com")!
    }

    /// The token endpoint for the client-credentials grant.
    var tokenURL: URL {
        gatewayURL.appendingPathComponent("auth/token")
    }

    var displayName: String {
        switch self {
        case .us:   "United States"
        case .eu:   "Europe"
        case .apac: "Asia-Pacific"
        }
    }
}
