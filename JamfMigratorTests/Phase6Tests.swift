//
//  Phase6Tests.swift
//  JamfMigratorTests
//
//  Platform objects: PreStages, enrollment customizations, Blueprints,
//  Compliance Benchmarks and the tenant-settings singletons.
//

import Foundation
import Testing
@testable import JamfMigrator

private func phase6Context() -> TransformContext {
    var context = TransformContext()
    context.destIdsByName = [
        "sites": ["HQ": "9"],
        "buildings": ["Main": "21"],
        "departments": ["IT": "31"],
        "packages": ["Chrome-120.pkg": "41"],
        "osxconfigurationprofiles": ["Wi-Fi": "51"],
        "enrollmentcustomizations": ["Welcome": "61"],
        platformGroupsKey: ["All Laptops": "DEST-GROUP-UUID"],
    ]
    context.sourceNamesById = [
        "sites": ["2": "HQ"],
        "buildings": ["1": "Main"],
        "departments": ["3": "IT"],
        "packages": ["8": "Chrome-120.pkg"],
        "osxconfigurationprofiles": ["5": "Wi-Fi"],
        "enrollmentcustomizations": ["6": "Welcome"],
        platformGroupsKey: ["SRC-GROUP-UUID": "All Laptops"],
    ]
    context.mappings = TenantMappings(adeInstances: ["1": "7"], distributionPoints: ["-2": "-2"])
    return context
}

private func jsonBody(_ outcome: TransformOutcome) throws -> [String: Any] {
    guard case .write(let object) = outcome else {
        Issue.record("expected .write, got \(outcome)")
        throw GatewayError.invalidURL("blocked")
    }
    return try JSONSerialization.jsonObject(with: object.body) as! [String: Any]
}

struct PreStageTransformTests {

    private var sourcePreStage: [String: Any] {
        ["id": "1", "displayName": "Standard Macs", "versionLock": 6,
         "profileUuid": "ABC", "defaultPrestage": false,
         "deviceEnrollmentProgramInstanceId": "1",
         "siteId": "2", "enrollmentSiteId": "2",
         "enrollmentCustomizationId": "6",
         "prestageInstalledProfileIds": ["5"],
         "customPackageIds": ["8"],
         "customPackageDistributionPointId": "-2",
         "locationInformation": ["id": "1", "buildingId": "1", "departmentId": "3", "versionLock": 3],
         "purchasingInformation": ["id": "1", "versionLock": 2],
         "accountSettings": ["id": "1", "adminAccountEnabled": true, "versionLock": 2]]
    }

    @Test func createRemapsEverythingAndStripsLocks() throws {
        let type = ObjectRegistry.type("computerprestages")!
        let out = try jsonBody(ProTransformer.transform(type: type, json: sourcePreStage, context: phase6Context()))

        #expect(out["id"] == nil)
        #expect(out["profileUuid"] == nil)
        #expect(out["versionLock"] == nil)
        #expect(out["deviceEnrollmentProgramInstanceId"] as? String == "7")
        #expect(out["siteId"] as? String == "9")
        #expect(out["enrollmentSiteId"] as? String == "9")
        #expect(out["enrollmentCustomizationId"] as? String == "61")
        #expect(out["prestageInstalledProfileIds"] as? [String] == ["51"])
        #expect(out["customPackageIds"] as? [String] == ["41"])
        // the API requires nested id/versionLock even on create: -1 / 0
        let location = out["locationInformation"] as? [String: Any]
        #expect(location?["buildingId"] as? String == "21")
        #expect(location?["departmentId"] as? String == "31")
        #expect(location?["id"] as? String == "-1")
        #expect(location?["versionLock"] as? Int == 0)
    }

    @Test func updateEchoesTheDestinationVersionLocks() throws {
        let type = ObjectRegistry.type("computerprestages")!
        var context = phase6Context()
        context.action = .update(destId: "77")
        context.destVersionLocks = ["root": 12, "locationInformation": 4, "purchasingInformation": 5, "accountSettings": 6]
        context.destPreStageIds = ["locationInformation": "9", "purchasingInformation": "9", "accountSettings": "9"]
        let out = try jsonBody(ProTransformer.transform(type: type, json: sourcePreStage, context: context))

        #expect(out["versionLock"] as? Int == 12)
        #expect((out["locationInformation"] as? [String: Any])?["versionLock"] as? Int == 4)
        #expect((out["locationInformation"] as? [String: Any])?["id"] as? String == "9")
        #expect((out["purchasingInformation"] as? [String: Any])?["versionLock"] as? Int == 5)
        #expect((out["accountSettings"] as? [String: Any])?["versionLock"] as? Int == 6)
    }

    @Test func unmappedADEInstanceBlocks() {
        let type = ObjectRegistry.type("computerprestages")!
        var context = phase6Context()
        context.mappings.adeInstances = [:]
        guard case .blocked(let reason) = ProTransformer.transform(type: type, json: sourcePreStage, context: context) else {
            Issue.record("expected .blocked")
            return
        }
        #expect(reason.contains("ADE"))
    }

    @Test func adminPasswordWarningIsAttached() throws {
        let type = ObjectRegistry.type("computerprestages")!
        let outcome = ProTransformer.transform(type: type, json: sourcePreStage, context: phase6Context())
        guard case .write(let object) = outcome else { return }
        #expect(object.warnings.contains { $0.contains("admin password") })
    }
}

struct BlueprintBenchmarkTransformTests {

    @Test func blueprintRemapsGroupsAndReassignsPayloadIdentifiers() throws {
        let type = ObjectRegistry.type("blueprints")!
        let source: [String: Any] = [
            "id": "B1", "name": "Baseline", "created": "x", "updated": "y",
            "deploymentState": "DEPLOYED",
            "scope": ["deviceGroups": ["SRC-GROUP-UUID"]],
            "activationPredicate": "group == 'SRC-GROUP-UUID'",
            "steps": [["components": [["type": "configuration-profile",
                                       "payloadIdentifier": "OLD-PAYLOAD-ID",
                                       "settings": ["RequirePasscode": ["Included": true, "Value": true]]]]]],
        ]
        let out = try jsonBody(ProTransformer.transform(type: type, json: source, context: phase6Context()))

        #expect(out["id"] == nil)
        #expect(out["deploymentState"] == nil)
        #expect((out["scope"] as? [String: Any])?["deviceGroups"] as? [String] == ["DEST-GROUP-UUID"])
        #expect(out["activationPredicate"] as? String == "group == 'DEST-GROUP-UUID'")
        let component = (((out["steps"] as? [[String: Any]])?.first?["components"] as? [[String: Any]]))?.first
        let newIdentifier = component?["payloadIdentifier"] as? String
        #expect(newIdentifier != nil && newIdentifier != "OLD-PAYLOAD-ID")
    }

    @Test func blueprintWithUnknownGroupBlocks() {
        let type = ObjectRegistry.type("blueprints")!
        let source: [String: Any] = ["name": "Baseline", "scope": ["deviceGroups": ["UNKNOWN-UUID"]]]
        guard case .blocked = ProTransformer.transform(type: type, json: source, context: phase6Context()) else {
            Issue.record("expected .blocked")
            return
        }
    }

    @Test func benchmarkBuildsThePostShape() throws {
        let type = ObjectRegistry.type("compliancebenchmarks")!
        let source: [String: Any] = [
            "id": "C1", "title": "CIS Level 1", "baselineId": "cis-l1",
            "enforcementMode": "MONITOR", "syncState": "SYNCED",
            "rules": [["id": "r1", "enabled": true, "odv": "8", "extra": "dropme"]],
            "target": ["deviceGroups": ["SRC-GROUP-UUID"]],
        ]
        let out = try jsonBody(ProTransformer.transform(type: type, json: source, context: phase6Context()))

        #expect(out["sourceBaselineId"] as? String == "cis-l1")
        #expect(out["baselineId"] == nil)
        #expect(out["syncState"] == nil)
        let rule = (out["rules"] as? [[String: Any]])?.first
        #expect(rule?["id"] as? String == "r1")
        #expect(rule?["extra"] == nil)
        #expect((out["target"] as? [String: Any])?["deviceGroups"] as? [String] == ["DEST-GROUP-UUID"])
    }

    @Test func singletonCopiesWithSecretWarnings() throws {
        let type = ObjectRegistry.type("smtpserver")!
        let outcome = ProTransformer.transform(type: type, json: ["enabled": true, "connectionSettings": ["host": "smtp.x"]],
                                               context: phase6Context())
        let out = try jsonBody(outcome)
        #expect(out["enabled"] as? Bool == true)
        guard case .write(let object) = outcome else { return }
        #expect(object.warnings.contains { $0.contains("SMTP password") })
    }
}

struct Phase6EngineTests {

    @Test func singletonsAreUpdatedInPlace() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/pro/v3/check-in"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["checkInFrequency": 15]))
            case ("dst", "GET", "/pro/v3/check-in"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["checkInFrequency": 30]))
            case ("dst", "PUT", "/pro/v3/check-in"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["checkInFrequency": 15]))
            default:
                return nil
            }
        }
        let engine = MigrationEngine(source: gateway.source, dest: gateway.dest, journal: makeJournal())
        let report = await engine.migrate(typeKeys: ["checkin"])

        #expect(report.entries.first?.status == .updated(destId: "singleton"))
        #expect(gateway.writes(to: "dst").map { "\($0.method) \($0.path)" } == ["PUT /pro/v3/check-in"])
    }

    @Test func benchmarksAreReplacedAndSyncIsPolled() async throws {
        let posted = Locked(false)
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/compliance-benchmarks/v1/benchmarks"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["benchmarks": [["id": "C1", "title": "CIS Level 1"]]]))
            case ("src", "GET", "/compliance-benchmarks/v1/benchmarks/C1"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(
                    ["id": "C1", "title": "CIS Level 1", "baselineId": "cis-l1",
                     "rules": [["id": "r1", "enabled": true]]]))
            case ("dst", "GET", "/compliance-benchmarks/v1/benchmarks"):
                // syncState only appears on list entries; after the recreate
                // the list serves the new benchmark as SYNCED for the poll
                if posted.value {
                    return MockHTTP.Reply(status: 200, data: MockHTTP.json(["benchmarks": [["id": "C10", "title": "CIS Level 1", "syncState": "SYNCED"]]]))
                }
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["benchmarks": [["id": "C9", "title": "CIS Level 1"]]]))
            case ("dst", "DELETE", "/compliance-benchmarks/v1/benchmarks/C9"):
                return MockHTTP.Reply(status: 204)
            case ("dst", "POST", "/compliance-benchmarks/v1/benchmarks"):
                posted.withLock { $0 = true }
                // the create response names the id benchmarkId (verified live)
                return MockHTTP.Reply(status: 201, data: MockHTTP.json(["benchmarkId": "C10", "title": "CIS Level 1", "syncState": "SYNCING"]))
            default:
                return nil
            }
        }
        let engine = MigrationEngine(source: gateway.source, dest: gateway.dest, journal: makeJournal())
        let report = await engine.migrate(typeKeys: ["compliancebenchmarks"])

        #expect(report.entries.first?.status == .updated(destId: "C10"))
        let writes = gateway.writes(to: "dst").map { "\($0.method) \($0.path)" }
        #expect(writes == ["DELETE /compliance-benchmarks/v1/benchmarks/C9", "POST /compliance-benchmarks/v1/benchmarks"])
    }

    /// A 409 duplicate title on create means a benchmark with that name
    /// already exists; the engine re-lists and treats the match as the object.
    @Test func benchmarkDuplicateTitleIsAMatch() async throws {
        let listCalls = Locked(0)
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/compliance-benchmarks/v1/benchmarks"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["benchmarks": [["id": "C1", "title": "CIS Level 1"]]]))
            case ("src", "GET", "/compliance-benchmarks/v1/benchmarks/C1"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "C1", "title": "CIS Level 1", "baselineId": "cis-l1"]))
            case ("dst", "GET", "/compliance-benchmarks/v1/benchmarks"):
                listCalls.withLock { $0 += 1 }
                // first list: empty (no match, so the engine creates); the
                // re-list after the 409 shows the benchmark that appeared
                if listCalls.value == 1 {
                    return MockHTTP.Reply(status: 200, data: MockHTTP.json(["benchmarks": []]))
                }
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["benchmarks": [["id": "C9", "title": "CIS Level 1"]]]))
            case ("dst", "POST", "/compliance-benchmarks/v1/benchmarks"):
                return MockHTTP.Reply(status: 409, data: MockHTTP.json(["message": "title already exists", "error": "DuplicateFieldException", "statusCode": 409]))
            default:
                return nil
            }
        }
        let engine = MigrationEngine(source: gateway.source, dest: gateway.dest, journal: makeJournal())
        let report = await engine.migrate(typeKeys: ["compliancebenchmarks"])
        #expect(report.entries.first?.status == .unchanged(destId: "C9"))
    }

    @Test func deployedBlueprintsAreDeployedOnTheDestination() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/blueprints/v1/blueprints"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 1, "results": [["id": "B1", "name": "Baseline"]]]))
            case ("src", "GET", "/blueprints/v1/blueprints/B1"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(
                    ["id": "B1", "name": "Baseline", "deploymentState": ["state": "DEPLOYED"], "steps": []]))
            case ("dst", "POST", "/blueprints/v1/blueprints"):
                return MockHTTP.Reply(status: 201, data: MockHTTP.json(["id": "B7"]))
            case ("dst", "POST", "/blueprints/v1/blueprints/B7/deploy"):
                return MockHTTP.Reply(status: 202)
            case ("dst", "GET", "/blueprints/v1/blueprints/B7"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "B7", "deploymentState": ["state": "DEPLOYED"]]))
            default:
                return nil
            }
        }
        let engine = MigrationEngine(source: gateway.source, dest: gateway.dest, journal: makeJournal())
        let report = await engine.migrate(typeKeys: ["blueprints"])

        #expect(report.entries.first?.status == .created(destId: "B7"))
        let writes = gateway.writes(to: "dst").map { "\($0.method) \($0.path)" }
        #expect(writes == ["POST /blueprints/v1/blueprints", "POST /blueprints/v1/blueprints/B7/deploy"])
    }

    @Test func blueprintDelete500IsVerifiedWithAGet() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("dst", "GET", "/blueprints/v1/blueprints"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 1, "results": [["id": "B1", "name": "Baseline"]]]))
            case ("dst", "DELETE", "/blueprints/v1/blueprints/B1"):
                return MockHTTP.Reply(status: 500, data: Data("boom".utf8))
            case ("dst", "GET", "/blueprints/v1/blueprints/B1"):
                return MockHTTP.Reply(status: 404)
            default:
                return nil
            }
        }
        let engine = DeleteEngine(client: gateway.dest, journal: makeJournal(mode: .delete))
        let report = await engine.delete(typeKeys: ["blueprints"])
        #expect(report.entries.first?.status == .deleted)
    }

    @Test func deletePlansAndRunsSkipSingletons() async throws {
        let gateway = FakeGateway { _, _, _, _ in nil }
        let engine = DeleteEngine(client: gateway.dest, journal: makeJournal(mode: .delete))
        let report = await engine.delete(typeKeys: ["checkin", "smtpserver"])
        #expect(report.entries.isEmpty)
        #expect(gateway.requests.value.filter { $0.method == "DELETE" }.isEmpty)

        let planner = MigrationPlanner(source: gateway.source, dest: gateway.dest)
        let plan = await planner.planDeletion(typeKeys: ["checkin", "smtpserver"])
        #expect(plan.entries.isEmpty)
    }
}

struct Phase6PlannerTests {

    @Test func benchmarkDifferencesPlanAsReplace() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/compliance-benchmarks/v1/benchmarks"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["benchmarks": [["id": "C1", "title": "CIS Level 1"]]]))
            case ("dst", "GET", "/compliance-benchmarks/v1/benchmarks"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["benchmarks": [["id": "C9", "title": "CIS Level 1"]]]))
            case ("src", "GET", "/compliance-benchmarks/v1/benchmarks/C1"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(
                    ["id": "C1", "title": "CIS Level 1", "baselineId": "cis-l1", "enforcementMode": "ENFORCE"]))
            case ("dst", "GET", "/compliance-benchmarks/v1/benchmarks/C9"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(
                    ["id": "C9", "title": "CIS Level 1", "baselineId": "cis-l1", "enforcementMode": "MONITOR"]))
            default:
                return nil
            }
        }
        let planner = MigrationPlanner(source: gateway.source, dest: gateway.dest)
        let plan = await planner.plan(typeKeys: ["compliancebenchmarks"])

        guard case .replace(let destId) = plan.entries.first?.change else {
            Issue.record("expected .replace, got \(String(describing: plan.entries.first?.change))")
            return
        }
        #expect(destId == "C9")
        #expect(plan.counts.replace == 1)
        #expect(plan.changeCount == 1)
    }

    @Test func gatewayOnlyTypesBlockOnDirectConnections() async throws {
        let session = MockHTTP.session { request in
            if request.url?.path.contains("token") == true { return MockHTTP.tokenJSON() }
            return MockHTTP.Reply(status: 200, data: Data("{}".utf8))
        }
        let direct = PlatformClient(serverURL: URL(string: "https://msp.jamfcloud.com")!,
                                    tokenProvider: TokenProvider(
                                        credentials: { .init(tokenURL: URL(string: "https://msp.jamfcloud.com/api/oauth/token")!,
                                                             clientId: "i", clientSecret: "s") },
                                        session: session),
                                    session: session)
        let gateway = FakeGateway { _, _, _, _ in nil }

        let planner = MigrationPlanner(source: gateway.source, dest: direct)
        let plan = await planner.plan(typeKeys: ["blueprints"])
        guard case .blocked(let reason) = plan.entries.first?.change else {
            Issue.record("expected .blocked")
            return
        }
        #expect(reason.contains("Platform API gateway"))
    }
}
