//
//  SettingsView.swift
//  JamfMigrator
//
//  Settings: tenants (with client secret and the Protected toggle), the
//  service-account secrets used by transforms, and export options.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Tenants", systemImage: "building.2") {
                TenantsSettings()
            }
            Tab("Secrets", systemImage: "key") {
                SecretsSettings()
            }
            Tab("Export", systemImage: "square.and.arrow.up") {
                ExportSettings()
            }
        }
        .frame(width: 560, height: 420)
    }
}

// MARK: - Tenants

private struct TenantsSettings: View {

    @Environment(AppState.self) private var appState
    @State private var selectedTenantID: Tenant.ID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(appState.tenantStore.tenants, selection: $selectedTenantID) { tenant in
                    HStack {
                        Text(tenant.name)
                        if tenant.isProtected {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                                .help("Protected: this tenant can never be wiped.")
                        }
                    }
                    .tag(tenant.id)
                }
                HStack {
                    Button("Add", systemImage: "plus") {
                        let tenant = Tenant(name: "New tenant")
                        appState.tenantStore.upsert(tenant)
                        selectedTenantID = tenant.id
                    }
                    Button("Remove", systemImage: "minus") {
                        if let tenant = selectedTenant {
                            appState.tenantStore.remove(tenant)
                            selectedTenantID = nil
                        }
                    }
                    .disabled(selectedTenant == nil)
                    Spacer()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 160, maxWidth: 220)

            if let tenant = selectedTenant {
                TenantEditor(tenant: tenant)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ContentUnavailableView("No tenant selected", systemImage: "building.2")
                    .frame(maxWidth: .infinity)
            }
        }
        .padding()
    }

    private var selectedTenant: Tenant? {
        selectedTenantID.flatMap(appState.tenantStore.tenant(id:))
    }
}

private struct TenantEditor: View {

    @Environment(AppState.self) private var appState
    let tenant: Tenant
    @State private var secret = ""

    var body: some View {
        Form {
            TextField("Name", text: binding(\.name))
            Picker("Region", selection: binding(\.region)) {
                ForEach(Region.allCases) { region in
                    Text(region.displayName).tag(region)
                }
            }
            TextField("Environment ID", text: binding(\.environmentId))
                .font(.body.monospaced())
            TextField("Client ID", text: binding(\.clientId))
                .font(.body.monospaced())
            SecureField("Client secret", text: $secret)
                .onChange(of: secret) {
                    appState.tenantStore.setSecret(secret, for: tenant)
                }
            Toggle("Protected — this tenant can never be wiped", isOn: binding(\.isProtected))
                .help("On by default for the golden master. A protected tenant can't be wiped at all.")
        }
        .formStyle(.grouped)
        .onAppear {
            secret = appState.tenantStore.secret(for: tenant) ?? ""
        }
        .onChange(of: tenant.id) {
            secret = appState.tenantStore.secret(for: tenant) ?? ""
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Tenant, Value>) -> Binding<Value> {
        Binding(
            get: { (appState.tenantStore.tenant(id: tenant.id) ?? tenant)[keyPath: keyPath] },
            set: { newValue in
                var updated = appState.tenantStore.tenant(id: tenant.id) ?? tenant
                updated[keyPath: keyPath] = newValue
                appState.tenantStore.upsert(updated)
            })
    }
}

// MARK: - Service secrets

private struct SecretsSettings: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Text("The API never returns these passwords. When set here, runs write them to the destination instead of the \"\(placeholderSecret)\" placeholder.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(AppState.serviceSecretKeys, id: \.key) { entry in
                ServiceSecretField(key: entry.key, label: entry.label)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct ServiceSecretField: View {

    @Environment(AppState.self) private var appState
    let key: String
    let label: String
    @State private var value = ""

    var body: some View {
        SecureField(label, text: $value)
            .onAppear { value = appState.serviceSecret(key) }
            .onChange(of: value) {
                appState.setServiceSecret(value, for: key)
            }
    }
}

// MARK: - Export

private struct ExportSettings: View {

    @AppStorage("exportOnRun") private var exportOnRun = false

    var body: some View {
        Form {
            Toggle("Save payloads during runs", isOn: $exportOnRun)
            Text("Each run writes the raw source payloads and the trimmed payloads that were sent, per object, under Application Support › JamfMigrator › exports.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}
