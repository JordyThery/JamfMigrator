//
//  InspectorView.swift
//  JamfMigrator
//
//  The detail column: the selected object's outcome, warnings, and the
//  field-level diff between source and destination.
//

import SwiftUI

struct InspectorView: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        if let entry = selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(entry.name.isEmpty ? "(unnamed)" : entry.name)
                            .font(.title2.weight(.semibold))
                        ChangeBadge(change: entry.change)
                    }

                    if case .blocked(let reason) = entry.change {
                        Label(reason, systemImage: "hand.raised.fill")
                            .foregroundStyle(.orange)
                    }
                    if case .keep(let reason) = entry.change {
                        Label(reason, systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                    }

                    if !entry.warnings.isEmpty {
                        GroupBox("Review after the run") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(entry.warnings, id: \.self) { warning in
                                    Label(warning, systemImage: "exclamationmark.triangle")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }

                    if !entry.diff.isEmpty {
                        GroupBox("Differences (source → destination)") {
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                                GridRow {
                                    Text("Field").fontWeight(.semibold)
                                    Text("Source").fontWeight(.semibold)
                                    Text("Destination").fontWeight(.semibold)
                                }
                                Divider()
                                ForEach(entry.diff, id: \.path) { diff in
                                    GridRow(alignment: .top) {
                                        Text(diff.path)
                                            .font(.caption.monospaced())
                                        DiffValue(text: diff.source)
                                        DiffValue(text: diff.destination)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if isUpdateOrReplace(entry.change) {
                        Text("No field-level diff is available for this object.")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("No object selected",
                                   systemImage: "doc.text.magnifyingglass",
                                   description: Text("Select an object to see its details and diff."))
        }
    }

    private func isUpdateOrReplace(_ change: PlannedChange) -> Bool {
        switch change {
        case .update, .replace: true
        default: false
        }
    }

    private var selectedEntry: ObjectPlan? {
        guard let plan = appState.plan, let id = appState.selectedObjectID else { return nil }
        return plan.entries.first { $0.id == id }
    }
}

private struct DiffValue: View {
    let text: String?

    var body: some View {
        Text(text ?? "—")
            .font(.caption)
            .foregroundStyle(text == nil ? .tertiary : .primary)
            .textSelection(.enabled)
            .lineLimit(6)
    }
}
