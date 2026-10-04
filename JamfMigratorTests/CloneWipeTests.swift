//
//  CloneWipeTests.swift
//  JamfMigratorTests
//
//  The Phase 5 engine pieces: ADE/distribution-point mapping proposals, the
//  verified tenant backup, and the post-clone verifier.
//

import Foundation
import Testing
@testable import JamfMigrator

struct MappingTests {

    @Test func matchingNamesMapToEachOther() {
        let mappings = MappingCatalog.propose(
            sourceADE: [ObjectRef(id: "1", name: "ABM Production")],
            destADE: [ObjectRef(id: "9", name: "ABM Production"), ObjectRef(id: "10", name: "ABM Test")],
            sourceDPs: [ObjectRef(id: "3", name: "HQ Share")],
            destDPs: [ObjectRef(id: "7", name: "HQ Share")])
        #expect(mappings.adeInstances == ["1": "9"])
        #expect(mappings.distributionPoints["3"] == "7")
        #expect(mappings.distributionPoints["-2"] == "-2")
    }

    @Test func singleDestinationADEMapsAutomatically() {
        let mappings = MappingCatalog.propose(
            sourceADE: [ObjectRef(id: "1", name: "ABM One"), ObjectRef(id: "2", name: "ABM Two")],
            destADE: [ObjectRef(id: "9", name: "Fresh ABM")],
            sourceDPs: [], destDPs: [])
        #expect(mappings.adeInstances == ["1": "9", "2": "9"])
    }

    @Test func noDestinationADELeavesInstancesUnmapped() {
        let mappings = MappingCatalog.propose(
            sourceADE: [ObjectRef(id: "1", name: "ABM One")],
            destADE: [],
            sourceDPs: [], destDPs: [])
        #expect(mappings.adeInstances.isEmpty)
    }

    @Test func identityMappingsPassDestinationIdsThrough() {
        // normalizing a destination payload must not re-map its ids
        let mappings = TenantMappings(adeInstances: ["2": "5"], distributionPoints: ["-2": "-2"])
        let identity = mappings.identity
        #expect(identity.adeInstances["5"] == "5")
        #expect(identity.adeInstances["2"] == "2")
        #expect(identity.distributionPoints["-2"] == "-2")
    }
}

struct TenantExporterTests {

    @Test func backupWritesEveryObjectAndVerifies() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("dst", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 2, "results": [
                    ["id": "1", "name": "Utilities"], ["id": "2", "name": "Browsers"]]]))
            case ("dst", "GET", "/pro/v1/categories/1"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "1", "name": "Utilities"]))
            case ("dst", "GET", "/pro/v1/categories/2"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "2", "name": "Browsers"]))
            case ("dst", "GET", "/proclassic/sites"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["sites": [["id": 4, "name": "HQ"]]]))
            case ("dst", "GET", "/proclassic/sites/id/4"):
                return MockHTTP.Reply(status: 200, data: Data("<site><id>4</id><name>HQ</name></site>".utf8))
            default:
                return nil
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let exporter = TenantExporter(client: gateway.dest)
        let result = await exporter.backup(typeKeys: ["categories", "sites"], to: root)

        #expect(result.isComplete)
        #expect(result.totalObjects == 3)
        #expect(result.objectCounts == ["categories": 2, "sites": 1])
        let utilities = root.appending(path: "categories/raw/Utilities-1.json")
        let site = root.appending(path: "sites/raw/HQ-4.xml")
        #expect(FileManager.default.fileExists(atPath: utilities.path))
        #expect(FileManager.default.fileExists(atPath: site.path))
    }

    @Test func failedDetailMakesTheBackupIncomplete() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("dst", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 1, "results": [["id": "1", "name": "Utilities"]]]))
            case ("dst", "GET", "/pro/v1/categories/1"):
                return MockHTTP.Reply(status: 500, data: Data("boom".utf8))
            default:
                return nil
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let exporter = TenantExporter(client: gateway.dest)
        let result = await exporter.backup(typeKeys: ["categories"], to: root)

        #expect(!result.isComplete)
        #expect(result.errors.count >= 1)
    }
}

struct VerifierTests {

    @Test func cleanWhenEverythingIsUnchanged() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (method, path) {
            case ("GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 1, "results": [
                    ["id": env == "src" ? "5" : "70", "name": "Utilities"]]]))
            case ("GET", "/pro/v1/categories/5"), ("GET", "/pro/v1/categories/70"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "x", "name": "Utilities", "priority": 9]))
            default:
                return nil
            }
        }

        let report = await Verifier.verify(source: gateway.source, dest: gateway.dest, typeKeys: ["categories"])
        #expect(report.isClean)
        #expect(report.types.first?.sourceCount == 1)
        #expect(report.types.first?.destCount == 1)
    }

    @Test func missingAndDifferingObjectsAreDiscrepancies() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 2, "results": [
                    ["id": "5", "name": "Utilities"], ["id": "6", "name": "Browsers"]]]))
            case ("dst", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 1, "results": [
                    ["id": "70", "name": "Utilities"]]]))
            case ("src", "GET", "/pro/v1/categories/5"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "5", "name": "Utilities", "priority": 3]))
            case ("src", "GET", "/pro/v1/categories/6"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "6", "name": "Browsers"]))
            case ("dst", "GET", "/pro/v1/categories/70"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "70", "name": "Utilities", "priority": 9]))
            default:
                return nil
            }
        }

        let report = await Verifier.verify(source: gateway.source, dest: gateway.dest, typeKeys: ["categories"])
        #expect(!report.isClean)
        #expect(report.discrepancyCount == 2)
        let discrepancies = report.types.first?.discrepancies ?? []
        #expect(discrepancies.contains { $0.contains("Browsers") && $0.contains("missing") })
        #expect(discrepancies.contains { $0.contains("Utilities") && $0.contains("differs") })
    }

    @Test func excludedObjectsAreIgnored() async throws {
        let gateway = FakeGateway { env, method, path, _ in
            switch (env, method, path) {
            case ("src", "GET", "/pro/v1/categories"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 1, "results": [["id": "6", "name": "Browsers"]]]))
            case ("src", "GET", "/pro/v1/categories/6"):
                return MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "6", "name": "Browsers"]))
            default:
                return nil
            }
        }

        let report = await Verifier.verify(source: gateway.source, dest: gateway.dest,
                                           typeKeys: ["categories"],
                                           excluding: ["categories": ["6"]])
        #expect(report.isClean)
    }
}
