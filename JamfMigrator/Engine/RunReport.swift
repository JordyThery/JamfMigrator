//
//  RunReport.swift
//  JamfMigrator
//
//  The outcome of a migration or delete run, one entry per object.
//

import Foundation

struct RunReportEntry: Codable, Sendable, Equatable {
    let type: String
    let objectId: String
    let objectName: String
    let status: ObjectStatus
    var warnings: [String] = []
}

struct RunReport: Codable, Sendable {
    var entries: [RunReportEntry] = []

    mutating func add(type: ObjectType, ref: ObjectRef, status: ObjectStatus, warnings: [String] = []) {
        entries.append(RunReportEntry(type: type.key, objectId: ref.id, objectName: ref.name,
                                      status: status, warnings: warnings))
    }

    func entries(for type: String) -> [RunReportEntry] {
        entries.filter { $0.type == type }
    }

    /// Everything that did not finish: failures and by-design blocks.
    var failures: [RunReportEntry] {
        entries.filter { !$0.status.isDone }
    }

    /// Only the real failures — what a resumed run would retry. Blocked
    /// entries are by design and must not keep a journal alive.
    var retryableFailures: [RunReportEntry] {
        entries.filter { if case .failed = $0.status { true } else { false } }
    }

    var entriesWithWarnings: [RunReportEntry] {
        entries.filter { !$0.warnings.isEmpty }
    }
}

/// Live progress, one event per finished object.
struct ProgressEvent: Sendable, Equatable {
    let type: String
    let objectName: String
    let completed: Int
    let total: Int
    let status: ObjectStatus
}
