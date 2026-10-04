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
        enum Method: Sendable {
            /// OAuth client credentials (/auth/token on the gateway,
            /// /api/oauth/token on a Jamf Pro server).
            case oauthClient(clientId: String, clientSecret: String)
            /// A Jamf Pro user account (/api/v1/auth/token): the credentials
            /// go in one Basic header to mint a bearer token; every API call
            /// still uses the bearer token.
            case userPassword(username: String, password: String)
        }

        let tokenURL: URL
        let method: Method

        init(tokenURL: URL, method: Method) {
            self.tokenURL = tokenURL
            self.method = method
        }

        init(tokenURL: URL, clientId: String, clientSecret: String) {
            self.init(tokenURL: tokenURL, method: .oauthClient(clientId: clientId, clientSecret: clientSecret))
        }
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch credentials.method {
        case .oauthClient(let clientId, let clientSecret):
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            // form-encode by hand: URLComponents leaves "+" unencoded, which
            // the server would decode as a space inside a secret
            request.httpBody = Data(
                "grant_type=client_credentials&client_id=\(formEncoded(clientId))&client_secret=\(formEncoded(clientSecret))".utf8)
        case .userPassword(let username, let password):
            let basic = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        }

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
            let detail = String(data: data, encoding: .utf8).map { String($0.prefix(300)) }
            throw GatewayError.tokenFailure(status: http.statusCode, detail: detail)
        }

        // two response shapes: OAuth {access_token, expires_in} and the Jamf
        // Pro user-token {token, expires: ISO8601}
        struct OAuthResponse: Decodable {
            let accessToken: String
            let expiresIn: TimeInterval
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case expiresIn = "expires_in"
            }
        }
        struct UserTokenResponse: Decodable {
            let token: String
            let expires: String
        }
        if let decoded = try? JSONDecoder().decode(OAuthResponse.self, from: data) {
            return Token(value: decoded.accessToken, obtained: now(), lifetime: decoded.expiresIn)
        }
        do {
            let decoded = try JSONDecoder().decode(UserTokenResponse.self, from: data)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let lifetime = formatter.date(from: decoded.expires).map { $0.timeIntervalSince(now()) } ?? 20 * 60
            return Token(value: decoded.token, obtained: now(), lifetime: max(lifetime, 60))
        } catch {
            throw GatewayError.decoding(error)
        }
    }

    private static func formEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
