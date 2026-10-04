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
            CommandGroup(replacing: .appInfo) {
                Button("About Jamf Migrator") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(
                            string: "Based on Replicator by Jamf.",
                            attributes: [
                                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                .foregroundColor: NSColor.secondaryLabelColor,
                            ]),
                    ])
                }
            }

            CommandGroup(after: .help) {
                Button("Guided Tour") { appState.startTour() }
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
