//
//  PlanSummaryView.swift
//  JamfMigrator
//
//  The middle column around a dry run: a prominent progress view while the
//  planner works, and the summary it lands on afterwards — totals and
//  every planned type with its counts.
//

import SwiftUI

/// Shown while a preview runs; planning a whole tenant takes minutes.
struct PlanningProgressView: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "eye")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Planning the dry run")
                .font(.title3.weight(.semibold))

            Group {
                if appState.planningStep == 0 {
                    ProgressView()
                        .progressViewStyle(.linear)
                } else {
                    ProgressView(value: Double(appState.planningStep),
                                 total: Double(max(appState.planningTotal, 1)))
                }
            }
            .frame(maxWidth: 320)

            Text(statusLine)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("Both tenants are read; nothing is written.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusLine: String {
        guard appState.planningStep > 0 else { return "\(appState.planningStatus)…" }
        return "\(appState.planningStatus) — type \(appState.planningStep) of \(appState.planningTotal)"
    }
}

/// The overview a finished dry run opens on.
struct PlanSummaryView: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        if let plan = appState.plan {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(plan)
                    totals(plan)
                    if unchecked(plan) > 0 {
                        Label("\(Plural.count(unchecked(plan), "unchecked object")) \(unchecked(plan) == 1 ? "is" : "are") left out of the run.",
                              systemImage: "checklist.unchecked")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if warningCount(plan) > 0 {
                        StatusLabel("\(Plural.count(warningCount(plan), "object")) \(warningCount(plan) == 1 ? "has" : "have") warnings to review after the run.",
                                    systemImage: "exclamationmark.triangle.fill", color: .orange)
                            .font(.callout)
                    }
                    perType(plan)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Sections

    private func header(_ plan: MigrationPlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(plan.mode == .copy
                 ? "\(appState.sourceTenant?.name ?? "Source") → \(appState.destTenant?.name ?? "Destination")"
                 : "Delete from \(appState.destTenant?.name ?? "the tenant")")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(appState.effectiveChangeCount == 0
                 ? "Nothing to do — the destination already matches."
                 : "Select a type below or in the sidebar to review its objects, then Run.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func totals(_ plan: MigrationPlan) -> some View {
        let counts = plan.counts
        let effective = appState.effectiveCounts
        return HStack(spacing: 10) {
            if plan.mode == .copy {
                CountTile(value: effective.create, label: "Create", color: .green)
                CountTile(value: effective.update, label: "Update", color: .blue)
                if counts.replace > 0 {
                    CountTile(value: effective.replace, label: "Replace", color: .purple)
                }
                CountTile(value: counts.unchanged, label: "Unchanged", color: .secondary)
                CountTile(value: counts.blocked, label: "Blocked", color: .orange)
            } else {
                CountTile(value: effective.delete, label: "Delete", color: .red)
                CountTile(value: counts.keep, label: "Kept", color: .secondary)
                if counts.blocked > 0 {
                    CountTile(value: counts.blocked, label: "Blocked", color: .orange)
                }
            }
        }
    }

    private func perType(_ plan: MigrationPlan) -> some View {
        let rows = ObjectRegistry.types.filter { !plan.entries(for: $0.key).isEmpty }
        return VStack(alignment: .leading, spacing: 0) {
            Text("Per Type")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 6)
            ForEach(rows) { type in
                Button {
                    appState.selectedTypeKey = type.key
                } label: {
                    HStack {
                        Text(type.displayName)
                        Spacer()
                        Text(rowSummary(plan.entries(for: type.key), mode: plan.mode))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 6)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows this type’s objects.")
                Divider()
            }
        }
    }

    // MARK: Helpers

    private func rowSummary(_ entries: [ObjectPlan], mode: RunMode) -> String {
        var create = 0, update = 0, unchanged = 0, blocked = 0, delete = 0, keep = 0
        for entry in entries {
            switch entry.change {
            case .create: create += 1
            case .update, .replace: update += 1
            case .unchanged: unchanged += 1
            case .blocked: blocked += 1
            case .delete: delete += 1
            case .keep: keep += 1
            }
        }
        var parts = [String]()
        if mode == .delete {
            if delete > 0 { parts.append("\(delete) to delete") }
            if keep > 0 { parts.append("\(keep) kept") }
        } else {
            if create > 0 { parts.append("\(create) to create") }
            if update > 0 { parts.append("\(update) to update") }
            if unchanged > 0 { parts.append("\(unchanged) unchanged") }
        }
        if blocked > 0 { parts.append("\(blocked) blocked") }
        return parts.joined(separator: " · ")
    }

    private func unchecked(_ plan: MigrationPlan) -> Int {
        let counts = plan.counts
        let planned = counts.create + counts.update + counts.replace + counts.delete
        return max(planned - appState.effectiveChangeCount, 0)
    }

    private func warningCount(_ plan: MigrationPlan) -> Int {
        plan.entries.filter { !$0.warnings.isEmpty }.count
    }
}

private struct CountTile: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            // the number in the primary color reads at full contrast; the
            // color is a mark beside the label, never the only cue
            Text("\(value)")
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(value == 0 ? Color.secondary : Color.primary)
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .opacity(value == 0 ? 0.4 : 1)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 72)
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }
}
