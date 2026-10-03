//
//  JamfMigratorApp.swift
//  JamfMigrator
//
//  The SwiftUI app entry. The legacy storyboard UI is no longer launched and
//  is deleted in Phase 7.
//

import SwiftUI

@main
struct JamfMigratorApp: App {

    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
        .commands {
            CommandMenu("Migration") {
                Button(appState.mode == .copy ? "Enter Delete Mode" : "Leave Delete Mode") {
                    appState.mode = appState.mode == .copy ? .delete : .copy
                }
                .keyboardShortcut("d", modifiers: .command)

                Divider()

                Button("Preview") { appState.preview() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!appState.canPreview)
                Button("Run") { appState.run() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!appState.canRun)
            }
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
