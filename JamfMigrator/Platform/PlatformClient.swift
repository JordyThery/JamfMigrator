//
//  PlatformClient.swift
//  JamfMigrator
//
//  Sends every request to the platform API gateway for one tenant.
//

import Foundation

enum HTTPMethod: String, Sendable {
    case get    = "GET"
    case post   = "POST"
    case put    = "PUT"
    case patch  = "PATCH"
    case delete = "DELETE"

    var isWrite: Bool { self != .get }

    /// Only idempotent methods are retried after a 5xx.
    var isIdempotent: Bool { self == .get || self == .put || self == .delete }
}

/// One tenant's connection to the platform API gateway.
///
/// Every request gets the bearer token, the `X-Environment-Id` header and the
/// correct Accept/Content-Type (XML for `/proclassic`, JSON otherwise), plus
/// `Accept-Encoding: identity` on writes. Redirects are never followed (the
/// gateway's `href` values point at internal hosts). A 401 refreshes the token
/// once; 429 honors `Retry-After`; 5xx retries only idempotent methods.
/// Writes are throttled to one per `writeInterval`.
actor PlatformClient {

    struct Configuration: Sendable {
        /// Total attempts for a request, including the first one.
        var maxAttempts = 4
        /// Base delay for retries without a Retry-After header; grows linearly per attempt.
        var retryBaseDelay: Duration = .seconds(1)
        /// Minimum spacing between write requests.
        var writeInterval: Duration = .milliseconds(200)
        var userAgent = AppInfo.userAgentHeader
    }

    struct Response: Sendable {
        let status: Int
        let data: Data
        let headers: [String: String]

        func decoded<T: Decodable>(_ type: T.Type = T.self) throws -> T {
            do {
                return try JSONDecoder().decode(type, from: data)
            } catch {
                throw GatewayError.decoding(error)
            }
        }
    }

    nonisolated let baseURL: URL
    nonisolated let environmentId: String
    private let tokenProvider: TokenProvider
    private let session: URLSession
    private let configuration: Configuration
    /// Injectable so the retry and throttle tests don't actually wait.
    private let sleep: @Sendable (Duration) async throws -> Void
    private var lastWrite: ContinuousClock.Instant?
    private let redirectBlocker = RedirectBlocker()

    init(region: Region,
         environmentId: String,
         tokenProvider: TokenProvider,
         session: URLSession = URLSession(configuration: .ephemeral),
         configuration: Configuration = Configuration(),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.baseURL = region.gatewayURL
        self.environmentId = environmentId
        self.tokenProvider = tokenProvider
        self.session = session
        self.configuration = configuration
        self.sleep = sleep
    }

    // MARK: Requests

    func send(_ method: HTTPMethod,
              _ path: String,
              query: [URLQueryItem] = [],
              body: Data? = nil,
              contentType: String? = nil,
              accept: String? = nil) async throws -> Response {
        let request = try makeRequest(method, path, query: query, body: body,
                                      contentType: contentType, accept: accept)
        var attempt = 0
        var didRetryAuth = false
        while true {
            attempt += 1
            if method.isWrite {
                try await throttleWrite()
            }
            var attemptRequest = request
            attemptRequest.setValue("Bearer \(try await tokenProvider.validToken())",
                                    forHTTPHeaderField: "Authorization")

            let data: Data
            let urlResponse: URLResponse
            do {
                (data, urlResponse) = try await session.data(for: attemptRequest, delegate: redirectBlocker)
            } catch {
                throw GatewayError.transport(error)
            }
            guard let http = urlResponse as? HTTPURLResponse else {
                throw GatewayError.transport(URLError(.badServerResponse))
            }

            switch http.statusCode {
            case 200...299:
                var headers = [String: String]()
                for (name, value) in http.allHeaderFields {
                    if let name = name as? String, let value = value as? String {
                        headers[name] = value
                    }
                }
                return Response(status: http.statusCode, data: data, headers: headers)
            case 401 where !didRetryAuth:
                didRetryAuth = true
                await tokenProvider.invalidate()
            case 429 where attempt < configuration.maxAttempts:
                try await sleep(retryDelay(for: http, attempt: attempt))
            case 500... where method.isIdempotent && attempt < configuration.maxAttempts:
                try await sleep(configuration.retryBaseDelay * attempt)
            default:
                throw GatewayError.from(status: http.statusCode, body: data)
            }
        }
    }

    /// GET and decode a JSON response.
    func get<T: Decodable>(_ type: T.Type = T.self, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send(.get, path, query: query).decoded(type)
    }

    // MARK: Request construction

    private func makeRequest(_ method: HTTPMethod,
                             _ path: String,
                             query: [URLQueryItem],
                             body: Data?,
                             contentType: String?,
                             accept: String?) throws -> URLRequest {
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(url: baseURL.appendingPathComponent(trimmedPath),
                                             resolvingAgainstBaseURL: false) else {
            throw GatewayError.invalidURL("\(baseURL)/\(trimmedPath)")
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw GatewayError.invalidURL("\(baseURL)/\(trimmedPath)?\(query)")
        }

        // the Classic namespace speaks XML, everything else JSON
        let isClassic = trimmedPath.hasPrefix("proclassic")
        let defaultType = isClassic ? "application/xml" : "application/json"

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue(environmentId, forHTTPHeaderField: "X-Environment-Id")
        request.setValue(accept ?? defaultType, forHTTPHeaderField: "Accept")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue(contentType ?? defaultType, forHTTPHeaderField: "Content-Type")
        }
        if method.isWrite {
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }
        return request
    }

    // MARK: Retry and throttle

    private func retryDelay(for response: HTTPURLResponse, attempt: Int) -> Duration {
        if let header = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(header.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            return .seconds(seconds)
        }
        return configuration.retryBaseDelay * attempt
    }

    private func throttleWrite() async throws {
        let now = ContinuousClock.now
        if let lastWrite {
            let elapsed = now - lastWrite
            if elapsed < configuration.writeInterval {
                try await sleep(configuration.writeInterval - elapsed)
            }
        }
        lastWrite = ContinuousClock.now
    }
}

/// Refuses every redirect: the gateway's Location/href values point at
/// internal hosts that are not reachable (and would drop our headers).
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
