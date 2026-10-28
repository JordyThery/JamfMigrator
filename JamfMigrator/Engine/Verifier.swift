//
//  Verifier.swift
//  JamfMigrator
//
//  Verifies a clone by planning again: after a successful run, every source
//  object should come back Unchanged (or stay Blocked for a known reason).
//  Also compares per-type object counts between the tenants.
//

import Foundation
import JTKit

struct VerifyReport: Sendable {

    struct TypeResult: Sendable, Equatable {
        let typeKey: String
        /// The objects Verify covered on the source (left-out ones not counted).
        let sourceCount: Int
        /// The type's objects on the destination; nil when they couldn't be listed.
        let destCount: Int?
        /// Objects that are not Unchanged after the run: name and why.
        var discrepancies: [String] = []
        var blocked: [String] = []
        /// Why the type couldn't be checked (a list or detail that couldn't
        /// be read); nil when it was. A type that wasn't checked never passes.
        var notChecked: String? = nil
    }

    var types: [TypeResult] = []

    /// A second run would write nothing, and every type was checked.
    var isClean: Bool {
        types.allSatisfy { $0.discrepancies.isEmpty && $0.notChecked == nil }
    }

    var discrepancyCount: Int {
        types.reduce(0) { $0 + $1.discrepancies.count }
    }

    var notCheckedCount: Int {
        types.filter { $0.notChecked != nil }.count
    }
}

enum Verifier {

    /// Plans source → destination again and reports everything that is not
    /// Unchanged. A clean verify means a second run would write nothing.
    /// `only` is a test-only limit to named source objects (see `OnlyObjects`).
    static func verify(source: JamfPlatform.Client,
                       dest: JamfPlatform.Client,
                       typeKeys: Set<String>,
                       excluding: [String: Set<String>] = [:],
                       only: OnlyObjects? = nil,
                       secrets: [String: String] = [:],
                       mappings: TenantMappings = TenantMappings(),
                       progress: (@Sendable (String) -> Void)? = nil) async -> VerifyReport {
        let planner = MigrationPlanner(source: source, dest: dest, secrets: secrets, mappings: mappings, progress: progress)
        let plan = await planner.plan(typeKeys: typeKeys, only: only)

        var report = VerifyReport()
        for type in ObjectRegistry.types where typeKeys.contains(type.key) {
            // Blueprints and Benchmarks aren't checked (or planned) when a
            // tenant connects directly to Jamf Pro
            if type.requiresGateway && !(source.supportsPlatformEndpoints && dest.supportsPlatformEndpoints) { continue }
            let excluded = excluding[type.key] ?? []
            let entries = plan.entries(for: type.key).filter { !excluded.contains($0.objectId) }
            let destCount = try? await ObjectLister.list(type, on: dest).count
            var result = VerifyReport.TypeResult(typeKey: type.key,
                                                 sourceCount: entries.filter { $0.objectId != "-" }.count,
                                                 destCount: destCount)
            if let unread = entries.first(where: \.isReadFailure) {
                if case .blocked(let reason) = unread.change { result.notChecked = reason }
            } else if destCount == nil {
                result.notChecked = "The destination's list couldn't be read."
            }
            for entry in entries where !entry.isReadFailure {
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
