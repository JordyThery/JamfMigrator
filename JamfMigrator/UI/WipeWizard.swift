//
//  WipeWizard.swift
//  JamfMigrator
//
//  The gated "Wipe tenant" flow. Every gate must pass, in order: delete mode
//  is on (the button only exists there), the tenant isn't protected, the
//  dry-run preview, a verified backup (skippable only through an extra
//  confirmation), and finally typing the tenant's name before a destructive
//  button that names the tenant and the object count.
//

import SwiftUI

struct WipeWizard: View {

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var typedName = ""
    @State private var backupSkipped = false
    @State private var showSkipBackupConfirmation = false
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Wipe \(tenantName)", systemImage: "trash.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.red)
                Spacer()
                Button("Close") { dismiss() }
                    .disabled(appState.isRunning || appState.isBackingUp)
            }
            .padding()

            Divider()

            if let tenant = appState.destTenant, tenant.isProtected {
                ContentUnavailableView {
                    Label("\(tenant.name) is protected", systemImage: "lock.fill")
                } description: {
                    Text("A protected tenant can't be wiped at all. Switch protection off in Settings › Tenants first.")
                }
            } else if started || appState.isRunning || appState.report != nil {
                runSection
            } else {
                gatesForm
            }
        }
        .frame(minWidth: 620, minHeight: 500)
        .onAppear {
            if appState.plan == nil && !appState.isPlanning {
                appState.preview()
            }
        }
    }

    private var tenantName: String {
        appState.destTenant?.name ?? "?"
    }

    // MARK: Gates

    private var gatesForm: some View {
        Form {
            Section("1 — Preview") {
                if appState.isPlanning {
                    ProgressView("Planning… \(appState.planningStatus)")
                } else if let plan = appState.plan, plan.mode == .delete {
                    let counts = plan.counts
                    Label("\(counts.delete) objects will be deleted; \(counts.keep) built-ins are kept.",
                          systemImage: "checkmark.circle.fill")
                    Text("Close the wizard to review the full list in the main window; untick anything to keep it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Preview what will be deleted") { appState.preview() }
                }
            }

            Section("2 — Backup") {
                if appState.isBackingUp {
                    ProgressView("Backing up… \(appState.planningStatus)")
                } else if let result = appState.backupResult {
                    if result.isComplete {
                        Label("Backup complete: \(result.totalObjects) objects in \(result.root.lastPathComponent).",
                              systemImage: "checkmark.circle.fill")
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([result.root])
                        }
                    } else {
                        Label("The backup did not complete.", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        ForEach(result.errors.prefix(5), id: \.self) { error in
                            Text(error).font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Try again") { appState.backup() }
                    }
                } else if backupSkipped {
                    Label("Backup skipped.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Button("Back up \(tenantName) first") { appState.backup() }
                        .buttonStyle(.borderedProminent)
                    Button("Skip the backup…", role: .destructive) {
                        showSkipBackupConfirmation = true
                    }
                    .confirmationDialog("Skip the backup?", isPresented: $showSkipBackupConfirmation) {
                        Button("I don't need a backup", role: .destructive) { backupSkipped = true }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Without a backup there is no way to restore anything this wipe deletes.")
                    }
                }
            }

            Section("3 — Confirm") {
                TextField("Type the tenant's name: \(tenantName)", text: $typedName)
                    .autocorrectionDisabled()
                Button("Delete \(deleteCount) objects from \(tenantName)", role: .destructive) {
                    started = true
                    appState.run()
                }
                .disabled(!allGatesPass)
                .help(allGatesPass ? "" : "Finish the preview and the backup, and type the tenant's name exactly.")
            }
        }
        .formStyle(.grouped)
    }

    private var deleteCount: Int {
        appState.plan?.counts.delete ?? 0
    }

    private var allGatesPass: Bool {
        guard appState.mode == .delete,
              let tenant = appState.destTenant, !tenant.isProtected,
              let plan = appState.plan, plan.mode == .delete, plan.counts.delete > 0,
              typedName == tenant.name else { return false }
        return backupSkipped || appState.backupResult?.isComplete == true
    }

    // MARK: Run and leftovers

    private var runSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if appState.isRunning {
                if let latest = appState.runEvents.last {
                    let typeName = ObjectRegistry.type(latest.type)?.displayName ?? latest.type
                    ProgressView(value: Double(latest.completed), total: Double(max(latest.total, 1))) {
                        Text("Deleting \(typeName): \(latest.objectName)").lineLimit(1)
                    }
                } else {
                    ProgressView("Starting…")
                }
                HStack {
                    Spacer()
                    Button("Stop", role: .destructive) { appState.cancel() }
                }
            } else if let report = appState.report {
                let leftovers = report.failures
                Label(leftovers.isEmpty
                      ? "Wipe finished: \(report.entries.count) objects deleted."
                      : "Wipe finished, but \(leftovers.count) objects could not be deleted.",
                      systemImage: leftovers.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(leftovers.isEmpty ? .green : .orange)
                    .font(.headline)
                if !leftovers.isEmpty {
                    List(leftovers, id: \.objectId) { entry in
                        VStack(alignment: .leading) {
                            Text(entry.objectName)
                            if case .failed(let reason) = entry.status {
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Run again (retries the leftovers)") {
                        appState.run()
                    }
                }
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
    }
}
