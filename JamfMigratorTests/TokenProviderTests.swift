//
//  TokenProviderTests.swift
//  JamfMigratorTests
//

import Foundation
import Testing
@testable import JamfMigrator

private let tokenURL = URL(string: "https://us.api.jamfcloud.com/auth/token")!

private func makeCredentials() -> TokenProvider.Credentials {
    TokenProvider.Credentials(tokenURL: tokenURL, clientId: "client-id", clientSecret: "client-secret")
}

struct TokenProviderTests {

    @Test func fetchesAndCachesToken() async throws {
        let requestCount = Locked(0)
        let session = MockHTTP.session { _ in
            requestCount.withLock { $0 += 1 }
            return MockHTTP.tokenJSON("tok-1")
        }
        let provider = TokenProvider(credentials: { makeCredentials() }, session: session)

        #expect(try await provider.validToken() == "tok-1")
        #expect(try await provider.validToken() == "tok-1")
        #expect(requestCount.value == 1)
    }

    @Test func sendsClientCredentialsForm() async throws {
        let seenBody = Locked<String?>(nil)
        let seenContentType = Locked<String?>(nil)
        let session = MockHTTP.session { request in
            seenBody.value = request.bodyData.flatMap { String(data: $0, encoding: .utf8) }
            seenContentType.value = request.value(forHTTPHeaderField: "Content-Type")
            return MockHTTP.tokenJSON()
        }
        let provider = TokenProvider(credentials: { makeCredentials() }, session: session)
        _ = try await provider.validToken()

        let body = try #require(seenBody.value)
        #expect(body.contains("grant_type=client_credentials"))
        #expect(body.contains("client_id=client-id"))
        #expect(body.contains("client_secret=client-secret"))
        #expect(seenContentType.value == "application/x-www-form-urlencoded")
    }

    @Test func refreshesAtEightyPercentOfLifetime() async throws {
        let requestCount = Locked(0)
        let session = MockHTTP.session { _ in
            requestCount.withLock { $0 += 1 }
            return MockHTTP.tokenJSON("tok-\(requestCount.value)", expiresIn: 900)
        }
        let clock = Locked(Date(timeIntervalSinceReferenceDate: 0))
        let provider = TokenProvider(credentials: { makeCredentials() },
                                     session: session,
                                     now: { clock.value })

        #expect(try await provider.validToken() == "tok-1")

        // 10 minutes in: 900 * 0.8 = 720 s has not passed, keep the cached token
        clock.value = Date(timeIntervalSinceReferenceDate: 600)
        #expect(try await provider.validToken() == "tok-1")

        // 13 minutes in: past 80% of the lifetime, fetch a new one
        clock.value = Date(timeIntervalSinceReferenceDate: 780)
        #expect(try await provider.validToken() == "tok-2")
        #expect(requestCount.value == 2)
    }

    @Test func concurrentCallersShareOneFetch() async throws {
        let requestCount = Locked(0)
        let session = MockHTTP.session { _ in
            requestCount.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.05)
            return MockHTTP.tokenJSON()
        }
        let provider = TokenProvider(credentials: { makeCredentials() }, session: session)

        async let first = provider.validToken()
        async let second = provider.validToken()
        _ = try await (first, second)
        #expect(requestCount.value == 1)
    }

    @Test func invalidateForcesANewToken() async throws {
        let requestCount = Locked(0)
        let session = MockHTTP.session { _ in
            requestCount.withLock { $0 += 1 }
            return MockHTTP.tokenJSON("tok-\(requestCount.value)")
        }
        let provider = TokenProvider(credentials: { makeCredentials() }, session: session)

        #expect(try await provider.validToken() == "tok-1")
        await provider.invalidate()
        #expect(try await provider.validToken() == "tok-2")
    }

    @Test func badCredentialsThrowTokenFailure() async throws {
        let session = MockHTTP.session { _ in
            MockHTTP.Reply(status: 401, data: Data(#"{"error":"unauthorized_client"}"#.utf8))
        }
        let provider = TokenProvider(credentials: { makeCredentials() }, session: session)

        await #expect {
            _ = try await provider.validToken()
        } throws: { error in
            guard case .tokenFailure(let status, let detail) = error as? GatewayError else { return false }
            return status == 401 && detail?.contains("unauthorized_client") == true
        }
    }
}
