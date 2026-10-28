//
//  SettingsView.swift
//  JamfMigrator
//
//  The app's own Settings tabs: Connections (JTKit's shared tenants list,
//  with the Protected toggle), the service-account secrets used by
//  transforms, and export options. JTKit's `SettingsWindow` adds General
//  before them and Updates after them.
//

import JTKit
import SwiftUI

/// The size every Jamf Migrator tab had in its own Settings window, kept so
/// the tabs look as before.
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
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("A protected tenant can never be wiped. Recommended for the source tenant.")
                    if !tenant.usesGateway {
                        Text("Blueprints and Compliance Benchmarks need the Platform API and are unavailable over a direct connection.")
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
            Text("The API never returns these passwords. When set here, runs write them to the destination instead of the \"\(placeholderSecret)\" placeholder.")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SecureField(label, text: $value)
                .onAppear { value = appState.serviceSecret(key) }
                .onChange(of: value) {
                    saveFailed = !appState.setServiceSecret(value, for: key)
                }
            if saveFailed {
                Text("The Keychain refused to save this password.")
                    .font(.caption)
                    .foregroundStyle(.red)
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
            Text("Each run writes the raw source payloads and the trimmed payloads that were sent, per object, under Application Support › JamfMigrator › exports.")
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
