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
    /// The object exists but can't be updated in place (Compliance Benchmarks
    /// only): it will be deleted and recreated. Needs confirmation.
    case replace(destId: String)
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
    /// What Preview saw, as a SHA-256 of the object as it was compared: the
    /// source object, and for an update the destination object. Run makes the
    /// same comparison right before writing and stops if either differs.
    var sourceDigest: String? = nil
    var destDigest: String? = nil
    /// Objects this object refers to that the run will create first
    /// (registry key and name), e.g. a script's new category. Unticking one
    /// of them blocks Run while this object stays ticked.
    var plannedDependencies: [PlannedDependency] = []
    /// The object (or the whole type, for "(all objects)") couldn't be read:
    /// Verify reports such a type as not checked, never as passed.
    var isReadFailure = false

    var id: String { "\(typeKey)/\(objectId)" }
}

/// A reference to an object the same run creates.
struct PlannedDependency: Sendable, Hashable, Codable {
    let typeKey: String
    let name: String
}

struct MigrationPlan: Sendable, Codable {
    var mode: RunMode = .copy
    var entries: [ObjectPlan] = []
    /// The types Preview planned; Run carries out these, never the current
    /// selection.
    var typeKeys: Set<String> = []

    /// The planned creates, by registry key: the names Preview treated as
    /// "will exist" when comparing references.
    var plannedCreateNames: [String: Set<String>] {
        var names = [String: Set<String>]()
        for entry in entries {
            if case .create = entry.change { names[entry.typeKey, default: []].insert(entry.name) }
        }
        return names
    }

    /// Every Create, Update, Replace and Delete row, per registry key: the
    /// ticks right after Preview.
    var runnableIds: [String: Set<String>] {
        var ids = [String: Set<String>]()
        for entry in entries where entry.change.isRunnable { ids[entry.typeKey, default: []].insert(entry.objectId) }
        return ids
    }

    func entries(for typeKey: String) -> [ObjectPlan] {
        entries.filter { $0.typeKey == typeKey }
    }

    /// Counts per change kind, for the sidebar and the confirmation dialogs.
    var counts: (create: Int, update: Int, replace: Int, unchanged: Int, blocked: Int, delete: Int, keep: Int) {
        var create = 0, update = 0, replace = 0, unchanged = 0, blocked = 0, delete = 0, keep = 0
        for entry in entries {
            switch entry.change {
            case .create: create += 1
            case .update: update += 1
            case .replace: replace += 1
            case .unchanged: unchanged += 1
            case .blocked: blocked += 1
            case .delete: delete += 1
            case .keep: keep += 1
            }
        }
        return (create, update, replace, unchanged, blocked, delete, keep)
    }

    /// Everything that would actually change, i.e. what the confirmation shows.
    var changeCount: Int {
        let counts = counts
        return counts.create + counts.update + counts.replace + counts.delete
    }
}
