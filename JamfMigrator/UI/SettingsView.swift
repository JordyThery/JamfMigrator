//
//  SettingsView.swift
//  JamfMigrator
//
//  The app's own Settings tabs: Connections (JTKit's shared tenants list,
//  with the Protected toggle), the service-account secrets used by
//  transforms, and export options. JTKit's `SettingsWindow` adds Updates
//  after them (the app has no General settings of its own).
//

import JTKit
import SwiftUI

/// The height of the app's own Settings tabs.
private let tabHeight: CGFloat = 480

// MARK: - Connections

/// JTKit's shared Connections tab for the tenants. Source and Destination
/// stay chosen in the sidebar too; the buttons here set the same choice.
struct ConnectionsSettings: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        ConnectionsSettingsTab(
            store: appState.tenantStore.connections,
            services: [.jamfPlatform, .jamfPro],
            roles: [appState.sourceRole,
                    ConnectionRole("Destination", selection: $appState.destTenantID, demo: appState.destDemo)],
            height: tabHeight,
            newRecord: { service in
                Tenant(connection: Connection(name: "New tenant", service: service))
            },
            didDelete: { tenant in appState.forgetTenant(tenant.id) },
            test: { tenant, secrets in
                // always the real tenant on the real network, also in demo mode
                let client = appState.tenantStore.testClient(for: tenant, secretOverride: secrets[.main])
                let check = await Preflight.check(client)
                guard check.reachable else {
                    throw TenantTestError(message: check.error ?? "No response.")
                }
                return "Connected · Jamf Pro \(check.version ?? "?")"
            }
        ) { $tenant in
            Section {
                Toggle("Protected", isOn: $tenant.isProtected)
                    .accessibilityIdentifier("tenant-protected")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("A protected tenant can never be wiped. Recommended for the source tenant.")
                    if !tenant.usesGateway {
                        Text("Blueprints and Compliance Benchmarks need the Jamf Platform API gateway; this tenant connects directly to Jamf Pro.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct TenantTestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Service secrets

struct SecretsSettings: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            if appState.demo.isOn {
                Label("Demo Mode is on. These are your real passwords; demo runs write the placeholder instead.",
                      systemImage: "testtube.2")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("The API never returns these passwords. When set here, runs write them to the destination instead of the “\(placeholderSecret)” placeholder.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(AppState.serviceSecretKeys, id: \.key) { entry in
                ServiceSecretField(key: entry.key, label: entry.label)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: SettingsLayout.width, height: tabHeight)
        .tabItem { Label("Secrets", systemImage: "key") }
        .settingsTabName("Secrets")
    }
}

private struct ServiceSecretField: View {

    @Environment(AppState.self) private var appState
    let key: String
    let label: String
    @State private var value = ""
    @State private var saveFailed = false
    @State private var readError: String?
    /// What the Keychain holds (shown or last saved): showing it doesn't save
    /// it; nil until read, or when it couldn't be read.
    @State private var stored: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SecureField(label, text: $value)
                .onAppear {
                    do {
                        let current = try appState.serviceSecret(key)
                        stored = current
                        value = current
                        readError = nil
                    } catch {
                        readError = error.localizedDescription
                    }
                }
                .onChange(of: value) {
                    guard let saved = appState.saveServiceSecretIfChanged(value, for: key, stored: &stored) else { return }
                    saveFailed = !saved
                    if saved { readError = nil }
                }
            if let readError {
                StatusLabel(readError, systemImage: "exclamationmark.triangle.fill", color: .red)
                    .font(.caption)
            } else if saveFailed {
                StatusLabel("The Keychain refused to save this password.", systemImage: "exclamationmark.triangle.fill", color: .red)
                    .font(.caption)
            }
        }
    }
}

// MARK: - Export

struct ExportSettings: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        Form {
            // the app's own settings, so a sandbox run never changes the real one
            Toggle("Save payloads during runs", isOn: $appState.exportOnRun)
            Text("Each run writes the raw source payloads and the trimmed payloads that were sent, per object, under Application Support › JamfMigrator › exports. Passwords, password hashes, Settings › Secrets values and license serial numbers are replaced by “<redacted>”.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: SettingsLayout.width, height: tabHeight)
        .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
        .settingsTabName("Export")
    }
}
