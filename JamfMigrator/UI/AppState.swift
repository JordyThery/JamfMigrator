//
//  AppState.swift
//  JamfMigrator
//
//  The app's observable state: tenant selection, the sticky delete mode
//  (memory only — the app always starts in Copy), the current plan and the
//  running engine.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppState {

    let tenantStore: TenantStore
    private let secretStore: any SecretStore

    // MARK: Mode and selection

    /// Sticky for the session, but the app always starts in Copy mode.
    var mode: RunMode = .copy {
        didSet {
            if mode != oldValue {
                plan = nil
                report = nil
            }
        }
    }

    var sourceTenantID: Tenant.ID? {
        didSet { UserDefaults.standard.set(sourceTenantID?.uuidString, forKey: "sourceTenantID") }
    }
    var destTenantID: Tenant.ID? {
        didSet { UserDefaults.standard.set(destTenantID?.uuidString, forKey: "destTenantID") }
    }

    var selectedTypeKeys: Set<String> {
        didSet { UserDefaults.standard.set(Array(selectedTypeKeys), forKey: "selectedTypeKeys") }
    }
    /// Source object ids the user unchecked, per registry key.
    var excludedObjectIds: [String: Set<String>] = [:]

    /// Sidebar and list selection.
    var selectedTypeKey: String?
    var selectedObjectID: ObjectPlan.ID?
    var searchText = ""

    // MARK: Plan and run state

    var preflight: PreflightReport?
    var plan: MigrationPlan?
    var isPlanning = false
    var planningStatus = ""

    var isRunning = false
    var runEvents: [ProgressEvent] = []
    var report: RunReport?
    var lastError: String?

    private var runTask: Task<Void, Never>?
    private var activeMigration: MigrationEngine?
    private var activeDelete: DeleteEngine?

    init(tenantStore: TenantStore? = nil, secretStore: any SecretStore = KeychainSecretStore()) {
        self.tenantStore = tenantStore ?? TenantStore()
        self.secretStore = secretStore
        let defaults = UserDefaults.standard
        self.sourceTenantID = (defaults.string(forKey: "sourceTenantID")).flatMap(UUID.init)
        self.destTenantID = (defaults.string(forKey: "destTenantID")).flatMap(UUID.init)
        if let stored = defaults.stringArray(forKey: "selectedTypeKeys") {
            self.selectedTypeKeys = Set(stored)
        } else {
            self.selectedTypeKeys = Set(ObjectRegistry.types.map(\.key))
        }
    }

    var sourceTenant: Tenant? { sourceTenantID.flatMap(tenantStore.tenant(id:)) }
    var destTenant: Tenant? { destTenantID.flatMap(tenantStore.tenant(id:)) }

    /// Delete mode acts on the destination tenant.
    var targetTenant: Tenant? { destTenant }

    var canPreview: Bool {
        guard !isPlanning && !isRunning, destTenant != nil, !selectedTypeKeys.isEmpty else { return false }
        return mode == .delete || sourceTenant != nil
    }

    var canRun: Bool {
        plan != nil && !isRunning && !isPlanning && plan!.changeCount > 0
    }

    // MARK: Service secrets (bind/ldap/fsrw/fsro), stored in the Keychain

    static let serviceSecretKeys: [(key: String, label: String)] = [
        ("bind", "Directory binding password"),
        ("ldap", "LDAP bind password"),
        ("fsrw", "File share read/write password"),
        ("fsro", "File share read-only password"),
    ]

    func serviceSecret(_ key: String) -> String {
        secretStore.secret(for: "service-\(key)") ?? ""
    }

    func setServiceSecret(_ value: String, for key: String) {
        secretStore.setSecret(value.isEmpty ? nil : value, for: "service-\(key)")
    }

    private var serviceSecrets: [String: String] {
        var secrets = [String: String]()
        for (key, _) in Self.serviceSecretKeys {
            let value = serviceSecret(key)
            if !value.isEmpty { secrets[key] = value }
        }
        return secrets
    }

    // MARK: Preview

    func preview() {
        guard canPreview, let destTenant else { return }
        let dest = tenantStore.client(for: destTenant)
        isPlanning = true
        plan = nil
        report = nil
        lastError = nil
        let mode = mode
        let typeKeys = selectedTypeKeys
        let secrets = serviceSecrets
        runTask = Task { [weak self] in
            guard let self else { return }
            let progress: @Sendable (String) -> Void = { name in
                Task { @MainActor [weak self] in self?.planningStatus = name }
            }
            if mode == .delete {
                let planner = MigrationPlanner(source: dest, dest: dest, secrets: secrets, progress: progress)
                let plan = await planner.planDeletion(typeKeys: typeKeys)
                self.plan = plan
            } else if let sourceTenant {
                let source = tenantStore.client(for: sourceTenant)
                self.preflight = await Preflight.run(source: source, dest: dest, typeKeys: typeKeys)
                let planner = MigrationPlanner(source: source, dest: dest, secrets: secrets, progress: progress)
                let plan = await planner.plan(typeKeys: typeKeys)
                self.plan = plan
            }
            self.isPlanning = false
            if self.selectedTypeKey == nil {
                self.selectedTypeKey = ObjectRegistry.types.first { self.selectedTypeKeys.contains($0.key) }?.key
            }
        }
    }

    // MARK: Run

    func run() {
        guard canRun, let destTenant else { return }
        guard mode == .copy || !destTenant.isProtected else {
            lastError = "\(destTenant.name) is protected; switch protection off in Settings before deleting from it."
            return
        }
        let dest = tenantStore.client(for: destTenant)
        isRunning = true
        runEvents = []
        report = nil
        lastError = nil
        let typeKeys = selectedTypeKeys
        let excluding = excludedObjectIds
        let secrets = serviceSecrets
        let journal = JournalStore(url: journalURL(destTenant: destTenant),
                                   mode: mode,
                                   sourceTenantId: mode == .copy ? sourceTenantID : nil,
                                   destTenantId: destTenant.id)
        let progress: @Sendable (ProgressEvent) -> Void = { event in
            Task { @MainActor [weak self] in self?.runEvents.append(event) }
        }

        switch mode {
        case .copy:
            guard let sourceTenant else { return }
            let source = tenantStore.client(for: sourceTenant)
            let export = exportWriterIfEnabled()
            let engine = MigrationEngine(source: source, dest: dest, journal: journal,
                                         export: export, secrets: secrets, progress: progress)
            activeMigration = engine
            runTask = Task { [weak self] in
                let report = await engine.migrate(typeKeys: typeKeys, excluding: excluding)
                await self?.finishRun(report: report, journal: journal)
            }
        case .delete:
            let engine = DeleteEngine(client: dest, journal: journal, progress: progress)
            activeDelete = engine
            runTask = Task { [weak self] in
                let report = await engine.delete(typeKeys: typeKeys, excluding: excluding)
                await self?.finishRun(report: report, journal: journal)
            }
        }
    }

    func cancel() {
        runTask?.cancel()
        let migration = activeMigration
        let delete = activeDelete
        Task {
            await migration?.cancel()
            await delete?.cancel()
        }
    }

    private func finishRun(report: RunReport, journal: JournalStore) async {
        self.report = report
        self.isRunning = false
        self.activeMigration = nil
        self.activeDelete = nil
        if report.failures.isEmpty {
            await journal.finish()
        }
        // refresh the plan so the list reflects the new destination state
        plan = nil
    }

    // MARK: Paths

    private func journalURL(destTenant: Tenant) -> URL {
        URL(fileURLWithPath: AppInfo.appSupportPath, isDirectory: true)
            .appendingPathComponent("journals", isDirectory: true)
            .appendingPathComponent("\(destTenant.id.uuidString)-\(mode.rawValue).json")
    }

    private func exportWriterIfEnabled() -> ExportWriter? {
        guard UserDefaults.standard.bool(forKey: "exportOnRun") else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let root = URL(fileURLWithPath: AppInfo.appSupportPath, isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        return ExportWriter(root: root)
    }
}
