//
//  ObjectListView.swift
//  JamfMigrator
//
//  The middle column: the selected type's objects with their dry-run outcome,
//  a search field, and per-object checkboxes to exclude objects from the run.
//

import SwiftUI

struct ObjectListView: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        Group {
            if appState.plan == nil {
                ContentUnavailableView("No preview yet",
                                       systemImage: "eye",
                                       description: Text("Select the tenants, then click Preview to see what would change."))
            } else if appState.selectedTypeKey == nil {
                ContentUnavailableView("No object type selected",
                                       systemImage: "sidebar.left",
                                       description: Text("Select a type in the sidebar."))
            } else {
                List(filteredEntries, selection: $appState.selectedObjectID) { entry in
                    ObjectRow(entry: entry)
                        .tag(entry.id)
                }
            }
        }
        .searchable(text: $appState.searchText, placement: .automatic, prompt: "Filter by name")
        .navigationTitle(typeTitle)
        .toolbar {
            if let typeKey = appState.selectedTypeKey, appState.plan != nil {
                ToolbarItem {
                    Menu("Select", systemImage: "checklist") {
                        Button("Check all") {
                            appState.excludedObjectIds[typeKey] = []
                        }
                        Button("Uncheck all") {
                            appState.excludedObjectIds[typeKey] = Set(
                                appState.plan?.entries(for: typeKey).map(\.objectId) ?? [])
                        }
                    }
                    .help("Check or uncheck every object of this type.")
                }
            }
        }
    }

    private var typeTitle: String {
        guard appState.plan != nil else { return "Objects" }
        return appState.selectedTypeKey.flatMap { ObjectRegistry.type($0)?.displayName } ?? "Objects"
    }

    private var filteredEntries: [ObjectPlan] {
        guard let plan = appState.plan, let typeKey = appState.selectedTypeKey else { return [] }
        let entries = plan.entries(for: typeKey)
        guard !appState.searchText.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(appState.searchText) }
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
                .disabled(!entry.change.isRunnable)
                .help("Uncheck to leave this object out of the run.")
            Text(entry.name.isEmpty ? "(unnamed)" : entry.name)
                .lineLimit(1)
            if !entry.warnings.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(entry.warnings.joined(separator: "\n"))
            }
            Spacer()
            ChangeBadge(change: entry.change)
        }
    }

    private var includedBinding: Binding<Bool> {
        Binding(
            get: { !(appState.excludedObjectIds[entry.typeKey]?.contains(entry.objectId) ?? false) },
            set: { included in
                if included {
                    appState.excludedObjectIds[entry.typeKey]?.remove(entry.objectId)
                } else {
                    appState.excludedObjectIds[entry.typeKey, default: []].insert(entry.objectId)
                }
            })
    }
}

struct ChangeBadge: View {
    let change: PlannedChange

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2), in: .capsule)
            .foregroundStyle(color)
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

    private var color: Color {
        switch change {
        case .create: .green
        case .update: .blue
        case .replace: .purple
        case .unchanged: .secondary
        case .blocked: .orange
        case .delete: .red
        case .keep: .secondary
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
