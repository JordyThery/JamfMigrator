//
//  SidebarView.swift
//  JamfMigrator
//
//  Source and destination tenants, then the object types grouped by step,
//  each with its selection checkbox and the plan's counts.
//

import SwiftUI

struct SidebarView: View {

    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var appState = appState

        List(selection: $appState.selectedTypeKey) {
            Section("Tenants") {
                if appState.mode == .copy {
                    TenantPicker(title: "Source", selection: $appState.sourceTenantID)
                }
                TenantPicker(title: appState.mode == .copy ? "Destination" : "Tenant",
                             selection: $appState.destTenantID)
                if appState.tenantStore.tenants.isEmpty {
                    Button("Add tenants in Settings…") { openSettings() }
                        .buttonStyle(.link)
                }
                if let preflight = appState.preflight, appState.mode == .copy {
                    PreflightSummary(preflight: preflight)
                }
            }

            ForEach(steps, id: \.self) { step in
                Section("Step \(step)") {
                    ForEach(types(in: step)) { type in
                        TypeRow(type: type)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay(alignment: .bottom) {
            if appState.isPlanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(appState.planningStatus)
                        .font(.caption)
                        .lineLimit(1)
                }
                .padding(8)
            }
        }
    }

    private var steps: [Int] {
        Array(Set(ObjectRegistry.types.map(\.step))).sorted()
    }

    private func types(in step: Int) -> [ObjectType] {
        ObjectRegistry.types.filter { $0.step == step }
    }
}

private struct TenantPicker: View {
    @Environment(AppState.self) private var appState
    let title: String
    @Binding var selection: Tenant.ID?

    var body: some View {
        Picker(title, selection: $selection) {
            Text("None").tag(Tenant.ID?.none)
            ForEach(appState.tenantStore.tenants) { tenant in
                Text(tenant.name).tag(Tenant.ID?.some(tenant.id))
            }
        }
    }
}

private struct PreflightSummary: View {
    let preflight: PreflightReport

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("\(preflight.source.version ?? "?") → \(preflight.destination.version ?? "?")",
                  systemImage: preflight.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(preflight.isReady ? .green : .orange)
            if !preflight.deniedTypes.isEmpty {
                Text("No permission: \(preflight.deniedTypes.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !preflight.destinationIsEmpty {
                Text("The destination is not empty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

private struct TypeRow: View {
    @Environment(AppState.self) private var appState
    let type: ObjectType

    var body: some View {
        @Bindable var appState = appState
        HStack {
            Toggle(type.displayName, isOn: .init(
                get: { appState.selectedTypeKeys.contains(type.key) },
                set: { included in
                    if included {
                        appState.selectedTypeKeys.insert(type.key)
                    } else {
                        appState.selectedTypeKeys.remove(type.key)
                    }
                }))
                .toggleStyle(.checkbox)
            Spacer()
            if let plan = appState.plan {
                PlanBadge(entries: plan.entries(for: type.key), mode: plan.mode)
            }
        }
        .tag(type.key)
    }
}

/// Compact counts for a type: "3+ 1± 7=" in copy mode, "12−" in delete mode.
private struct PlanBadge: View {
    let entries: [ObjectPlan]
    let mode: RunMode

    var body: some View {
        if !entries.isEmpty {
            Text(summary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        var create = 0, update = 0, unchanged = 0, blocked = 0, delete = 0
        for entry in entries {
            switch entry.change {
            case .create: create += 1
            case .update: update += 1
            case .unchanged: unchanged += 1
            case .blocked: blocked += 1
            case .delete: delete += 1
            case .keep: break
            }
        }
        if mode == .delete { return "\(delete)−" }
        var parts = [String]()
        if create > 0 { parts.append("\(create)+") }
        if update > 0 { parts.append("\(update)±") }
        if unchanged > 0 { parts.append("\(unchanged)=") }
        if blocked > 0 { parts.append("\(blocked)✕") }
        return parts.joined(separator: " ")
    }
}
