//
//  PlatformClientTests.swift
//  JamfMigratorTests
//

import Foundation
import Testing
@testable import JamfMigrator

/// A client against a fake gateway. `handler` answers API requests; the token
/// endpoint is served automatically. Sleeps are recorded, not slept.
private struct Harness {
    let client: PlatformClient
    let apiRequests: Locked<[URLRequest]>
    let tokenRequestCount: Locked<Int>
    let sleeps: Locked<[Duration]>

    init(environmentId: String = "env-1", handler: @escaping MockHTTP.Handler) {
        let apiRequests = Locked<[URLRequest]>([])
        let tokenRequestCount = Locked(0)
        let sleeps = Locked<[Duration]>([])
        let session = MockHTTP.session { request in
            if request.url?.path == "/auth/token" {
                tokenRequestCount.withLock { $0 += 1 }
                return MockHTTP.tokenJSON("tok-\(tokenRequestCount.value)")
            }
            apiRequests.withLock { $0.append(request) }
            return try handler(request)
        }
        let provider = TokenProvider(
            credentials: { TokenProvider.Credentials(tokenURL: Region.us.tokenURL, clientId: "id", clientSecret: "secret") },
            session: session)
        self.client = PlatformClient(region: .us,
                                     environmentId: environmentId,
                                     tokenProvider: provider,
                                     session: session,
                                     sleep: { duration in sleeps.withLock { $0.append(duration) } })
        self.apiRequests = apiRequests
        self.tokenRequestCount = tokenRequestCount
        self.sleeps = sleeps
    }
}

struct PlatformClientTests {

    @Test func proRequestsSendJSONHeadersAndEnvironmentId() async throws {
        let harness = Harness { _ in MockHTTP.Reply(status: 200, data: Data("{}".utf8)) }
        _ = try await harness.client.send(.get, "/pro/v1/jamf-pro-version")

        let request = try #require(harness.apiRequests.value.first)
        #expect(request.url?.absoluteString == "https://us.api.jamfcloud.com/pro/v1/jamf-pro-version")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-1")
        #expect(request.value(forHTTPHeaderField: "X-Environment-Id") == "env-1")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func classicRequestsSpeakXML() async throws {
        let harness = Harness { _ in MockHTTP.Reply(status: 201, data: Data("<category><id>26</id></category>".utf8)) }
        _ = try await harness.client.send(.post, "proclassic/categories/id/0",
                                          body: Data("<category><name>JM-TEST</name></category>".utf8))

        let request = try #require(harness.apiRequests.value.first)
        #expect(request.url?.path == "/proclassic/categories/id/0")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/xml")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/xml")
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
    }

    @Test func unauthorizedRefreshesTheTokenOnce() async throws {
        let apiCalls = Locked(0)
        let harness = Harness { _ in
            apiCalls.withLock { $0 += 1 }
            return apiCalls.value == 1
                ? MockHTTP.Reply(status: 401)
                : MockHTTP.Reply(status: 200, data: Data("{}".utf8))
        }
        let response = try await harness.client.send(.get, "pro/v1/sites")

        #expect(response.status == 200)
        #expect(harness.tokenRequestCount.value == 2)
        #expect(harness.apiRequests.value.last?.value(forHTTPHeaderField: "Authorization") == "Bearer tok-2")
    }

    @Test func persistentUnauthorizedThrows() async throws {
        let harness = Harness { _ in MockHTTP.Reply(status: 401) }
        await #expect {
            _ = try await harness.client.send(.get, "pro/v1/sites")
        } throws: { ($0 as? GatewayError)?.status == 401 }
        // one refresh attempt, then give up
        #expect(harness.apiRequests.value.count == 2)
    }

    @Test func tooManyRequestsHonorsRetryAfter() async throws {
        let apiCalls = Locked(0)
        let harness = Harness { _ in
            apiCalls.withLock { $0 += 1 }
            return apiCalls.value == 1
                ? MockHTTP.Reply(status: 429, headers: ["Retry-After": "3"])
                : MockHTTP.Reply(status: 200, data: Data("{}".utf8))
        }
        _ = try await harness.client.send(.get, "pro/v2/groups")

        #expect(harness.sleeps.value.contains(.seconds(3)))
        #expect(apiCalls.value == 2)
    }

    @Test func serverErrorsRetryOnlyIdempotentMethods() async throws {
        let getCalls = Locked(0)
        let getHarness = Harness { _ in
            getCalls.withLock { $0 += 1 }
            return getCalls.value < 3
                ? MockHTTP.Reply(status: 502)
                : MockHTTP.Reply(status: 200, data: Data("{}".utf8))
        }
        let response = try await getHarness.client.send(.get, "pro/v1/buildings")
        #expect(response.status == 200)
        #expect(getCalls.value == 3)

        let postCalls = Locked(0)
        let postHarness = Harness { _ in
            postCalls.withLock { $0 += 1 }
            return MockHTTP.Reply(status: 502)
        }
        await #expect {
            _ = try await postHarness.client.send(.post, "pro/v1/buildings", body: Data("{}".utf8))
        } throws: { ($0 as? GatewayError)?.status == 502 }
        #expect(postCalls.value == 1)
    }

    @Test func writesAreThrottled() async throws {
        let harness = Harness { _ in MockHTTP.Reply(status: 201, data: Data("{}".utf8)) }
        _ = try await harness.client.send(.post, "pro/v1/buildings", body: Data("{}".utf8))
        _ = try await harness.client.send(.post, "pro/v1/buildings", body: Data("{}".utf8))

        // the second write waits out the remainder of the write interval
        #expect(harness.sleeps.value.count == 1)
        if let delay = harness.sleeps.value.first {
            #expect(delay > .zero && delay <= .milliseconds(200))
        }
    }

    @Test func gatewayErrorBodyIsDecoded() async throws {
        let body = """
        {"httpStatus": 400, "traceId": "abc123", "errors": [
            {"code": "INVALID_FIELD", "field": "name", "description": "must not be blank"}
        ]}
        """
        let harness = Harness { _ in MockHTTP.Reply(status: 400, data: Data(body.utf8)) }

        await #expect {
            _ = try await harness.client.send(.post, "pro/v1/buildings", body: Data("{}".utf8))
        } throws: { error in
            guard case .response(let status, let errors, let traceId, _) = error as? GatewayError else { return false }
            return status == 400 && traceId == "abc123"
                && errors == [APIErrorDetail(code: "INVALID_FIELD", field: "name", description: "must not be blank")]
        }
    }
}
