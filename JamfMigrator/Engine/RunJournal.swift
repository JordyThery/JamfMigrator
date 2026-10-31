//
//  RunJournal.swift
//  JamfMigrator
//
//  Persists a run's progress so Resume Run can carry on with the same plan.
//  Saved as JSON after every object.
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
    var mode: RunMode = .copy
    var sourceTenantId: UUID?
    var destTenantId: UUID?
    /// The Preview this journal records a run of. Only a run of that same
    /// plan (Resume Run) skips what the journal says is done; a run of any
    /// other plan starts a fresh journal, so an earlier run never makes Run
    /// skip a write Preview planned.
    var planId: UUID?
    /// Per-object outcome, per registry key, keyed by source id (copy) or
    /// destination id (delete).
    var objects: [String: [String: ObjectStatus]] = [:]

    mutating func record(type: String, objectId: String, status: ObjectStatus) {
        objects[type, default: [:]][objectId] = status
    }

    func status(type: String, objectId: String) -> ObjectStatus? {
        objects[type]?[objectId]
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
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
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

    /// Called by the engines before a run of `planId`: a journal of
    /// another plan (or of none) is replaced by a fresh one, so only Resume
    /// Run of the same plan skips finished objects.
    func begin(planId: UUID) {
        guard journal.planId != planId else { return }
        var fresh = RunJournal()
        fresh.mode = journal.mode
        fresh.sourceTenantId = journal.sourceTenantId
        fresh.destTenantId = journal.destTenantId
        fresh.planId = planId
        journal = fresh
        save()
    }

    func record(type: String, objectId: String, status: ObjectStatus) {
        journal.record(type: type, objectId: objectId, status: status)
        save()
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
            AppActivity.record("Couldn’t save the run journal \(fileURL.lastPathComponent): \(error.localizedDescription)",
                               category: "Journal", level: .warning)
        }
    }
}
