//
//  PlannerTests.swift
//  JamfMigratorTests
//

import Foundation
import Testing
@testable import JamfMigrator

struct PayloadDiffTests {

    @Test func xmlBecomesANestedDictionary() {
        let xml = """
        <policy><general><name>Chrome</name><enabled>true</enabled></general>\
        <scope><computer_group><name>A</name></computer_group><computer_group><name>B</name></computer_group></scope></policy>
        """
        let dict = XMLDictionary.parse(xml)
        let policy = dict["policy"] as? [String: Any]
        let general = policy?["general"] as? [String: Any]
        #expect(general?["name"] as? String == "Chrome")
        let scope = policy?["scope"] as? [String: Any]
        let groups = scope?["computer_group"] as? [Any]
        #expect(groups?.count == 2)
    }

    @Test func identicalPayloadsHaveNoDiff() {
        let a: [String: Any] = ["name": "X", "nested": ["enabled": true], "list": ["1", "2"]]
        let b: [String: Any] = ["name": "X", "nested": ["enabled": true], "list": ["1", "2"]]
        #expect(PayloadDiff.diff(source: a, destination: b).isEmpty)
    }

    @Test func differencesCarryThePathAndBothValues() {
        let a: [String: Any] = ["general": ["name": "Chrome", "frequency": "Once per day"]]
        let b: [String: Any] = ["general": ["name": "Chrome", "frequency": "Ongoing", "extra": "field"]]
        let diff = PayloadDiff.diff(source: a, destination: b)
        #expect(diff.contains(DiffEntry(path: "general/frequency", source: "Once per day", destination: "Ongoing")))
        #expect(diff.contains(DiffEntry(path: "general/extra", source: nil, destination: "field")))
        #expect(diff.count == 2)
    }

    @Test func arrayCountDifferencesAreReported() {
        let a: [String: Any] = ["list": ["1"]]
        let b: [String: Any] = ["list": ["1", "2"]]
        let diff = PayloadDiff.diff(source: a, destination: b)
        #expect(diff == [DiffEntry(path: "list#count", source: "1", destination: "2")])
    }

    @Test func emptyStringsCompareEqualToMissingFields() {
        // Jamf normalizes absent fields to "" on the destination (verified
        // live 2026-10-04: package manifest fields)
        let a: [String: Any] = ["name": "X"]
        let b: [String: Any] = ["name": "X", "manifest": "", "note": NSNull()]
        #expect(PayloadDiff.diff(source: a, destination: b).isEmpty)
    }
}

struct MigrationPlannerTests {

    /// src has two categories; dst already has one of them identical and the
    /// other doesn't exist → one Unchanged, one Create. Nothing is written.
    @Test func createAndUnchangedOutcomes() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 2, "results": [
                    ["id": "5", "name": "Utilities"], ["id": "6", "name": "Browsers"]]]))
            case ("dst", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 1, "results": [
                    ["id": "70", "name": "Utilities"]]]))
            case ("src", "GET", "/pro/v1/categories/5"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "5", "name": "Utilities", "priority": 9]))
            case ("src", "GET", "/pro/v1/categories/6"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "6", "name": "Browsers", "priority": 9]))
            case ("dst", "GET", "/pro/v1/categories/70"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "70", "name": "Utilities", "priority": 9]))
            default:
                return nil
            }
        }

        let planner = MigrationPlanner(source: gateway.source, dest: gateway.dest)
        let plan = await planner.plan(typeKeys: ["categories"])

        #expect(plan.entries.count == 2)
        #expect(plan.entries.first { $0.name == "Utilities" }?.change == .unchanged(destId: "70"))
        #expect(plan.entries.first { $0.name == "Browsers" }?.change == .create)
        #expect(gateway.writes(to: "dst").isEmpty)
        #expect(gateway.writes(to: "src").isEmpty)
    }

    @Test func updateCarriesAStructuralDiff() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 1, "results": [["id": "5", "name": "Utilities"]]]))
            case ("dst", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 1, "results": [["id": "70", "name": "Utilities"]]]))
            case ("src", "GET", "/pro/v1/categories/5"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "5", "name": "Utilities", "priority": 3]))
            case ("dst", "GET", "/pro/v1/categories/70"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "70", "name": "Utilities", "priority": 9]))
            default:
                return nil
            }
        }

        let planner = MigrationPlanner(source: gateway.source, dest: gateway.dest)
        let plan = await planner.plan(typeKeys: ["categories"])

        guard case .update(let destId) = plan.entries.first?.change else {
            Issue.record("expected .update, got \(String(describing: plan.entries.first))")
            return
        }
        #expect(destId == "70")
        #expect(plan.entries.first?.diff == [DiffEntry(path: "priority", source: "3", destination: "9")])
    }

    @Test func classicUpdateDiffIsStructuralToo() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/proclassic/policies"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["policies": [["id": 10, "name": "Chrome"]]]))
            case ("dst", "GET", "/proclassic/policies"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["policies": [["id": 31, "name": "Chrome"]]]))
            case ("src", "GET", "/proclassic/policies/id/10"):
                return MockHTTP.Reply(status: 200, data: Data("<policy><general><id>10</id><name>Chrome</name><enabled>true</enabled></general></policy>".utf8))
            case ("dst", "GET", "/proclassic/policies/id/31"):
                return MockHTTP.Reply(status: 200, data: Data("<policy><general><id>31</id><name>Chrome</name><enabled>false</enabled></general></policy>".utf8))
            default:
                return nil
            }
        }

        let planner = MigrationPlanner(source: gateway.source, dest: gateway.dest)
        let plan = await planner.plan(typeKeys: ["policies"])

        #expect(plan.entries.first?.change == .update(destId: "31"))
        #expect(plan.entries.first?.diff == [DiffEntry(path: "policy/general/enabled", source: "true", destination: "false")])
    }

    @Test func duplicateDestinationNamesAreBlocked() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 1, "results": [["id": "5", "name": "Utilities"]]]))
            case ("dst", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 2, "results": [
                    ["id": "70", "name": "Utilities"], ["id": "71", "name": "Utilities"]]]))
            default:
                return nil
            }
        }

        let planner = MigrationPlanner(source: gateway.source, dest: gateway.dest)
        let plan = await planner.plan(typeKeys: ["categories"])

        guard case .blocked(let reason) = plan.entries.first?.change else {
            Issue.record("expected .blocked")
            return
        }
        #expect(reason.contains("More than one"))
    }

    /// A patch policy whose title is missing on dst but planned in the same
    /// run is not Blocked — the run creates the title first.
    @Test func dependenciesPlannedInTheSameRunUnblock() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/pro/v3/patch-software-title-configurations"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 1, "results": [["id": "5", "displayName": "Google Chrome"]]]))
            case ("src", "GET", "/pro/v3/patch-software-title-configurations/5"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "5", "displayName": "Google Chrome", "softwareTitleId": "10"]))
            case ("src", "GET", "/proclassic/patchpolicies"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["patch_policies": [["id": 2, "name": "Chrome Stable"]]]))
            case ("src", "GET", "/proclassic/patchpolicies/id/2"):
                return MockHTTP.Reply(status: 200, data: Data("<patch_policy><general><id>2</id><name>Chrome Stable</name></general><software_title_configuration_id>5</software_title_configuration_id></patch_policy>".utf8))
            default:
                return nil
            }
        }

        let planner = MigrationPlanner(source: gateway.source, dest: gateway.dest)
        let plan = await planner.plan(typeKeys: ["patchsoftwaretitles", "patchpolicies"])

        #expect(plan.entries(for: "patchsoftwaretitles").first?.change == .create)
        #expect(plan.entries(for: "patchpolicies").first?.change == .create)

        // without the title in the run, the policy is Blocked
        let plannerWithoutTitle = MigrationPlanner(source: gateway.source, dest: gateway.dest)
        let planWithout = await plannerWithoutTitle.plan(typeKeys: ["patchpolicies"])
        guard case .blocked = planWithout.entries.first?.change else {
            Issue.record("expected .blocked without the title in the run")
            return
        }
    }

    @Test func deletePlanListsRemovalsAndKeepsBuiltIns() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("dst", "GET", "/pro/v3/computer-groups/smart-groups"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 2, "results": [
                    ["id": "1", "name": "All Managed Clients"], ["id": "12", "name": "All Laptops"]]]))
            case ("dst", "GET", "/proclassic/policies"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["policies": [["id": 31, "name": "Chrome"]]]))
            default:
                return nil
            }
        }

        let planner = MigrationPlanner(source: gateway.source, dest: gateway.dest)
        let plan = await planner.planDeletion(typeKeys: ["policies", "smartcomputergroups"])

        // deletion order: policies (step 8) before groups (step 6)
        #expect(plan.entries.map(\.name) == ["Chrome", "All Managed Clients", "All Laptops"])
        #expect(plan.entries[0].change == .delete)
        #expect(plan.entries[1].change == .keep(reason: "Built-in object"))
        #expect(plan.entries[2].change == .delete)
        #expect(plan.changeCount == 2)
        #expect(gateway.writes(to: "dst").isEmpty)
    }
}

struct PreflightTests {

    @Test func reportsVersionsPermissionsAndCounts() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case (_, "GET", "/pro/v1/jamf-pro-version"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["version": env == "src" ? "11.32.0" : "11.33.0"]))
            case ("src", "GET", "/pro/v1/categories"), ("dst", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 1, "results": [["id": "1", "name": "X"]]]))
            case (_, "GET", "/proclassic/policies"):
                return MockHTTP.Reply(status: 403, data: MockHTTP.json(["httpStatus": 403, "errors": [["code": "BAD_PERMISSIONS"]]]))
            default:
                return nil
            }
        }

        let report = await Preflight.run(source: gateway.source, dest: gateway.dest,
                                         typeKeys: ["categories", "policies"])

        #expect(report.source.version == "11.32.0")
        #expect(report.destination.version == "11.33.0")
        #expect(report.sourcePermissions["categories"] == .allowed)
        #expect(report.destinationPermissions["policies"] == .denied)
        #expect(report.deniedTypes == ["policies"])
        #expect(!report.isReady)
        #expect(report.destinationCounts["categories"] == 1)
        #expect(report.destinationCounts["policies"] == nil)
        #expect(!report.destinationIsEmpty)
    }

    @Test func unreachableTenantIsReported() async throws {
        let gateway = FakeGateway { env, _, path, _ in
            if path == "/pro/v1/jamf-pro-version" && env == "src" {
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["version": "11.32.0"]))
            }
            return MockHTTP.Reply(status: 503, data: Data("upstream connect error".utf8))
        }

        let report = await Preflight.run(source: gateway.source, dest: gateway.dest, typeKeys: ["categories"])
        #expect(report.source.reachable)
        #expect(!report.destination.reachable)
        #expect(report.destination.error?.contains("503") == true)
        #expect(!report.isReady)
    }
}
