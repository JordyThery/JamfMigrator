//
//  RunReport.swift
//  JamfMigrator
//
//  The outcome of a migration or delete run, one entry per object.
//

import Foundation
import JTKit

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

/// A finished run's report as text, saved to Application Support/JamfMigrator/
/// Run Reports, one file per run, so a record of what was created, changed,
/// deleted, skipped and failed survives quitting the app. Stopped runs are
/// saved too. Everything in it goes through JTKit's redaction.
struct RunReportFile {
    var report: RunReport
    var mode: RunMode
    /// Nil in delete mode, which works on one tenant.
    var sourceName: String?
    var destinationName: String
    var started: Date
    var finished: Date
    var wasStopped: Bool
    var appVersion = AppInfo.version

    /// Application Support/JamfMigrator/Run Reports (inside the sandbox container).
    static var folder: URL {
        URL(fileURLWithPath: AppInfo.appSupportPath, isDirectory: true)
            .appendingPathComponent("Run Reports", isDirectory: true)
    }

    /// e.g. 20261026-143205-copy.md, the date style of the exports and backups.
    var fileName: String {
        "\(Self.formatted(started, "yyyyMMdd-HHmmss"))-\(mode.rawValue).md"
    }

    /// Writes the report into `folder` and returns where. A second run in
    /// the same second gets a numbered name instead of replacing the first.
    func save(in folder: URL = RunReportFile.folder) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (fileName as NSString).deletingPathExtension
        var url = folder.appendingPathComponent(fileName)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base)-\(number).md")
            number += 1
        }
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }

    var text: String {
        var lines = ["# Jamf Migrator run report"]
        if mode == .copy {
            lines.append("Copy · Source: \(sourceName ?? "?") → Destination: \(destinationName)")
        } else {
            lines.append("Delete · Tenant: \(destinationName)")
        }
        let day = Self.formatted(started, "yyyy-MM-dd")
        let end = Self.formatted(finished, day == Self.formatted(finished, "yyyy-MM-dd") ? "HH:mm:ss" : "yyyy-MM-dd HH:mm:ss")
        lines.append("Started \(Self.formatted(started, "yyyy-MM-dd HH:mm:ss")) · "
                     + "\(wasStopped ? "Stopped" : "Finished") \(end) · Jamf Migrator \(appVersion)")
        if wasStopped {
            lines.append("The run was stopped before the end; objects after that point were not touched.")
        }

        let created = report.entries.filter { if case .created = $0.status { true } else { false } }
        let changed = report.entries.filter { if case .updated = $0.status { true } else { false } }
        let deleted = report.entries.filter { $0.status == .deleted }
        let skipped = report.entries.filter {
            switch $0.status {
            case .unchanged, .blocked: true
            default: false
            }
        }
        let failed = report.retryableFailures

        var counts = mode == .copy
            ? ["Created \(created.count)", "Changed \(changed.count)"]
            : ["Deleted \(deleted.count)"]
        counts += ["Skipped \(skipped.count)", "Failed \(failed.count)"]
        lines.append(counts.joined(separator: " · "))
        if report.entries.isEmpty {
            lines += ["", "Nothing was done."]
        }

        section("Failed", failed, into: &lines)
        section("Skipped", skipped, into: &lines)
        section("Created", created, into: &lines)
        section("Changed", changed, into: &lines)
        section("Deleted", deleted, into: &lines)

        let warned = report.entriesWithWarnings
        if !warned.isEmpty {
            lines += ["", "## Review after the run"]
            for entry in warned {
                for warning in entry.warnings {
                    lines.append("- \(Self.object(entry)): \(warning)")
                }
            }
        }
        return Redaction.text(lines.joined(separator: "\n") + "\n")
    }

    private func section(_ title: String, _ entries: [RunReportEntry], into lines: inout [String]) {
        guard !entries.isEmpty else { return }
        lines += ["", "## \(title)"]
        for entry in entries {
            lines.append("- \(Self.object(entry))\(Self.outcome(entry.status))")
        }
    }

    /// `Scripts › "Install Rosetta" (id 12)`, or `Policies › (all objects)`
    /// for a whole type.
    private static func object(_ entry: RunReportEntry) -> String {
        let type = ObjectRegistry.type(entry.type)?.displayName ?? entry.type
        guard entry.objectId != "-" else { return "\(type) › \(entry.objectName)" }
        let name = entry.objectName.isEmpty ? "(unnamed)" : "\"\(entry.objectName)\""
        return "\(type) › \(name) (id \(entry.objectId))"
    }

    private static func outcome(_ status: ObjectStatus) -> String {
        switch status {
        case .created(let destId), .updated(let destId): " → id \(destId) on the destination"
        case .unchanged: ": unchanged"
        case .deleted: ""
        case .blocked(let reason), .failed(let reason): ": \(reason)"
        }
    }

    private static func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
