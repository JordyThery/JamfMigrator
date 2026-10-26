//
//  PlatformClientTests.swift
//  JamfMigratorTests
//

import Foundation
import Testing
import JTKit
@testable import JamfMigrator

/// A client against a fake gateway. `handler` answers API requests; the token
/// endpoint is served automatically. Sleeps are recorded, not slept.
private struct Harness {
    let client: JamfPlatform.Client
    let apiRequests: Locked<[URLRequest]>
    let tokenRequestCount: Locked<Int>
    let sleeps: Locked<[Duration]>

    init(environmentId: String = TestEnvironment.id, handler: @escaping MockHTTP.Handler) {
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
        // the app's usual spacing between writes, so the throttle test sees it
        self.client = JamfPlatform.Client.fake(environmentId: environmentId,
                                          session: session,
                                          writeSpacing: JamfPlatform.Client.defaultWriteSpacing,
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
        #expect(request.value(forHTTPHeaderField: "X-Environment-Id") == TestEnvironment.id)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    /// JTKit's User-Agent, the same text the app sent itself before.
    @Test func requestsSayWhichAppSentThem() async throws {
        let harness = Harness { _ in MockHTTP.Reply(status: 200, data: Data("{}".utf8)) }
        _ = try await harness.client.send(.get, "pro/v1/sites")

        let request = try #require(harness.apiRequests.value.first)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "JamfMigrator/\(version)")
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
        } throws: { ($0 as? JamfPlatformError)?.status == 401 }
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
        } throws: { ($0 as? JamfPlatformError)?.status == 502 }
        #expect(postCalls.value == 1)

        // PUT replaces a whole record, so it is safe to send again
        let putCalls = Locked(0)
        let putHarness = Harness { _ in
            putCalls.withLock { $0 += 1 }
            return putCalls.value < 2
                ? MockHTTP.Reply(status: 503)
                : MockHTTP.Reply(status: 200, data: Data("{}".utf8))
        }
        _ = try await putHarness.client.send(.put, "pro/v1/buildings/1", body: Data("{}".utf8))
        #expect(putCalls.value == 2)
    }

    /// JTKit follows a redirect only to HTTPS on the same host; the
    /// gateway's internal hosts are never reached.
    @Test func redirectsToAnotherHostAreNotFollowed() async throws {
        let harness = Harness { request in
            request.url?.path == "/elsewhere"
                ? MockHTTP.Reply(status: 200, data: Data("{}".utf8))
                : MockHTTP.Reply(status: 302, headers: ["Location": "https://internal.example/elsewhere"])
        }
        await #expect {
            _ = try await harness.client.send(.get, "pro/v1/sites")
        } throws: { ($0 as? JamfPlatformError)?.status == 302 }
        #expect(harness.apiRequests.value.count == 1)
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
            guard let error = error as? JamfPlatformError else { return false }
            return error.status == 400 && error.traceID == "abc123"
                && error.body?.errors == [.init(code: "INVALID_FIELD", field: "name", description: "must not be blank")]
                && error.message().contains("INVALID_FIELD (name): must not be blank")
        }
    }
}
