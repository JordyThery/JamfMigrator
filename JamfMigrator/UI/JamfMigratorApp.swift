//
//  JamfMigratorApp.swift
//  JamfMigrator
//
//  The SwiftUI app entry: the main window, the Settings scene, and the
//  menu commands.
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
                Button("Check for Updates…") { updates.checkManually() }
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
                // routes through ContentView so the same confirmation dialog
                // appears as for the toolbar button
                Button("Run") { appState.runRequested = true }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!appState.canRun)
            }
        }

        Settings {
            SettingsView()
                .environment(appState)
                .environment(updates)
        }
    }
}
