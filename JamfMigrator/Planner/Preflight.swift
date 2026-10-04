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

struct PreflightReport: Sendable {

    struct TenantCheck: Sendable {
        let reachable: Bool
        let version: String?
        let error: String?
    }

    let source: TenantCheck
    let destination: TenantCheck
    /// Probe results per registry key.
    let sourcePermissions: [String: ProbeResult]
    let destinationPermissions: [String: ProbeResult]
    /// Objects already on the destination, per registry key.
    let destinationCounts: [String: Int]

    var destinationIsEmpty: Bool {
        destinationCounts.values.allSatisfy { $0 == 0 }
    }

    /// Registry keys either integration lacks permission for.
    var deniedTypes: [String] {
        let denied = sourcePermissions.merging(destinationPermissions) { a, b in
            a == .allowed ? b : a
        }
        return denied.filter { $0.value != .allowed }.map(\.key).sorted()
    }

    var isReady: Bool {
        source.reachable && destination.reachable && deniedTypes.isEmpty
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

    static func run(source: PlatformClient, dest: PlatformClient, typeKeys: Set<String>) async -> PreflightReport {
        let sourceCheck = await check(source)
        let destCheck = await check(dest)

        let types = ObjectRegistry.types.filter { typeKeys.contains($0.key) }
        let pathsByType = Dictionary(uniqueKeysWithValues: types.map { ($0.key, $0.api.listPath) })

        var sourcePermissions = [String: ProbeResult]()
        var destPermissions = [String: ProbeResult]()
        if sourceCheck.reachable {
            sourcePermissions = keyed(await PermissionProbe(client: source).check(paths: Array(pathsByType.values)),
                                      by: pathsByType)
        }
        if destCheck.reachable {
            destPermissions = keyed(await PermissionProbe(client: dest).check(paths: Array(pathsByType.values)),
                                    by: pathsByType)
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
                               destinationCounts: destinationCounts)
    }

    private static func check(_ client: PlatformClient) async -> PreflightReport.TenantCheck {
        struct Version: Decodable { let version: String }
        do {
            let version = try await client.get(Version.self, "pro/v1/jamf-pro-version")
            return .init(reachable: true, version: version.version, error: nil)
        } catch {
            return .init(reachable: false, version: nil, error: error.localizedDescription)
        }
    }

    private static func keyed(_ results: [String: ProbeResult], by pathsByType: [String: String]) -> [String: ProbeResult] {
        var byType = [String: ProbeResult]()
        for (typeKey, path) in pathsByType {
            byType[typeKey] = results[path] ?? .unreachable("not probed")
        }
        return byType
    }
}
