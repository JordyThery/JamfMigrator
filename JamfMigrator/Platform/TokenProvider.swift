//
//  TokenProvider.swift
//  JamfMigrator
//
//  Client-credentials tokens for the platform API gateway.
//

import Foundation

/// Fetches and caches a bearer token for one tenant.
///
/// The gateway issues no refresh token (`refresh_expires_in` is 0), so every
/// refresh is a new client-credentials grant. Tokens live 900 s; a cached
/// token is reused until 80% of its lifetime has passed. Only one fetch runs
/// at a time: concurrent callers await the same request.
actor TokenProvider {

    struct Credentials: Sendable {
        let tokenURL: URL
        let clientId: String
        let clientSecret: String
    }

    private struct Token {
        let value: String
        let obtained: Date
        let lifetime: TimeInterval

        func isUsable(at date: Date) -> Bool {
            date.timeIntervalSince(obtained) < lifetime * 0.8
        }
    }

    /// Read at fetch time so a secret updated in the Keychain is picked up
    /// without rebuilding the provider.
    private let credentials: @Sendable () throws -> Credentials
    private let session: URLSession
    private let now: @Sendable () -> Date

    private var cached: Token?
    private var fetchTask: Task<Token, any Error>?

    init(credentials: @escaping @Sendable () throws -> Credentials,
         session: URLSession = URLSession(configuration: .ephemeral),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials
        self.session = session
        self.now = now
    }

    /// A token that is valid right now, fetching a new one if needed.
    func validToken() async throws -> String {
        if let cached, cached.isUsable(at: now()) {
            return cached.value
        }
        return try await refreshedToken().value
    }

    /// Drops the cached token so the next call fetches a new one, e.g. after a 401.
    func invalidate() {
        cached = nil
    }

    private func refreshedToken() async throws -> Token {
        if let fetchTask {
            return try await fetchTask.value
        }
        let task = Task { [credentials, session, now] in
            try await Self.fetchToken(credentials: credentials(), session: session, now: now)
        }
        fetchTask = task
        defer { fetchTask = nil }
        do {
            let token = try await task.value
            cached = token
            return token
        } catch {
            cached = nil
            throw error
        }
    }

    private static func fetchToken(credentials: Credentials,
                                   session: URLSession,
                                   now: @Sendable () -> Date) async throws -> Token {
        var request = URLRequest(url: credentials.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: credentials.clientId),
            URLQueryItem(name: "client_secret", value: credentials.clientSecret),
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GatewayError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GatewayError.transport(URLError(.badServerResponse))
        }
        guard (200...299).contains(http.statusCode) else {
            throw GatewayError.tokenFailure(status: http.statusCode,
                                            detail: String(data: data, encoding: .utf8))
        }

        struct TokenResponse: Decodable {
            let accessToken: String
            let expiresIn: TimeInterval
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case expiresIn = "expires_in"
            }
        }
        do {
            let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            return Token(value: decoded.accessToken, obtained: now(), lifetime: decoded.expiresIn)
        } catch {
            throw GatewayError.decoding(error)
        }
    }
}
