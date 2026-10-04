//
//  MockHTTP.swift
//  JamfMigratorTests
//
//  A URLProtocol-based fake server. Each session gets its own handler, keyed
//  through an X-Mock-Id header, so tests can run in parallel.
//

import Foundation

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
