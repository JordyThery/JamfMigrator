//
//  FakeGateway.swift
//  JamfMigratorTests
//
//  A fake two-tenant gateway for engine and planner tests. The handler
//  routes source vs destination tenant by the X-Environment-Id header.
//

import Foundation
@testable import JamfMigrator

/// A fake two-tenant gateway. Unhandled list paths return empty lists so the
/// engine's dependency lookups always succeed.
struct FakeGateway {
    let source: PlatformClient
    let dest: PlatformClient
    let requests: Locked<[(env: String, method: String, path: String, body: Data?)]>

    init(handler: @escaping @Sendable (_ env: String, _ method: String, _ path: String, _ body: Data?) -> MockHTTP.Reply?) {
        let requests = Locked<[(env: String, method: String, path: String, body: Data?)]>([])
        let session = MockHTTP.session { request in
            let path = request.url?.path ?? ""
            if path == "/auth/token" { return MockHTTP.tokenJSON() }
            let env = request.value(forHTTPHeaderField: "X-Environment-Id") ?? ""
            let method = request.httpMethod ?? ""
            let body = request.bodyData
            requests.withLock { $0.append((env, method, path, body)) }
            if let reply = handler(env, method, path, body) { return reply }
            // default: empty lists in the right shape
            if method == "GET" && path.hasPrefix("/proclassic/") {
                return MockHTTP.Reply(status: 200, data: Data("{}".utf8))
            }
            if method == "GET" && path.hasPrefix("/pro/") {
                return MockHTTP.Reply(status: 200, data: Data(#"{"totalCount":0,"results":[]}"#.utf8))
            }
            return MockHTTP.Reply(status: 404)
        }
        let makeClient = { (env: String) in
            PlatformClient(region: .us, environmentId: env,
                           tokenProvider: TokenProvider(
                               credentials: { TokenProvider.Credentials(tokenURL: Region.us.tokenURL, clientId: "id", clientSecret: "s") },
                               session: session),
                           session: session,
                           configuration: .init(writeInterval: .zero))
        }
        self.source = makeClient("src")
        self.dest = makeClient("dst")
        self.requests = requests
    }

    func writes(to env: String) -> [(method: String, path: String, body: Data?)] {
        requests.value.filter { $0.env == env && $0.method != "GET" }.map { ($0.method, $0.path, $0.body) }
    }
}

func makeJournal(mode: RunMode = .copy) -> JournalStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("EngineTests-\(UUID().uuidString).json")
    return JournalStore(url: url, mode: mode)
}
