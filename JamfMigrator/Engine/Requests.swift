//
//  Requests.swift
//  JamfMigrator
//
//  The app's way of sending a request through JTKit's Platform client.
//

import Foundation
import JTKit

enum HTTPMethod: String, Sendable {
    case get    = "GET"
    case post   = "POST"
    case put    = "PUT"
    case patch  = "PATCH"
    case delete = "DELETE"

    var isWrite: Bool { self != .get }

    /// PUT replaces a whole record and DELETE removes one, so sending either
    /// twice does no harm: JTKit retries them after a server error, as it
    /// does reads.
    var isIdempotent: Bool { self == .get || self == .put || self == .delete }
}

/// JamfMigrator's requests on JTKit's client for one tenant: the platform API
/// gateway, or a Jamf Pro server reached directly (`pro/…` → `api/…`,
/// `proclassic/…` → `JSSResource/…`).
///
/// JTKit adds the bearer token, the `X-Environment-Id` header (gateway only),
/// its User-Agent, retries (429 for every method; server errors and network
/// drops for reads, PUT and DELETE; one new sign-in after a 401), XML for
/// `/proclassic` and JSON otherwise, and writes every request to the activity
/// log. On top of that writes get `Accept-Encoding: identity`.
extension JamfPlatform.Client {

    /// The spacing between writes the app has always used.
    static let defaultWriteSpacing: Duration = .milliseconds(200)

    /// Blueprints and Compliance Benchmarks exist only behind the gateway.
    var supportsPlatformEndpoints: Bool { server == .platformAPI }

    func send(_ method: HTTPMethod,
              _ path: String,
              query: [URLQueryItem] = [],
              body: Data? = nil,
              contentType: String? = nil,
              accept: String? = nil) async throws -> HTTPResponse {
        try await send(HTTPRequest(method: method.rawValue,
                                   path: path,
                                   query: query,
                                   body: body,
                                   accept: accept,
                                   contentType: contentType,
                                   headers: method.isWrite ? ["Accept-Encoding": "identity"] : [:],
                                   safeToRepeat: method.isIdempotent))
    }
}
