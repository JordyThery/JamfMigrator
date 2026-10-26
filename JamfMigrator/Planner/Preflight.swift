//
//  Preflight.swift
//  JamfMigrator
//
//  Checks that run before a plan: both tenants answer, the integrations have
//  the permissions the selected types need, and the destination's contents
//  are counted so a non-empty destination can be called out. Also carries the
//  manual checklist of what the API cannot copy.
//

import Foundation
import JTKit

struct PreflightReport: Sendable {

    struct TenantCheck: Sendable {
        let reachable: Bool
        let version: String?
        let error: String?
    }

    let source: TenantCheck
    let destination: TenantCheck
    /// Permission check results per registry key.
    let sourcePermissions: [String: JamfPlatform.PermissionResult]
    let destinationPermissions: [String: JamfPlatform.PermissionResult]
    /// Objects already on the destination, per registry key; -1 = the list
    /// failed.
    let destinationCounts: [String: Int]
    /// Selected types that need the Platform API gateway while a tenant
    /// connects directly. They aren't probed — they are Blocked by design,
    /// not missing a permission.
    var unavailableTypes: [String] = []

    var destinationIsEmpty: Bool {
        destinationCounts.values.allSatisfy { $0 <= 0 }
    }

    /// Registry keys either integration lacks permission for (HTTP 403).
    var missingPermissionTypes: [String] {
        types { $0 == .missingPermission }
    }

    /// Registry keys whose list isn't on a tenant (HTTP 404), and no
    /// permission is missing for.
    var notFoundTypes: [String] {
        types { $0 == .notFound }.filter { !missingPermissionTypes.contains($0) }
    }

    /// Registry keys that couldn't be checked (another status, or no answer)
    /// and aren't in either list above.
    var uncheckedTypes: [String] {
        let flagged = Set(missingPermissionTypes + notFoundTypes)
        return types {
            switch $0 {
            case .failed, .unreachable: true
            default: false
            }
        }.filter { !flagged.contains($0) }
    }

    /// Every type in one of the three lists.
    var flaggedTypes: [String] {
        missingPermissionTypes + notFoundTypes + uncheckedTypes
    }

    /// Keys with a result matching `match` on either tenant.
    private func types(where match: (JamfPlatform.PermissionResult) -> Bool) -> [String] {
        let keys = Set(sourcePermissions.filter { match($0.value) }.keys)
            .union(destinationPermissions.filter { match($0.value) }.keys)
        return keys.sorted()
    }

    /// Only an unreachable tenant stops a clone. Missing permissions and a
    /// non-empty destination are warnings: the affected types simply fail or
    /// update in place, and the user decides.
    var isReady: Bool {
        source.reachable && destination.reachable
    }

    var hasWarnings: Bool {
        !flaggedTypes.isEmpty || !destinationIsEmpty
    }

    /// Display names for a list of registry keys, in registry order.
    static func displayNames(_ keys: [String]) -> String {
        ObjectRegistry.types.filter { keys.contains($0.key) }.map(\.displayName)
            .joined(separator: ", ")
    }

    /// What the API cannot copy; shown before every clone.
    static let manualChecklist: [String] = [
        "ADE token: create one per tenant in Apple Business/School Manager against the destination's public key.",
        "VPP / Apps and Books tokens.",
        "APNs certificate.",
        "SSO certificates.",
        "API clients and roles (the gateway doesn't serve them).",
        "Package files: uploads are blocked by the gateway's CDN firewall, so files must already be on the destination's distribution points.",
    ]
}

enum Preflight {

    static func run(source: JamfPlatform.Client, dest: JamfPlatform.Client, typeKeys: Set<String>) async -> PreflightReport {
        let sourceCheck = await check(source)
        let destCheck = await check(dest)

        // gateway-only types can't be reached over a direct connection;
        // probing them would report a "missing permission" that isn't one
        let directPair = !(source.supportsPlatformEndpoints && dest.supportsPlatformEndpoints)
        let selected = ObjectRegistry.types.filter { typeKeys.contains($0.key) }
        let unavailable = directPair ? selected.filter(\.requiresGateway).map(\.key) : []
        let types = selected.filter { !unavailable.contains($0.key) }
        // the same GETs as always: each type's list, without paging
        // parameters. The registry names no Jamf Account permissions or Jamf
        // Pro privileges, so the report names the types.
        let checks = types.map {
            JamfPlatform.PermissionCheck($0.displayName, path: $0.api.listPath, query: [], permission: "")
        }

        var sourcePermissions = [String: JamfPlatform.PermissionResult]()
        var destPermissions = [String: JamfPlatform.PermissionResult]()
        if sourceCheck.reachable {
            sourcePermissions = keyed(await source.checkPermissions(checks), types: types)
        }
        if destCheck.reachable {
            destPermissions = keyed(await dest.checkPermissions(checks), types: types)
        }

        // counts only where the destination integration can actually list
        var destinationCounts = [String: Int]()
        if destCheck.reachable {
            for type in types where destPermissions[type.key] == .allowed {
                // -1 marks a failed list; it must not read as "empty"
                destinationCounts[type.key] = (try? await ObjectLister.list(type, on: dest).count) ?? -1
            }
        }

        return PreflightReport(source: sourceCheck,
                               destination: destCheck,
                               sourcePermissions: sourcePermissions,
                               destinationPermissions: destPermissions,
                               destinationCounts: destinationCounts,
                               unavailableTypes: unavailable)
    }

    /// Whether the tenant answers, and its Jamf Pro version. Also Settings'
    /// Test Connection.
    static func check(_ client: JamfPlatform.Client) async -> PreflightReport.TenantCheck {
        struct Version: Decodable { let version: String }
        do {
            let version = try await client.get(Version.self, "pro/v1/jamf-pro-version")
            return .init(reachable: true, version: version.version, error: nil)
        } catch {
            return .init(reachable: false, version: nil, error: error.localizedDescription)
        }
    }

    /// The results by registry key; they come back in the order of `types`.
    private static func keyed(_ results: [(check: JamfPlatform.PermissionCheck, result: JamfPlatform.PermissionResult)],
                              types: [ObjectType]) -> [String: JamfPlatform.PermissionResult] {
        Dictionary(zip(types, results).map { ($0.key, $1.result) }, uniquingKeysWith: { first, _ in first })
    }
}
