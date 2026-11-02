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
            VStack(alignment: .leading, spacing: 12) {
                if entry.diff.isEmpty {
                    ScrollView {
                        details(entry)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    // the outcome above, the differences in a table below,
                    // sortable by field, source or destination value
                    details(entry)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Differences (source → destination)")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    DiffTable(entries: entry.diff)
                        // a new object starts in the plan's own order
                        .id(entry.id)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView("No Object Selected",
                                   systemImage: "doc.text.magnifyingglass",
                                   description: Text("Select an object to see its details and diff."))
        }
    }

    @ViewBuilder
    private func details(_ entry: ObjectPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(entry.name.isEmpty ? "(unnamed)" : entry.name)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                ChangeBadge(change: entry.change)
            }

            if case .blocked(let reason) = entry.change {
                Label(reason, systemImage: "hand.raised.fill")
                    .statusColor(.orange)
            }
            if case .keep(let reason) = entry.change {
                Label(reason, systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }

            if !entry.warnings.isEmpty {
                GroupBox("Review After the Run") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(entry.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            if entry.diff.isEmpty && isUpdateOrReplace(entry.change) {
                Text("No field-level diff is available for this object.")
                    .foregroundStyle(.secondary)
            }
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

/// An object's field-level differences; click a column's title to sort by it.
private struct DiffTable: View {
    let entries: [DiffEntry]
    /// Empty: the plan's own order (by field path).
    @State private var sortOrder: [KeyPathComparator<DiffEntry>] = []

    var body: some View {
        Table(sorted, sortOrder: $sortOrder) {
            TableColumn("Field", value: \.path) { diff in
                Text(diff.path)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .help(diff.path)
                    .accessibilityIdentifier("diff-field")
            }
            TableColumn("Source", value: \.sourceText) { diff in
                DiffValue(text: diff.source)
                    .accessibilityIdentifier("diff-source")
            }
            TableColumn("Destination", value: \.destinationText) { diff in
                DiffValue(text: diff.destination)
                    .accessibilityIdentifier("diff-destination")
            }
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .frame(minHeight: 160)
    }

    private var sorted: [DiffEntry] {
        sortOrder.isEmpty ? entries : entries.sorted(using: sortOrder)
    }
}

private struct DiffValue: View {
    let text: String?

    var body: some View {
        // a missing value says so in words, readable at full contrast
        Text(text ?? "Not set")
            .font(.callout)
            .italic(text == nil)
            .foregroundStyle(text == nil ? .secondary : .primary)
            .textSelection(.enabled)
            .lineLimit(6)
            .help(text ?? "The field isn’t set on this side.")
    }
}

extension DiffEntry: Identifiable {
    var id: String { path }
    /// For sorting: a missing value sorts first.
    var sourceText: String { source ?? "" }
    var destinationText: String { destination ?? "" }
}
