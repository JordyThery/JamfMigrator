//
//  PermissionCheckTests.swift
//  JamfMigratorTests
//
//  The pre-run check on JTKit's permission check: a missing permission is
//  reported apart from a list that isn't there and one that couldn't be
//  checked. (JTKit's own tests cover the poller.)
//

import Foundation
import Testing
import JTKit
@testable import JamfMigrator

struct PermissionCheckTests {

    private static let forbidden = MockHTTP.Reply(status: 403, data: MockHTTP.json(["httpStatus": 403, "errors": [["code": "BAD_PERMISSIONS"]]]))

    @Test func eachProblemIsReportedApart() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case (_, "GET", "/pro/v1/jamf-pro-version"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["version": "11.33.0"]))
            case ("src", "GET", "/pro/v1/buildings"), ("src", "GET", "/proclassic/policies"):
                return Self.forbidden
            case ("dst", "GET", "/pro/v1/departments"), ("dst", "GET", "/proclassic/policies"):
                return MockHTTP.Reply(status: 404)
            case ("dst", "GET", "/pro/v1/scripts"):
                return MockHTTP.Reply(status: 500, data: Data("boom".utf8))
            default:
                return nil
            }
        }

        let report = await Preflight.run(source: gateway.source, dest: gateway.dest,
                                         typeKeys: ["categories", "buildings", "departments", "scripts", "policies"])

        #expect(report.sourcePermissions["categories"] == .allowed)
        #expect(report.destinationPermissions["scripts"] == .failed(status: 500))
        // policies: forbidden on the source and missing on the destination
        // counts once, as a missing permission
        #expect(report.missingPermissionTypes == ["buildings", "policies"])
        #expect(report.notFoundTypes == ["departments"])
        #expect(report.uncheckedTypes == ["scripts"])
        #expect(report.flaggedTypes.count == 4)
        #expect(report.isReady)
        #expect(report.hasWarnings)
    }

    @Test func everyTypeAllowedFlagsNothing() async throws {
        let gateway = FakeGateway { _, method, path, _ in
            method == "GET" && path == "/pro/v1/jamf-pro-version"
                ? MockHTTP.Reply(status: 200, data: MockHTTP.json(["version": "11.33.0"]))
                : nil
        }

        let report = await Preflight.run(source: gateway.source, dest: gateway.dest, typeKeys: ["categories", "scripts"])

        #expect(report.flaggedTypes.isEmpty)
        #expect(!report.hasWarnings)
    }

    /// The same reads as before: each type's list, without paging parameters.
    @Test func checksReadEachListAsBefore() async throws {
        let seen = Locked([URLRequest]())
        let session = MockHTTP.session { request in
            if request.url?.path == "/auth/token" { return MockHTTP.tokenJSON() }
            seen.withLock { $0.append(request) }
            if request.url?.path == "/pro/v1/jamf-pro-version" {
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["version": "11.33.0"]))
            }
            return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 0, "results": []]))
        }
        let client = JamfPlatform.Client.fake(session: session)

        _ = await Preflight.run(source: client, dest: client, typeKeys: ["categories"])

        let checks = seen.value.filter { $0.url?.path == "/pro/v1/categories" && $0.url?.query == nil }
        // one check per tenant (the destination's count adds paged reads)
        #expect(checks.count == 2)
        #expect(seen.value.allSatisfy { $0.httpMethod == "GET" })
    }
}
