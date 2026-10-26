//
//  PlatformClient.swift
//  JamfMigrator
//
//  Sends every request for one tenant, through JTKit's HTTP client.
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

/// JamfMigrator's side of JTKit's HTTP client for one tenant: the platform
/// API gateway or a direct Jamf Pro server.
///
/// JTKit adds the bearer token, retries (429 for every method; server errors
/// and network drops for reads, PUT and DELETE; one new sign-in after a 401)
/// and writes every request to the activity log. On top of that every
/// request gets the `X-Environment-Id` header (gateway only), XML for
/// `/proclassic` and JSON otherwise, and `Accept-Encoding: identity` on
/// writes. Redirects are never followed (the gateway's `href` values point at
/// internal hosts). Writes start at least `writeSpacing` apart.
struct PlatformClient: Sendable {

    struct Response: Sendable {
        let status: Int
        let data: Data

        func decoded<T: Decodable>(_ type: T.Type = T.self) throws -> T {
            do {
                return try JSONDecoder().decode(type, from: data)
            } catch {
                throw GatewayError.decoding(error)
            }
        }
    }

    /// How canonical (gateway-form) paths map onto this server.
    enum Connection: Sendable, Equatable {
        /// The platform gateway: paths are used as-is, X-Environment-Id is sent.
        case gateway
        /// A Jamf Pro instance: pro/… → api/…, proclassic/… → JSSResource/….
        /// Platform-only namespaces have no equivalent here.
        case direct
    }

    /// The spacing between writes the app has always used.
    static let defaultWriteSpacing: Duration = .milliseconds(200)

    let http: HTTPClient
    let environmentId: String
    let connection: Connection
    var baseURL: URL { http.baseURL }
    /// The recorder under the client, for the few requests that don't go to
    /// the tenant's API (Self Service icons on Jamf's icon server).
    var recorder: RequestRecorder { http.recorder }
    /// Blueprints and Compliance Benchmarks exist only behind the gateway.
    var supportsPlatformEndpoints: Bool { connection == .gateway }

    /// A tenant behind the platform API gateway of `region`.
    init(region: Region,
         environmentId: String,
         tokens: any BearerTokenSource,
         recorder: RequestRecorder,
         writeSpacing: Duration = PlatformClient.defaultWriteSpacing,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.init(baseURL: region.gatewayURL, environmentId: environmentId, connection: .gateway,
                  tokens: tokens, recorder: recorder, writeSpacing: writeSpacing, sleep: sleep, random: random)
    }

    /// A direct Jamf Pro connection, for tenants without Platform API access.
    init(serverURL: URL,
         tokens: any BearerTokenSource,
         recorder: RequestRecorder,
         writeSpacing: Duration = PlatformClient.defaultWriteSpacing,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.init(baseURL: serverURL, environmentId: "", connection: .direct,
                  tokens: tokens, recorder: recorder, writeSpacing: writeSpacing, sleep: sleep, random: random)
    }

    private init(baseURL: URL,
                 environmentId: String,
                 connection: Connection,
                 tokens: any BearerTokenSource,
                 recorder: RequestRecorder,
                 writeSpacing: Duration,
                 sleep: @escaping @Sendable (Duration) async throws -> Void,
                 random: @escaping @Sendable () -> Double) {
        var headers = ["User-Agent": AppInfo.userAgentHeader]
        if !environmentId.isEmpty {
            headers["X-Environment-Id"] = environmentId
        }
        self.http = HTTPClient(baseURL: baseURL,
                               tokens: tokens,
                               recorder: recorder,
                               headers: headers,
                               pathMapping: connection == .direct ? .jamfProDirect : .none,
                               redirects: .refuse,
                               writeSpacing: writeSpacing,
                               sleep: sleep,
                               random: random)
        self.environmentId = environmentId
        self.connection = connection
    }

    // MARK: Requests

    func send(_ method: HTTPMethod,
              _ path: String,
              query: [URLQueryItem] = [],
              body: Data? = nil,
              contentType: String? = nil,
              accept: String? = nil) async throws -> Response {
        let request = HTTPRequest(method: method.rawValue,
                                  path: path,
                                  query: query,
                                  body: body,
                                  accept: accept,
                                  contentType: contentType,
                                  headers: method.isWrite ? ["Accept-Encoding": "identity"] : [:],
                                  safeToRepeat: method.isIdempotent)
        do {
            let response = try await http.send(request)
            return Response(status: response.status, data: response.data)
        } catch let error as HTTPError {
            throw GatewayError(error)
        }
    }

    /// GET and decode a JSON response.
    func get<T: Decodable>(_ type: T.Type = T.self, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send(.get, path, query: query).decoded(type)
    }
}
