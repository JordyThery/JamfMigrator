//
//  ContentView.swift
//  JamfMigrator
//
//  The three-part window: sidebar (tenants + object types), object list, and
//  the diff inspector. Delete mode shows a red banner and a red Run button,
//  and every run in delete mode asks for confirmation with the tenant's name
//  and the planned counts.
//

import SwiftUI

struct ContentView: View {

    @Environment(AppState.self) private var appState
    @State private var showRunConfirmation = false
    @State private var showRunSheet = false

    var body: some View {
        @Bindable var appState = appState

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } content: {
            ObjectListView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 420)
        } detail: {
            InspectorView()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if appState.mode == .delete {
                DeleteModeBanner()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Mode", selection: $appState.mode) {
                    Label("Copy", systemImage: "doc.on.doc").tag(RunMode.copy)
                    Label("Delete", systemImage: "trash").tag(RunMode.delete)
                }
                .pickerStyle(.segmented)
                .help("Delete mode stays on for the session (⌘D) and always starts off at launch.")

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
            }
        }
        .confirmationDialog(runConfirmationTitle, isPresented: $showRunConfirmation) {
            Button(appState.mode == .delete ? "Delete \(appState.plan?.changeCount ?? 0) objects" : "Copy \(appState.plan?.changeCount ?? 0) changes",
                   role: appState.mode == .delete ? .destructive : nil) {
                appState.run()
                showRunSheet = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(runConfirmationMessage)
        }
        .sheet(isPresented: $showRunSheet) {
            RunView()
        }
        .alert("Something went wrong", isPresented: .init(
            get: { appState.lastError != nil },
            set: { if !$0 { appState.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.lastError ?? "")
        }
    }

    private var runConfirmationTitle: String {
        let tenant = appState.destTenant?.name ?? "the destination"
        return appState.mode == .delete
            ? "Delete objects from \(tenant)?"
            : "Copy to \(tenant)?"
    }

    private var runConfirmationMessage: String {
        guard let counts = appState.plan?.counts else { return "" }
        if appState.mode == .delete {
            return "\(counts.delete) objects will be deleted from \(appState.destTenant?.name ?? "the destination"); \(counts.keep) built-ins are kept. This cannot be undone."
        }
        return "\(counts.create) to create, \(counts.update) to update, \(counts.unchanged) unchanged, \(counts.blocked) blocked."
    }
}

struct DeleteModeBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Delete mode — runs remove objects from the destination tenant")
                .fontWeight(.semibold)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.red, in: .rect)
        .foregroundStyle(.white)
    }
}
