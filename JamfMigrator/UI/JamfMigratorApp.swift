//
//  JamfMigratorApp.swift
//  JamfMigrator
//
//  The SwiftUI app entry: the main window, the activity log, the About and
//  Settings windows, and the menu commands.
//

import JTKit
import SwiftUI

@main
struct JamfMigratorApp: App {

    @State private var appState = AppState.forLaunch()
    @State private var updates = UpdateChecker(
        configuration: UpdateConfiguration(owner: "JordyThery", repository: "JamfMigrator", appName: "Jamf Migrator"),
        activity: { line in
            AppActivity.record(line, category: "Updates",
                               level: line.hasPrefix("Update check failed") ? .warning : .info)
        }
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(updates)
                .environment(appState.demo)
                // a sandbox run (UI tests) makes no update check
                .task { if !appState.demo.isSandbox { await updates.checkAutomatically() } }
        }
        .commands {
            AppInfoCommands(appName: "Jamf Migrator") { updates.checkManually() }

            // JTKit's Connection menu, with the same choices as the sidebar:
            // Source and Destination, or only the tenant in delete mode, and
            // Demo Mode below them.
            ConnectionCommands(store: appState.tenantStore.connections, roles: appState.connectionRoles,
                               editTitle: "Edit Tenants…") {
                DemoModeToggle(demo: appState.demo)
                    .disabled(appState.isRunning || appState.isPlanning)
            }

            CommandGroup(after: .help) {
                Button("Guided Tour") { appState.tour.start() }
            }

            CommandMenu("Migration") {
                Button(appState.mode == .copy ? "Enter Delete Mode" : "Leave Delete Mode") {
                    appState.mode = appState.mode == .copy ? .delete : .copy
                }
                .keyboardShortcut("d", modifiers: .command)

                Divider()

                Button("Preview") { appState.preview() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!appState.canPreview)
                // routes through ContentView so the same confirmation dialog
                // appears as for the toolbar button
                Button("Run") { appState.runRequested = true }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!appState.canRun)
            }
        }

        // JTKit's shared activity log (Window › Activity Log, ⇧⌘L). It replaces
        // jamfmigrator.log, which stays on disk and is no longer written.
        ActivityLogWindow(
            log: AppActivity.log,
            emptyDescription: "Sign-ins, API calls, retries, update checks and run problems appear here as they happen."
        )

        AboutWindow(configuration: .jamfMigrator)

        // JTKit's Settings window: General (Appearance), the app's Connections,
        // Secrets and Export tabs, then Updates. Every tab has a name, so
        // "Add tenants in Settings…" can open Connections.
        SettingsWindow(updates: updates, opensTabsByName: true) {
            Group {
                ConnectionsSettings()
                SecretsSettings()
                ExportSettings()
            }
            .environment(appState)
            .environment(appState.demo)
        }
    }
}
