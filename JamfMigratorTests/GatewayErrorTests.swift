//
//  GatewayErrorTests.swift
//  JamfMigratorTests
//
//  The gateway answers with three different error body shapes; all of them
//  must come out as readable APIErrorDetails.
//

import Foundation
import Testing
@testable import JamfMigrator

struct GatewayErrorTests {

    @Test func decodesTheGatewayShape() {
        let body = Data(#"{"httpStatus":403,"traceId":"t-1","errors":[{"code":"BAD_PERMISSIONS","field":null,"description":"no access"}]}"#.utf8)
        guard case .response(let status, let errors, let traceId, _) = GatewayError.from(status: 403, body: body) else {
            Issue.record("expected .response")
            return
        }
        #expect(status == 403)
        #expect(traceId == "t-1")
        #expect(errors == [APIErrorDetail(code: "BAD_PERMISSIONS", field: nil, description: "no access")])
    }

    @Test func decodesTheBenchmarkShape() {
        let body = Data(#"{"message":"title already exists","error":"Conflict","statusCode":409,"logref":"log-9"}"#.utf8)
        guard case .response(let status, let errors, let traceId, _) = GatewayError.from(status: 409, body: body) else {
            Issue.record("expected .response")
            return
        }
        #expect(status == 409)
        #expect(traceId == "log-9")
        #expect(errors == [APIErrorDetail(code: "Conflict", field: nil, description: "title already exists")])
    }

    @Test func decodesThePrettyPrintedGatewayShape() {
        let body = Data("""
        {
            "httpStatus" : 422,
            "traceId" : "t-2",
            "errors" : [ {
                "code" : "HAS_DEPENDENCIES",
                "field" : null,
                "description" : "group is in use"
            } ]
        }
        """.utf8)
        guard case .response(_, let errors, let traceId, _) = GatewayError.from(status: 422, body: body) else {
            Issue.record("expected .response")
            return
        }
        #expect(traceId == "t-2")
        #expect(errors.first?.code == "HAS_DEPENDENCIES")
    }

    @Test func keepsAnUnknownBodyVerbatim() {
        let body = Data("upstream connect error".utf8)
        guard case .response(let status, let errors, let traceId, let raw) = GatewayError.from(status: 503, body: body) else {
            Issue.record("expected .response")
            return
        }
        #expect(status == 503)
        #expect(errors.isEmpty)
        #expect(traceId == nil)
        #expect(raw == body)
    }
}
