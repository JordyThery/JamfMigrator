//
//  ContentView.swift
//  JamfMigrator
//
//  The three-part window: sidebar (tenants + object types), object list, and
//  the diff inspector. Delete mode shows a red banner and a red Run button,
//  and every run in delete mode asks for confirmation with the tenant's name
//  and the planned counts.
//

import JTKit
import SwiftUI

struct ContentView: View {

    @Environment(AppState.self) private var appState
    @Environment(UpdateChecker.self) private var updates
    @State private var showRunConfirmation = false
    @State private var showRunSheet = false
    @State private var showCloneWizard = false
    @State private var showWipeWizard = false

    var body: some View {
        @Bindable var appState = appState

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } content: {
            ObjectListView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 420)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tourAnchor(TourAnchorID.plan)
        } detail: {
            InspectorView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tourAnchor(TourAnchorID.inspector)
        }
        .guidedTour(appState.tour)
        .safeAreaInset(edge: .top, spacing: 0) {
            if appState.mode == .delete {
                DeleteModeBanner()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // why Run is off although there is a plan
            if !appState.isRunning, !appState.isPlanning, let reason = appState.runBlockedReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Mode", selection: $appState.mode) {
                    Label("Copy", systemImage: "doc.on.doc").tag(RunMode.copy)
                    Label("Delete", systemImage: "trash").tag(RunMode.delete)
                }
                .pickerStyle(.segmented)
                .disabled(!appState.canChangeTenants)
                .help("Delete mode stays on for the session (⌘D). The app always launches in Copy mode.")

                if appState.mode == .copy {
                    Button("Clone Tenant", systemImage: "wand.and.stars") {
                        showCloneWizard = true
                    }
                    .disabled(!appState.canClone)
                    .help("Opens the guided clone flow: connect, map, preview, run, and verify.")
                } else {
                    Button("Wipe Tenant", systemImage: "xmark.bin") {
                        showWipeWizard = true
                    }
                    .tint(.red)
                    .disabled(!appState.canWipe)
                    .help("Deletes every selected object type from the tenant, behind gates: a preview, a backup, and typing the tenant’s name.")
                }

                Button("Preview", systemImage: "eye") {
                    appState.preview()
                }
                .disabled(!appState.canPreview)
                .help("Dry run: read both tenants and show what would change.")

                Button("Run", systemImage: appState.mode == .delete ? "trash.fill" : "play.fill") {
                    showRunConfirmation = true
                }
                .tint(appState.mode == .delete ? .red : nil)
                .buttonStyle(.borderedProminent)
                .disabled(!appState.canRun)
                .help(appState.runBlockedReason ?? "Carries out the plan Preview showed: the checked objects only.")
            }
        }
        // demo mode on or off, or another tenant: the plan is for other tenants
        .onChange(of: appState.demo.isOn) { appState.tenantsChanged(demoSwitched: true) }
        .onChange(of: appState.tenantPairKey) { appState.tenantsChanged(demoSwitched: false) }
        .onChange(of: appState.cloneRequested) { _, requested in
            if requested {
                appState.cloneRequested = false
                showCloneWizard = true
            }
        }
        .onChange(of: appState.wipeRequested) { _, requested in
            if requested {
                appState.wipeRequested = false
                showWipeWizard = true
            }
        }
        .onChange(of: appState.runRequested) { _, requested in
            if requested {
                appState.runRequested = false
                showRunConfirmation = true
            }
        }
        .confirmationDialog(runConfirmationTitle, isPresented: $showRunConfirmation) {
            Button(appState.runConfirmationButton, role: appState.mode == .delete ? .destructive : nil) {
                appState.run()
                if appState.lastError == nil {
                    showRunSheet = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(runConfirmationMessage)
        }
        .sheet(isPresented: $showRunSheet) {
            RunView()
        }
        .sheet(isPresented: $showCloneWizard) {
            CloneWizard()
        }
        .sheet(isPresented: $showWipeWizard) {
            WipeWizard()
        }
        .sheet(isPresented: .init(
            get: { updates.isPresented },
            set: { updates.isPresented = $0 })) {
            UpdateView()
                .environment(updates)
        }
        .alert("Can’t Complete This Action", isPresented: .init(
            get: { appState.lastError != nil },
            set: { if !$0 { appState.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.lastError ?? "")
        }
    }

    private var runConfirmationTitle: String { appState.runConfirmationTitle }

    private var runConfirmationMessage: String { appState.runConfirmationMessage }
}

/// Delete mode's banner across the window: which tenant a run deletes
/// from, and the way back to Copy.
struct DeleteModeBanner: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash.fill")
                .accessibilityHidden(true)
            Text(message)
                .fontWeight(.semibold)
                .lineLimit(2)
            Spacer()
            Button("Switch to Copy") { appState.mode = .copy }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!appState.canChangeTenants)
                .help("Leaves delete mode (⌘D).")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red, in: .rect)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Delete mode")
    }

    private var message: String {
        if let tenant = appState.destTenant?.name {
            return "Delete mode: a run deletes the checked objects from \(tenant)."
        }
        return "Delete mode: choose the tenant to delete from."
    }
}
