//
//  RunView.swift
//  JamfMigrator
//
//  The run sheet: live progress per object while the engine works, then the
//  results report. This replaces the legacy SummaryView and HTML summary.
//

import SwiftUI

struct RunView: View {

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(appState.isRunning ? "Running…" : "Results")
                    .font(.title2.weight(.semibold))
                Spacer()
                if appState.isRunning {
                    Button("Stop", role: .destructive) { appState.cancel() }
                } else {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }

            if appState.isRunning {
                if let latest = appState.runEvents.last {
                    let typeName = ObjectRegistry.type(latest.type)?.displayName ?? latest.type
                    ProgressView(value: Double(latest.completed), total: Double(max(latest.total, 1))) {
                        Text("\(typeName): \(latest.objectName) (\(latest.completed)/\(latest.total))")
                            .lineLimit(1)
                    }
                } else {
                    ProgressView("Starting…")
                }
            }

            if let report = appState.report {
                ReportSummary(report: report)
            } else {
                EventLog(events: appState.runEvents)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 400)
    }
}

private struct EventLog: View {
    let events: [ProgressEvent]

    var body: some View {
        List(Array(events.enumerated()), id: \.offset) { _, event in
            // append-only log: the offset is stable because rows are never
            // reordered or removed while the sheet is up
            HStack {
                Text(event.objectName.isEmpty ? "(unnamed)" : event.objectName)
                    .lineLimit(1)
                Spacer()
                StatusBadge(status: event.status)
            }
        }
    }
}

private struct ReportSummary: View {
    let report: RunReport

    var body: some View {
        List {
            Section("Per type") {
                ForEach(typeKeys, id: \.self) { typeKey in
                    let entries = report.entries(for: typeKey)
                    HStack {
                        Text(ObjectRegistry.type(typeKey)?.displayName ?? typeKey)
                        Spacer()
                        Text(summary(for: entries))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !report.failures.isEmpty {
                Section("Not migrated") {
                    ForEach(report.failures, id: \.objectId) { entry in
                        VStack(alignment: .leading) {
                            HStack {
                                Text(entry.objectName)
                                Spacer()
                                StatusBadge(status: entry.status)
                            }
                            if case .failed(let reason) = entry.status {
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            }
                            if case .blocked(let reason) = entry.status {
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            let warned = report.allWarnings
            if !warned.isEmpty {
                Section("Check these") {
                    ForEach(warned, id: \.objectId) { entry in
                        VStack(alignment: .leading) {
                            Text(entry.objectName)
                            ForEach(entry.warnings, id: \.self) { warning in
                                Text(warning).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var typeKeys: [String] {
        var seen = [String]()
        for entry in report.entries where !seen.contains(entry.type) {
            seen.append(entry.type)
        }
        return seen
    }

    private func summary(for entries: [RunReportEntry]) -> String {
        var created = 0, updated = 0, unchanged = 0, deleted = 0, failed = 0, blocked = 0
        for entry in entries {
            switch entry.status {
            case .created: created += 1
            case .updated: updated += 1
            case .unchanged: unchanged += 1
            case .deleted: deleted += 1
            case .failed: failed += 1
            case .blocked: blocked += 1
            }
        }
        var parts = [String]()
        if created > 0 { parts.append("\(created) created") }
        if updated > 0 { parts.append("\(updated) updated") }
        if unchanged > 0 { parts.append("\(unchanged) unchanged") }
        if deleted > 0 { parts.append("\(deleted) deleted") }
        if blocked > 0 { parts.append("\(blocked) blocked") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? "nothing to do" : parts.joined(separator: ", ")
    }
}

private struct StatusBadge: View {
    let status: ObjectStatus

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2), in: .capsule)
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case .created: "Created"
        case .updated: "Updated"
        case .unchanged: "Unchanged"
        case .deleted: "Deleted"
        case .blocked: "Blocked"
        case .failed: "Failed"
        }
    }

    private var color: Color {
        switch status {
        case .created: .green
        case .updated: .blue
        case .unchanged: .secondary
        case .deleted: .red
        case .blocked: .orange
        case .failed: .red
        }
    }
}
