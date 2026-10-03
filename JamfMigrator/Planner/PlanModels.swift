//
//  PlanModels.swift
//  JamfMigrator
//
//  What a dry run decides for each object. Nothing here touches the network.
//

import Foundation

/// The planned outcome for one object. `replace` (delete + recreate) arrives
/// with Compliance Benchmarks in Phase 6.
enum PlannedChange: Sendable, Equatable, Codable {
    /// The object isn't on the destination yet.
    case create
    /// The object exists on the destination but differs; see the diff.
    case update(destId: String)
    /// The object exists and is identical. It will be skipped.
    case unchanged(destId: String)
    /// The object can't be migrated; the reason says why.
    case blocked(reason: String)
    /// Delete mode: the object will be removed from the tenant.
    case delete
    /// Delete mode: a built-in that is kept, with the reason.
    case keep(reason: String)
}

/// One field-level difference between the normalized source and destination
/// payloads, e.g. path "general/frequency", source "Once per day", destination
/// "Ongoing".
struct DiffEntry: Sendable, Equatable, Codable {
    let path: String
    let source: String?
    let destination: String?
}

struct ObjectPlan: Sendable, Equatable, Codable, Identifiable {
    let typeKey: String
    let objectId: String
    let name: String
    let change: PlannedChange
    var warnings: [String] = []
    var diff: [DiffEntry] = []

    var id: String { "\(typeKey)/\(objectId)" }
}

struct MigrationPlan: Sendable, Codable {
    var mode: RunMode = .copy
    var createdAt = Date()
    var entries: [ObjectPlan] = []

    func entries(for typeKey: String) -> [ObjectPlan] {
        entries.filter { $0.typeKey == typeKey }
    }

    /// Counts per change kind, for the sidebar and the confirmation dialogs.
    var counts: (create: Int, update: Int, unchanged: Int, blocked: Int, delete: Int, keep: Int) {
        var create = 0, update = 0, unchanged = 0, blocked = 0, delete = 0, keep = 0
        for entry in entries {
            switch entry.change {
            case .create: create += 1
            case .update: update += 1
            case .unchanged: unchanged += 1
            case .blocked: blocked += 1
            case .delete: delete += 1
            case .keep: keep += 1
            }
        }
        return (create, update, unchanged, blocked, delete, keep)
    }

    /// Everything that would actually change, i.e. what the confirmation shows.
    var changeCount: Int {
        let counts = counts
        return counts.create + counts.update + counts.delete
    }
}
