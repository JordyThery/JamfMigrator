//
//  FakeGateway.swift
//  JamfMigratorTests
//
//  A fake two-tenant gateway for engine and planner tests. The handler
//  routes source vs destination tenant by the X-Environment-Id header,
//  passing it to handlers as "src" or "dst".
//

import Foundation
import JTKit
@testable import JamfMigrator

/// A fake two-tenant gateway. Unhandled list paths return empty lists so the
/// engine's dependency lookups always succeed.
struct FakeGateway {
    let source: JamfPlatform.Client
    let dest: JamfPlatform.Client
    let requests: Locked<[(env: String, method: String, path: String, body: Data?)]>

    init(handler: @escaping @Sendable (_ env: String, _ method: String, _ path: String, _ body: Data?) -> MockHTTP.Reply?) {
        let requests = Locked<[(env: String, method: String, path: String, body: Data?)]>([])
        let session = MockHTTP.session { request in
            let path = request.url?.path ?? ""
            if path == "/auth/token" { return MockHTTP.tokenJSON() }
            let env = switch request.value(forHTTPHeaderField: "X-Environment-Id") {
            case TestEnvironment.source?: "src"
            case TestEnvironment.destination?: "dst"
            default: ""
            }
            let method = request.httpMethod ?? ""
            let body = request.bodyData
            requests.withLock { $0.append((env, method, path, body)) }
            if let reply = handler(env, method, path, body) { return reply }
            // default: empty lists in the right shape
            if method == "GET" && path.hasPrefix("/proclassic/") {
                return MockHTTP.Reply(status: 200, data: Data("{}".utf8))
            }
            if method == "GET" {
                // pro and platform namespaces share the paginated list shape
                return MockHTTP.Reply(status: 200, data: Data(#"{"totalCount":0,"results":[]}"#.utf8))
            }
            return MockHTTP.Reply(status: 404)
        }
        self.source = JamfPlatform.Client.fake(environmentId: TestEnvironment.source, session: session)
        self.dest = JamfPlatform.Client.fake(environmentId: TestEnvironment.destination, session: session)
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
