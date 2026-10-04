//
//  Verifier.swift
//  JamfMigrator
//
//  Verifies a clone by planning again: after a successful run, every source
//  object should come back Unchanged (or stay Blocked for a known reason).
//  Also compares per-type object counts between the tenants.
//

import Foundation

struct VerifyReport: Sendable {

    struct TypeResult: Sendable, Equatable {
        let typeKey: String
        let sourceCount: Int
        let destCount: Int
        /// Objects that are not Unchanged after the run: name and why.
        var discrepancies: [String] = []
        var blocked: [String] = []
    }

    var types: [TypeResult] = []

    var isClean: Bool {
        types.allSatisfy { $0.discrepancies.isEmpty }
    }

    var discrepancyCount: Int {
        types.reduce(0) { $0 + $1.discrepancies.count }
    }
}

enum Verifier {

    /// Plans source → destination again and reports everything that is not
    /// Unchanged. A clean verify means a second run would write nothing.
    static func verify(source: PlatformClient,
                       dest: PlatformClient,
                       typeKeys: Set<String>,
                       excluding: [String: Set<String>] = [:],
                       secrets: [String: String] = [:],
                       mappings: TenantMappings = TenantMappings(),
                       progress: (@Sendable (String) -> Void)? = nil) async -> VerifyReport {
        let planner = MigrationPlanner(source: source, dest: dest, secrets: secrets, mappings: mappings, progress: progress)
        let plan = await planner.plan(typeKeys: typeKeys)

        var report = VerifyReport()
        for type in ObjectRegistry.types where typeKeys.contains(type.key) {
            let entries = plan.entries(for: type.key)
            let excluded = excluding[type.key] ?? []
            var result = VerifyReport.TypeResult(typeKey: type.key,
                                                 sourceCount: entries.count,
                                                 destCount: (try? await ObjectLister.list(type, on: dest).count) ?? 0)
            for entry in entries where !excluded.contains(entry.objectId) {
                switch entry.change {
                case .unchanged, .keep:
                    break
                case .blocked(let reason):
                    result.blocked.append("\(entry.name): \(reason)")
                case .create:
                    result.discrepancies.append("\(entry.name): missing on the destination")
                case .update:
                    result.discrepancies.append("\(entry.name): differs from the source")
                case .replace:
                    result.discrepancies.append("\(entry.name): differs from the source (would be replaced)")
                case .delete:
                    break
                }
            }
            report.types.append(result)
        }
        return report
    }
}
