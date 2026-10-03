//
//  RunJournal.swift
//  JamfMigrator
//
//  Persists a run's progress and id map so a failed run can resume and a
//  second run is safe. Saved as JSON after every object.
//

import Foundation

enum ObjectStatus: Codable, Equatable, Sendable {
    case created(destId: String)
    case updated(destId: String)
    case unchanged(destId: String)
    case deleted
    case blocked(reason: String)
    case failed(reason: String)

    var isDone: Bool {
        switch self {
        case .created, .updated, .unchanged, .deleted: true
        case .blocked, .failed: false
        }
    }

    var destId: String? {
        switch self {
        case .created(let id), .updated(let id), .unchanged(let id): id
        case .deleted, .blocked, .failed: nil
        }
    }
}

enum RunMode: String, Codable, Sendable {
    case copy
    case delete
}

struct RunJournal: Codable, Sendable {
    var runId = UUID()
    var mode: RunMode = .copy
    var startedAt = Date()
    var sourceTenantId: UUID?
    var destTenantId: UUID?
    /// Source id → destination id, per registry key. Also fed by name matches,
    /// so Classic payloads referencing ids can be resolved later.
    var idMap: [String: [String: String]] = [:]
    /// Per-object outcome, per registry key, keyed by source id (copy) or
    /// destination id (delete).
    var objects: [String: [String: ObjectStatus]] = [:]

    mutating func record(type: String, objectId: String, status: ObjectStatus) {
        objects[type, default: [:]][objectId] = status
        if let destId = status.destId {
            idMap[type, default: [:]][objectId] = destId
        }
    }

    func status(type: String, objectId: String) -> ObjectStatus? {
        objects[type]?[objectId]
    }

    func destId(type: String, sourceId: String) -> String? {
        idMap[type]?[sourceId]
    }
}

/// Owns the journal file for one run. Load it to resume; every record saves.
actor JournalStore {
    private(set) var journal: RunJournal
    private let fileURL: URL

    /// Opens the journal at `url`, resuming it if it exists and matches the
    /// requested mode and tenants; otherwise starts a fresh run.
    init(url: URL, mode: RunMode, sourceTenantId: UUID? = nil, destTenantId: UUID? = nil) {
        self.fileURL = url
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONDecoder().decode(RunJournal.self, from: data),
           existing.mode == mode,
           existing.sourceTenantId == sourceTenantId,
           existing.destTenantId == destTenantId {
            self.journal = existing
        } else {
            var fresh = RunJournal()
            fresh.mode = mode
            fresh.sourceTenantId = sourceTenantId
            fresh.destTenantId = destTenantId
            self.journal = fresh
        }
    }

    func record(type: String, objectId: String, status: ObjectStatus) {
        journal.record(type: type, objectId: objectId, status: status)
        save()
    }

    func destId(type: String, sourceId: String) -> String? {
        journal.destId(type: type, sourceId: sourceId)
    }

    func status(type: String, objectId: String) -> ObjectStatus? {
        journal.status(type: type, objectId: objectId)
    }

    /// Removes the journal file once a run finished cleanly.
    func finish() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try encoder.encode(journal).write(to: fileURL, options: .atomic)
        } catch {
            WriteToLog.shared.message("[JournalStore] could not save \(fileURL.path): \(error.localizedDescription)")
        }
    }
}
