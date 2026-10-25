//
//  JamfMigratorApp.swift
//  JamfMigrator
//
//  The SwiftUI app entry: the main window, the About and Settings windows,
//  and the menu commands.
//

import JTKit
import SwiftUI

@main
struct JamfMigratorApp: App {

    @State private var appState = AppState()
    @State private var updates = UpdateChecker(
        configuration: UpdateConfiguration(owner: "JordyThery", repository: "JamfMigrator", appName: "Jamf Migrator"),
        activity: { WriteToLog.shared.message("[UpdateChecker] \($0)") }
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(updates)
                .task { await updates.checkAutomatically() }
        }
        .commands {
            AppInfoCommands(appName: "Jamf Migrator") { updates.checkManually() }

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
        }
    }
}
