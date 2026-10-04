//
//  TenantMappings.swift
//  JamfMigrator
//
//  Cross-tenant mappings that can't be resolved by name: ADE (device
//  enrollment) instances and distribution points. Collected in the Clone
//  wizard and consumed by the PreStage transforms in Phase 6.
//

import Foundation

/// Source id → destination id mappings for one tenant pair.
struct TenantMappings: Codable, Equatable, Sendable {
    /// ADE instance mapping. Devices belong to each tenant's own ADE token,
    /// so instances can only be matched by hand — except when the destination
    /// has exactly one, which maps automatically.
    var adeInstances: [String: String] = [:]
    /// Distribution point mapping, for PreStage custom package sources.
    /// "-2" is the cloud distribution point and maps to itself.
    var distributionPoints: [String: String] = [:]

    var isEmpty: Bool { adeInstances.isEmpty && distributionPoints.isEmpty }
}

enum MappingCatalog {

    /// The tenant's ADE instances (/pro/v1/device-enrollments).
    static func adeInstances(on client: PlatformClient) async throws -> [ObjectRef] {
        let type = ObjectType(key: "deviceenrollments", displayName: "ADE instances", step: 0,
                              api: .pro(version: 1, resource: "device-enrollments"),
                              listShape: .proPaginated)
        return try await ObjectLister.list(type, on: client)
    }

    /// The tenant's distribution points (/pro/v1/distribution-points).
    static func distributionPoints(on client: PlatformClient) async throws -> [ObjectRef] {
        guard let type = ObjectRegistry.type("distributionpoints") else { return [] }
        return try await ObjectLister.list(type, on: client)
    }

    /// Proposes mappings: names that match map to each other; otherwise, when
    /// the destination has exactly one ADE instance, everything maps to it.
    static func propose(sourceADE: [ObjectRef], destADE: [ObjectRef],
                        sourceDPs: [ObjectRef], destDPs: [ObjectRef]) -> TenantMappings {
        var mappings = TenantMappings()

        let destADEByName = Dictionary(destADE.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        for instance in sourceADE {
            if let match = destADEByName[instance.name] {
                mappings.adeInstances[instance.id] = match
            } else if destADE.count == 1 {
                mappings.adeInstances[instance.id] = destADE[0].id
            }
        }

        let destDPByName = Dictionary(destDPs.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        for dp in sourceDPs {
            if let match = destDPByName[dp.name] {
                mappings.distributionPoints[dp.id] = match
            }
        }
        // the cloud distribution point is the same pseudo-id on every tenant
        mappings.distributionPoints["-2"] = "-2"
        return mappings
    }
}
