//
//  MockHTTP.swift
//  JamfMigratorTests
//
//  A URLProtocol-based fake server. Each session gets its own handler, keyed
//  through an X-Mock-Id header, so tests can run in parallel.
//

import Foundation
import JTKit
@testable import JamfMigrator

/// A tiny lock box so test state can cross @Sendable boundaries.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) { _value = value }

    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { body(&_value) }
    }
}

enum MockHTTP {
    struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var data = Data()
    }

    typealias Handler = @Sendable (URLRequest) throws -> Reply

    private static let handlers = Locked<[String: Handler]>([:])

    /// A URLSession whose every request is answered by `handler`.
    static func session(handler: @escaping Handler) -> URLSession {
        let id = UUID().uuidString
        handlers.withLock { $0[id] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Mock-Id": id]
        return URLSession(configuration: configuration)
    }

    static func handler(for id: String) -> Handler? {
        handlers.withLock { $0[id] }
    }

    static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    static func tokenJSON(_ token: String = "test-token", expiresIn: Double = 900) -> Reply {
        Reply(status: 200, data: json(["access_token": token, "expires_in": expiresIn, "token_type": "Bearer"]))
    }
}

final class MockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let id = request.value(forHTTPHeaderField: "X-Mock-Id"),
                  let handler = MockHTTP.handler(for: id) else {
                throw URLError(.unsupportedURL)
            }
            let reply = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                           httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// Inside URLProtocol the body arrives as a stream, never in httpBody.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Environment IDs for tests: JTKit refuses one that isn't a UUID.
enum TestEnvironment {
    static let id = "e77c1408-10c8-4007-b177-abc9157fbcaa"
    static let source = "5c0a1e00-0000-4000-8000-00000000005c"
    static let destination = "d5700000-0000-4000-8000-0000000000d5"
}

extension JamfPlatform.Client {
    /// A gateway client on a fake session. It signs in at /auth/token with
    /// a fixed secret, records nothing unless given a log, and records waits
    /// instead of sleeping them; retries add no randomness.
    static func fake(environmentId: String = TestEnvironment.id,
                     session: URLSession,
                     writeSpacing: Duration = .zero,
                     sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }) -> JamfPlatform.Client {
        let recorder = RequestRecorder(session: session, log: nil)
        let tokens = JamfPlatform.TokenProvider(tokenURL: JamfRegion.us.gatewayURL.appending(path: "auth/token"),
                                       method: .apiClient(clientID: "id"), secret: { "secret" }, recorder: recorder)
        // the Environment IDs tests use are UUIDs, so this can't throw
        return try! JamfPlatform.Client(baseURL: JamfRegion.us.gatewayURL, scope: .environment(environmentId),
                                        tokens: tokens, recorder: recorder,
                                        writeSpacing: writeSpacing, sleep: sleep, random: { 0 })
    }

    /// A direct Jamf Pro client on a fake session, signing in at /api/oauth/token.
    static func fakeDirect(serverURL: URL = URL(string: "https://msp.jamfcloud.com")!,
                           session: URLSession) -> JamfPlatform.Client {
        let recorder = RequestRecorder(session: session, log: nil)
        let tokens = JamfPlatform.TokenProvider(tokenURL: serverURL.appending(path: "api/oauth/token"),
                                       method: .apiClient(clientID: "id"), secret: { "secret" }, recorder: recorder)
        return try! JamfPlatform.Client(baseURL: serverURL, scope: .organization, server: .jamfPro,
                                        tokens: tokens, recorder: recorder, sleep: { _ in }, random: { 0 })
    }
}
