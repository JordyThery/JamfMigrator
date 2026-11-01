//
//  ObjectListView.swift
//  JamfMigrator
//
//  The middle column: the selected type's objects with their dry-run outcome,
//  a search field, and per-object checkboxes to exclude objects from the run.
//

import JTKit
import SwiftUI

struct ObjectListView: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        Group {
            if appState.isPlanning {
                PlanningProgressView()
            } else if appState.plan == nil {
                ContentUnavailableView("No Preview Yet",
                                       systemImage: "eye",
                                       description: Text("Select the tenants, then click Preview to see what would change."))
            } else if appState.selectedTypeKey == nil || appState.selectedTypeKey == AppState.summaryKey {
                PlanSummaryView()
            } else {
                List(selection: $appState.selectedObjectID) {
                    Section {
                        ForEach(filteredEntries) { entry in
                            ObjectRow(entry: entry)
                                .tag(entry.id)
                        }
                    } header: {
                        if let typeKey = appState.selectedTypeKey {
                            TypeCounts(typeKey: typeKey, shown: filteredEntries.count)
                        }
                    }
                }
            }
        }
        .searchable(text: $appState.searchText, placement: .automatic, prompt: "Filter by name")
        .navigationTitle(typeTitle)
        .toolbar {
            if let typeKey = appState.selectedTypeKey, typeKey != AppState.summaryKey, appState.plan != nil {
                ToolbarItem {
                    Menu("Select", systemImage: "checklist") {
                        Button("Check All") {
                            appState.setAllIncluded(true, typeKey: typeKey)
                        }
                        Button("Uncheck All") {
                            appState.setAllIncluded(false, typeKey: typeKey)
                        }
                    }
                    .help("Check or uncheck every object of this type.")
                }
            }
        }
    }

    private var typeTitle: String {
        guard appState.plan != nil else { return "Objects" }
        if appState.selectedTypeKey == nil || appState.selectedTypeKey == AppState.summaryKey { return "Summary" }
        return appState.selectedTypeKey.flatMap { ObjectRegistry.type($0)?.displayName } ?? "Objects"
    }

    private var filteredEntries: [ObjectPlan] {
        guard let plan = appState.plan, let typeKey = appState.selectedTypeKey else { return [] }
        let entries = plan.entries(for: typeKey)
        guard !appState.searchText.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(appState.searchText) }
    }
}

/// The selected type's outcomes in a line, and how many of its changes
/// are checked: "2 to create · 1 to update · 4 unchanged — 3 of 3 checked".
private struct TypeCounts: View {
    @Environment(AppState.self) private var appState
    let typeKey: String
    /// How many rows the filter leaves.
    let shown: Int

    var body: some View {
        let entries = appState.plan?.entries(for: typeKey) ?? []
        Text(Self.summary(entries, checked: entries.filter(appState.isIncluded).count, shown: shown))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .textCase(nil)
    }

    static func summary(_ entries: [ObjectPlan], checked: Int, shown: Int) -> String {
        var create = 0, update = 0, replace = 0, delete = 0, unchanged = 0, blocked = 0, kept = 0
        for entry in entries {
            switch entry.change {
            case .create: create += 1
            case .update: update += 1
            case .replace: replace += 1
            case .delete: delete += 1
            case .unchanged: unchanged += 1
            case .blocked: blocked += 1
            case .keep: kept += 1
            }
        }
        var parts = [String]()
        if create > 0 { parts.append("\(create) to create") }
        if update > 0 { parts.append("\(update) to update") }
        if replace > 0 { parts.append("\(replace) to replace") }
        if delete > 0 { parts.append("\(delete) to delete") }
        if unchanged > 0 { parts.append("\(unchanged) unchanged") }
        if blocked > 0 { parts.append("\(blocked) blocked") }
        if kept > 0 { parts.append("\(kept) kept") }
        var line = parts.isEmpty ? "No objects" : parts.joined(separator: " · ")
        let runnable = create + update + replace + delete
        if runnable > 0 { line += " — \(checked) of \(runnable) checked" }
        if shown < entries.count { line += " (\(shown) shown)" }
        return line
    }
}

private struct ObjectRow: View {
    @Environment(AppState.self) private var appState
    let entry: ObjectPlan

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: includedBinding)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Include \(entry.name.isEmpty ? "this object" : entry.name)")
                .disabled(!entry.change.isRunnable)
                .help("Uncheck to leave this object out of the run.")
            Text(entry.name.isEmpty ? "(unnamed)" : entry.name)
                .lineLimit(1)
            if let needing = appState.waitingOn(entry).first {
                StatusLabel("Needed by “\(needing.name)”", systemImage: "link", color: .orange)
                    .font(.caption)
                    .help("A checked object refers to this one, which the run would create. Check it, or uncheck the objects that need it.")
            }
            if !entry.warnings.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .help(entry.warnings.joined(separator: "\n"))
                    .accessibilityLabel("Warnings")
                    .accessibilityValue(entry.warnings.joined(separator: " "))
            }
            Spacer()
            ChangeBadge(change: entry.change)
        }
    }

    private var includedBinding: Binding<Bool> {
        Binding(
            get: { appState.isIncluded(entry) },
            set: { appState.setIncluded($0, entry) })
    }
}

/// A plan or run row's outcome: JTKit's `StatusBadge`, primary text on a
/// wash of the outcome's color (stronger under Increase Contrast), so the
/// word stays readable; nil color: the neutral badge.
struct OutcomeBadge: View {
    let label: String
    let color: Color?

    var body: some View {
        StatusBadge(label, style: color.map { .colored($0) } ?? .neutral)
    }
}

/// Labels below it get their status color on the symbol only; the text
/// stays primary (`StatusLabel` for a single one).
struct StatusIconLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon.foregroundStyle(color)
        }
    }
}

extension View {
    /// The status color on the symbols of the labels below, not their text.
    func statusColor(_ color: Color) -> some View {
        labelStyle(StatusIconLabelStyle(color: color))
    }
}

/// A status line whose symbol carries the color and whose text stays in the
/// primary color, so it reads at full contrast and doesn't rely on color.
struct StatusLabel: View {
    let text: String
    let systemImage: String
    let color: Color

    init(_ text: String, systemImage: String, color: Color) {
        self.text = text
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(color)
        }
    }
}

/// A planned change's badge.
struct ChangeBadge: View {
    let change: PlannedChange

    var body: some View {
        OutcomeBadge(label: label, color: color)
    }

    private var label: String {
        switch change {
        case .create: "Create"
        case .update: "Update"
        case .replace: "Replace"
        case .unchanged: "Unchanged"
        case .blocked: "Blocked"
        case .delete: "Delete"
        case .keep: "Kept"
        }
    }

    private var color: Color? {
        switch change {
        case .create: .green
        case .update: .blue
        case .replace: .purple
        case .unchanged: nil
        case .blocked: .orange
        case .delete: .red
        case .keep: nil
        }
    }
}

extension PlannedChange {
    /// Whether a run would touch this object at all.
    var isRunnable: Bool {
        switch self {
        case .create, .update, .replace, .delete: true
        case .unchanged, .blocked, .keep: false
        }
    }
}
