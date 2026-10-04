//
//  TenantMappings.swift
//  JamfMigrator
//
//  Cross-tenant mappings that can't be resolved by name: ADE (device
//  enrollment) instances and distribution points. Collected in the Clone
//  wizard and consumed by the PreStage transforms.
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

    /// Identity mappings over every id this mapping knows about, for
    /// normalizing a destination payload (its ids are already destination
    /// ids and must pass through unchanged).
    var identity: TenantMappings {
        func identical(_ map: [String: String]) -> [String: String] {
            var out: [String: String] = [:]
            for (key, value) in map { out[key] = key; out[value] = value }
            return out
        }
        return TenantMappings(adeInstances: identical(adeInstances),
                              distributionPoints: identical(distributionPoints))
    }
}

/// The registry key under which platform device-group lookups are stored in
/// the transform context: Blueprints and Benchmarks reference groups by their
/// groupPlatformId UUID (/pro/v2/groups), not the Jamf Pro id.
let platformGroupsKey = "platformgroups"

enum MappingCatalog {

    /// Device groups as the platform namespaces see them: id = groupPlatformId.
    static func platformGroups(on client: PlatformClient) async throws -> [ObjectRef] {
        var results = [ObjectRef]()
        var page = 0
        while true {
            let query = [URLQueryItem(name: "page", value: "\(page)"),
                         URLQueryItem(name: "page-size", value: "200")]
            let response = try await client.send(.get, "pro/v2/groups", query: query)
            let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] ?? [:]
            let entries = root["results"] as? [[String: Any]] ?? []
            for entry in entries {
                guard let uuid = entry["groupPlatformId"] as? String else { continue }
                results.append(ObjectRef(id: uuid, name: entry["groupName"] as? String ?? ""))
            }
            let totalCount = root["totalCount"] as? Int ?? results.count
            if results.count >= totalCount || entries.isEmpty { return results }
            page += 1
        }
    }

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
