//
//  EngineTests.swift
//  JamfMigratorTests
//
//  MigrationEngine and DeleteEngine against a fake gateway. The handler
//  routes source vs destination tenant by the X-Environment-Id header.
//

import Foundation
import Testing
@testable import JamfMigrator

struct MigrationEngineTests {

    @Test func createsACategoryAndAPolicyWithRemappedReferences() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(
                    ["totalCount": 1, "results": [["id": "5", "name": "Utilities"]]]))
            case ("src", "GET", "/pro/v1/categories/5"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "5", "name": "Utilities", "priority": 9]))
            case ("dst", "POST", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 201, data: MockHTTP.json(["id": "77", "href": "https://internal"]))
            case ("src", "GET", "/proclassic/policies"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["policies": [["id": 10, "name": "Install Chrome"]]]))
            case ("src", "GET", "/proclassic/policies/id/10"):
                return MockHTTP.Reply(status: 200, data: Data("<policy><general><id>10</id><name>Install Chrome</name></general></policy>".utf8))
            case ("dst", "POST", "/proclassic/policies/id/0"):
                return MockHTTP.Reply(status: 201, data: Data("<policy><id>31</id></policy>".utf8))
            default:
                return nil
            }
        }

        let journal = makeJournal()
        let engine = MigrationEngine(source: gateway.source, dest: gateway.dest, journal: journal)
        let report = await engine.migrate(typeKeys: ["categories", "policies"])

        #expect(report.entries.count == 2)
        #expect(report.entries(for: "categories").first?.status == .created(destId: "77"))
        #expect(report.entries(for: "policies").first?.status == .created(destId: "31"))
        #expect(await journal.destId(type: "categories", sourceId: "5") == "77")
        #expect(await journal.destId(type: "policies", sourceId: "10") == "31")

        let writes = gateway.writes(to: "dst")
        #expect(writes.map(\.path) == ["/pro/v1/categories", "/proclassic/policies/id/0"])
        // the policy body went out as XML with the id stripped
        let policyBody = String(decoding: writes.last?.body ?? Data(), as: UTF8.self)
        #expect(!policyBody.contains("<id>"))
        #expect(policyBody.contains("Install Chrome"))
    }

    @Test func matchesByNameAndUpdates() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(
                    ["totalCount": 1, "results": [["id": "5", "name": "Utilities"]]]))
            case ("dst", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(
                    ["totalCount": 1, "results": [["id": "70", "name": "Utilities"]]]))
            case ("src", "GET", "/pro/v1/categories/5"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "5", "name": "Utilities"]))
            case ("dst", "PUT", "/pro/v1/categories/70"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "70"]))
            default:
                return nil
            }
        }

        let journal = makeJournal()
        let engine = MigrationEngine(source: gateway.source, dest: gateway.dest, journal: journal)
        let report = await engine.migrate(typeKeys: ["categories"])

        #expect(report.entries.first?.status == .updated(destId: "70"))
        #expect(gateway.writes(to: "dst").map { "\($0.method) \($0.path)" } == ["PUT /pro/v1/categories/70"])
    }

    @Test func resumeSkipsFinishedObjects() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(
                    ["totalCount": 1, "results": [["id": "5", "name": "Utilities"]]]))
            default:
                return nil
            }
        }

        let journal = makeJournal()
        await journal.record(type: "categories", objectId: "5", status: .created(destId: "77"))
        let engine = MigrationEngine(source: gateway.source, dest: gateway.dest, journal: journal)
        let report = await engine.migrate(typeKeys: ["categories"])

        #expect(report.entries.first?.status == .created(destId: "77"))
        #expect(gateway.writes(to: "dst").isEmpty)
    }

    @Test func blockedObjectsAreReportedNotWritten() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/proclassic/classes"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["classes": [["id": 3, "name": "Math"]]]))
            case ("src", "GET", "/proclassic/classes/id/3"):
                return MockHTTP.Reply(status: 200, data: Data("<class><name>Math</name><source>Apple School Manager</source></class>".utf8))
            default:
                return nil
            }
        }

        let journal = makeJournal()
        let engine = MigrationEngine(source: gateway.source, dest: gateway.dest, journal: journal)
        let report = await engine.migrate(typeKeys: ["classes"])

        guard case .blocked(let reason)? = report.entries.first?.status else {
            Issue.record("expected .blocked, got \(String(describing: report.entries.first))")
            return
        }
        #expect(reason.contains("Apple School Manager"))
        #expect(gateway.writes(to: "dst").isEmpty)
    }

    @Test func copiesTheSelfServiceIcon() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/proclassic/policies"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["policies": [["id": 10, "name": "Chrome"]]]))
            case ("src", "GET", "/proclassic/policies/id/10"):
                return MockHTTP.Reply(status: 200, data: Data("""
                <policy><general><id>10</id><name>Chrome</name></general>\
                <self_service><self_service_icon><id>66</id><filename>chrome.png</filename>\
                <uri>https://src/iconservlet?id=66</uri></self_service_icon></self_service></policy>
                """.utf8))
            case ("dst", "POST", "/proclassic/policies/id/0"):
                return MockHTTP.Reply(status: 201, data: Data("<policy><id>31</id></policy>".utf8))
            case ("src", "GET", "/pro/v1/icon/download/66"):
                return MockHTTP.Reply(status: 200, data: Data([0x89, 0x50, 0x4E, 0x47]))
            case ("dst", "POST", "/pro/v1/icon"):
                return MockHTTP.Reply(status: 201, data: MockHTTP.json(["id": 9, "url": "https://dst/icon/9"]))
            case ("dst", "PUT", "/proclassic/policies/id/31"):
                return MockHTTP.Reply(status: 200, data: Data("<policy><id>31</id></policy>".utf8))
            default:
                return nil
            }
        }

        let journal = makeJournal()
        let engine = MigrationEngine(source: gateway.source, dest: gateway.dest, journal: journal)
        let report = await engine.migrate(typeKeys: ["policies"])

        #expect(report.entries.first?.status == .created(destId: "31"))
        let writes = gateway.writes(to: "dst").map { "\($0.method) \($0.path)" }
        #expect(writes == ["POST /proclassic/policies/id/0", "POST /pro/v1/icon", "PUT /proclassic/policies/id/31"])
        // the follow-up PUT points the policy at the new icon id
        let assignBody = String(decoding: gateway.writes(to: "dst").last?.body ?? Data(), as: UTF8.self)
        #expect(assignBody.contains("<self_service_icon><id>9</id></self_service_icon>"))
    }
}

struct DeleteEngineTests {

    @Test func deletesInReverseOrderSkipsBuiltInsAndRetriesDependencies() async throws {
        let groupDeleteCount = Locked(0)
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("dst", "GET", "/pro/v3/computer-groups/smart-groups"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 2, "results": [
                    ["id": "1", "name": "All Managed Clients"],
                    ["id": "12", "name": "All Laptops"],
                ]]))
            case ("dst", "DELETE", "/pro/v3/computer-groups/smart-groups/12"):
                groupDeleteCount.withLock { $0 += 1 }
                if groupDeleteCount.value == 1 {
                    return MockHTTP.Reply(status: 422, data: MockHTTP.json(
                        ["httpStatus": 422, "errors": [["code": "HAS_DEPENDENCIES"]]]))
                }
                return MockHTTP.Reply(status: 204)
            case ("dst", "GET", "/proclassic/policies"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["policies": [["id": 31, "name": "Chrome"]]]))
            case ("dst", "DELETE", "/proclassic/policies/id/31"):
                return MockHTTP.Reply(status: 200, data: Data("<policy><id>31</id></policy>".utf8))
            default:
                return nil
            }
        }

        let journal = makeJournal(mode: .delete)
        let engine = DeleteEngine(client: gateway.dest, journal: journal)
        let report = await engine.delete(typeKeys: ["policies", "smartcomputergroups"])

        // policies (step 8) delete before groups (step 6); the built-in group
        // is reported as kept, never touched; the held group succeeds on retry
        let deletes = gateway.requests.value.filter { $0.method == "DELETE" }.map(\.path)
        #expect(deletes == ["/proclassic/policies/id/31",
                            "/pro/v3/computer-groups/smart-groups/12",
                            "/pro/v3/computer-groups/smart-groups/12"])
        #expect(report.entries.filter { $0.status == .deleted }.count == 2)
        #expect(report.entries.contains { $0.status == .blocked(reason: "Built-in object") })
        #expect(report.entries.count == 3)
    }

    @Test func classicMisleading400IsVerifiedWithAGet() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("dst", "GET", "/proclassic/sites"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["sites": [["id": 4, "name": "HQ"]]]))
            case ("dst", "DELETE", "/proclassic/sites/id/4"):
                return MockHTTP.Reply(status: 400, data: Data("Bad Request".utf8))
            case ("dst", "GET", "/proclassic/sites/id/4"):
                return MockHTTP.Reply(status: 404)
            default:
                return nil
            }
        }

        let journal = makeJournal(mode: .delete)
        let engine = DeleteEngine(client: gateway.dest, journal: journal)
        let report = await engine.delete(typeKeys: ["sites"])

        #expect(report.entries.first?.status == .deleted)
    }
}

struct RunJournalTests {

    @Test func journalRoundTripsForResume() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalTest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = JournalStore(url: url, mode: .copy)
        await first.record(type: "categories", objectId: "5", status: .created(destId: "77"))
        await first.record(type: "policies", objectId: "10", status: .failed(reason: "boom"))

        let resumed = JournalStore(url: url, mode: .copy)
        #expect(await resumed.status(type: "categories", objectId: "5") == .created(destId: "77"))
        #expect(await resumed.status(type: "policies", objectId: "10") == .failed(reason: "boom"))
        #expect(await resumed.destId(type: "categories", sourceId: "5") == "77")

        // a different mode starts fresh
        let wipeJournal = JournalStore(url: url, mode: .delete)
        #expect(await wipeJournal.status(type: "categories", objectId: "5") == nil)
    }
}
