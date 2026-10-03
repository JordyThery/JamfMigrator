//
//  PollAndProbeTests.swift
//  JamfMigratorTests
//

import Foundation
import Testing
@testable import JamfMigrator

struct PollTests {

    @Test func returnsOnceTheValueIsReady() async throws {
        let tries = Locked(0)
        let value = try await Poll.until("test value", timeout: .seconds(1), interval: .milliseconds(1)) {
            tries.withLock { $0 += 1 }
            return tries.value >= 3 ? "ready" : nil
        }
        #expect(value == "ready")
        #expect(tries.value == 3)
    }

    @Test func timesOut() async {
        await #expect {
            _ = try await Poll.until("never ready", timeout: .milliseconds(10), interval: .milliseconds(2)) {
                nil as String?
            }
        } throws: { error in
            guard case .pollTimeout(let what) = error as? GatewayError else { return false }
            return what == "never ready"
        }
    }
}

struct PermissionProbeTests {

    @Test func classifiesEachPath() async throws {
        let session = MockHTTP.session { request in
            switch request.url?.path {
            case "/auth/token":
                return MockHTTP.tokenJSON()
            case "/pro/v1/sites":
                return MockHTTP.Reply(status: 200, data: Data("{}".utf8))
            case "/pro/v1/engage":
                return MockHTTP.Reply(status: 403, data: Data(#"{"httpStatus":403,"errors":[{"code":"BAD_PERMISSIONS"}]}"#.utf8))
            default:
                return MockHTTP.Reply(status: 404)
            }
        }
        let provider = TokenProvider(
            credentials: { TokenProvider.Credentials(tokenURL: Region.us.tokenURL, clientId: "id", clientSecret: "secret") },
            session: session)
        let client = PlatformClient(region: .us, environmentId: "env-1", tokenProvider: provider, session: session)

        let probe = PermissionProbe(client: client)
        let results = await probe.check(paths: ["pro/v1/sites", "pro/v1/engage", "pro/v1/missing"])

        #expect(results["pro/v1/sites"] == .allowed)
        #expect(results["pro/v1/engage"] == .denied)
        #expect(results["pro/v1/missing"] == .failed(status: 404))
    }
}
