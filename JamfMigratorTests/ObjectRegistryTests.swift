//
//  ObjectRegistryTests.swift
//  JamfMigratorTests
//
//  Pins the registry against the vendored jamf-cli gateway spec
//  (Resources/gateway-coverage.json). When the spec moves — a new endpoint
//  version appears, or CRUD coverage changes — these tests fail, pointing at
//  the registry entry to revisit.
//

import Foundation
import Testing
@testable import JamfMigrator

private final class BundleToken {}

/// The vendored gateway spec: path → allowed methods.
private let gatewaySpec: [String: Set<String>] = {
    let url = Bundle(for: BundleToken.self).url(forResource: "gateway-coverage", withExtension: "json")!
    let root = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let spec = root["spec"] as! [String: [String]]
    return spec.reduce(into: [:]) { $0[$1.key] = Set($1.value) }
}()

/// Normalizes a gateway path the way the spec does: every id component → {}.
private func specListPath(_ type: ObjectType) -> String { "/" + type.api.listPath }
private func specDetailPath(_ type: ObjectType) -> String { "/" + type.api.detailPath(id: "{}") }

struct ObjectRegistryTests {

    @Test(arguments: ObjectRegistry.types)
    func listAndDetailAreServedByTheGateway(type: ObjectType) throws {
        // the vendored spec only covers /pro and /proclassic; the platform
        // namespaces (Blueprints, Benchmarks) are pinned by live validation
        guard !type.requiresGateway else { return }

        let list = try #require(gatewaySpec[specListPath(type)],
                                "\(type.key): list path \(specListPath(type)) is not in the gateway spec")
        #expect(list.contains("GET"), "\(type.key): list path does not allow GET")

        // settings singletons GET and PUT/PATCH their one path; nothing deletes
        if case .singleton = type.listShape {
            #expect(list.contains(type.updateMethod.rawValue),
                    "\(type.key): singleton path does not allow \(type.updateMethod.rawValue)")
            return
        }

        let detail = try #require(gatewaySpec[specDetailPath(type)],
                                  "\(type.key): detail path \(specDetailPath(type)) is not in the gateway spec")
        for method in ["GET", "DELETE", type.updateMethod.rawValue] {
            #expect(detail.contains(method), "\(type.key): detail path does not allow \(method)")
        }
    }

    @Test(arguments: ObjectRegistry.types)
    func createIsServedByTheGateway(type: ObjectType) throws {
        guard !type.requiresGateway else { return }
        if case .singleton = type.listShape { return }

        // patch policies are created through softwaretitleconfig (path override)
        let createPath = type.key == "patchpolicies"
            ? "/proclassic/patchpolicies/softwaretitleconfig/id/{}"
            : "/" + type.api.createPath.replacingOccurrences(of: "/id/0", with: "/id/{}")
                                       .replacingOccurrences(of: "/groupid/0", with: "/groupid/{}")
                                       .replacingOccurrences(of: "/userid/0", with: "/userid/{}")
        let methods = try #require(gatewaySpec[createPath],
                                   "\(type.key): create path \(createPath) is not in the gateway spec")
        #expect(methods.contains("POST"), "\(type.key): create path does not allow POST")
    }

    @Test(arguments: ObjectRegistry.types)
    func pinnedVersionIsTheNewestInTheSpec(type: ObjectType) throws {
        guard case .pro(let version, let resource) = type.api else { return }
        // find every version of this exact resource in the spec
        var versions = Set<Int>()
        for path in gatewaySpec.keys {
            let prefixPattern = #"^/pro/v(\d+)/"#
            guard let range = path.range(of: prefixPattern, options: .regularExpression) else { continue }
            let rest = String(path[range.upperBound...])
            guard rest == resource || rest.hasPrefix(resource + "/") else { continue }
            let v = Int(path.dropFirst("/pro/v".count).prefix(while: \.isNumber))!
            // only count versions that actually serve the list resource itself
            if rest == resource { versions.insert(v) }
        }
        let newest = try #require(versions.max(), "\(type.key): resource \(resource) not found in the spec")
        #expect(version == newest, "\(type.key): pinned v\(version) but the spec's newest is v\(newest)")
    }

    @Test func dependenciesAreRegisteredAndMigrateFirst() throws {
        let order = ObjectRegistry.types.map(\.key)
        for type in ObjectRegistry.types {
            for dep in type.dependencies {
                let depIndex = try #require(order.firstIndex(of: dep),
                                            "\(type.key): dependency \(dep) is not registered")
                #expect(depIndex < order.firstIndex(of: type.key)!,
                        "\(type.key): dependency \(dep) migrates after it")
            }
        }
    }

    @Test func keysAreUniqueAndStepsAreOrdered() {
        let keys = ObjectRegistry.types.map(\.key)
        #expect(Set(keys).count == keys.count)
        #expect(ObjectRegistry.types.map(\.step) == ObjectRegistry.types.map(\.step).sorted())
    }
}
