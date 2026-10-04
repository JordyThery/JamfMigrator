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
                invalidateDerivedState()
            }
        }
    }

    // Only non-nil selections persist: a transient Picker rebuild (e.g. the
    // delete-mode toggle recreating the tenant pickers) writes nil through
    // the binding and must not erase the stored selection.
    var sourceTenantID: Tenant.ID? {
        didSet {
            if let sourceTenantID {
                UserDefaults.standard.set(sourceTenantID.uuidString, forKey: "sourceTenantID")
                if oldValue != nil && oldValue != sourceTenantID { invalidateDerivedState() }
            }
        }
    }
    var destTenantID: Tenant.ID? {
        didSet {
            if let destTenantID {
                UserDefaults.standard.set(destTenantID.uuidString, forKey: "destTenantID")
                if oldValue != nil && oldValue != destTenantID { invalidateDerivedState() }
            }
        }
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
    /// Set by the Migration › Run menu command; ContentView turns it into the
    /// same confirmation dialog the toolbar button shows.
    var runRequested = false

    /// Everything derived from the current mode and tenant pair. Called when
    /// either changes, so a stale plan can never run against the wrong tenant.
    private func invalidateDerivedState() {
        if isPlanning {
            runTask?.cancel()
            isPlanning = false
        }
        plan = nil
        preflight = nil
        report = nil
        verifyReport = nil
        backupResult = nil
        excludedObjectIds = [:]
        selectedObjectID = nil
        searchText = ""
    }

    // MARK: Guided tour

    /// The current tour step, nil when the tour is off. Starts automatically
    /// on first launch and can be replayed from Help › Guided Tour.
    var tourIndex: Int?

    func startTour() {
        tourIndex = 0
    }

    func endTour() {
        tourIndex = nil
        UserDefaults.standard.set(true, forKey: "hasSeenGuidedTour")
    }

    func startTourOnFirstLaunch() {
        // mark it seen right away, so a second window can't restart the tour
        guard !UserDefaults.standard.bool(forKey: "hasSeenGuidedTour") else { return }
        UserDefaults.standard.set(true, forKey: "hasSeenGuidedTour")
        startTour()
    }

    // MARK: Clone / Wipe wizard state

    /// ADE and distribution-point mappings for the current tenant pair.
    var mappings = TenantMappings() {
        didSet { saveMappings() }
    }
    var sourceADEInstances: [ObjectRef] = []
    var destADEInstances: [ObjectRef] = []
    var sourceDistributionPoints: [ObjectRef] = []
    var destDistributionPoints: [ObjectRef] = []
    var isLoadingMappings = false

    var isBackingUp = false
    var backupResult: BackupResult?
    private var activeExporter: TenantExporter?

    var isVerifying = false
    var verifyReport: VerifyReport?

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

    /// Clears the selections and stored defaults of a removed tenant.
    func forgetTenant(_ id: Tenant.ID) {
        let defaults = UserDefaults.standard
        if sourceTenantID == id {
            sourceTenantID = nil
            defaults.removeObject(forKey: "sourceTenantID")
        }
        if destTenantID == id {
            destTenantID = nil
            defaults.removeObject(forKey: "destTenantID")
        }
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("mappings-") && key.contains(id.uuidString) {
            defaults.removeObject(forKey: key)
        }
        invalidateDerivedState()
    }

    /// Whether the current tenant pair can reach the platform-only namespaces
    /// (Blueprints, Compliance Benchmarks). Delete mode only needs the
    /// destination; a copy needs both.
    var gatewayAvailable: Bool {
        let destOK = destTenant?.usesGateway ?? true
        if mode == .delete { return destOK }
        return destOK && (sourceTenant?.usesGateway ?? true)
    }

    var canPreview: Bool {
        guard !isPlanning && !isRunning, tourIndex == nil,
              destTenant != nil, !selectedTypeKeys.isEmpty else { return false }
        if mode == .delete { return true }
        // copying a tenant onto itself is never meaningful
        return sourceTenant != nil && sourceTenantID != destTenantID
    }

    var canRun: Bool {
        // the plan must match the current mode — a stale plan from before a
        // mode switch must never drive a run
        plan?.mode == mode && !isRunning && !isPlanning && tourIndex == nil
            && effectiveChangeCount > 0
    }

    /// The plan's actionable changes minus the unchecked objects — what a run
    /// would actually touch (e.g. one specific script).
    var effectiveCounts: (create: Int, update: Int, replace: Int, delete: Int) {
        guard let plan else { return (0, 0, 0, 0) }
        var create = 0, update = 0, replace = 0, delete = 0
        for entry in plan.entries where !(excludedObjectIds[entry.typeKey]?.contains(entry.objectId) ?? false) {
            switch entry.change {
            case .create: create += 1
            case .update: update += 1
            case .replace: replace += 1
            case .delete: delete += 1
            case .unchanged, .blocked, .keep: break
            }
        }
        return (create, update, replace, delete)
    }

    var effectiveChangeCount: Int {
        let counts = effectiveCounts
        return counts.create + counts.update + counts.replace + counts.delete
    }

    // MARK: Service secrets (bind/ldap/fsrw/fsro), stored in the Keychain

    static let serviceSecretKeys: [(key: String, label: String)] = [
        ("bind", "Directory binding password"),
        ("ldap", "LDAP bind password"),
        ("fsrw", "File share read/write password"),
        ("fsro", "File share read-only password"),
        ("recoverylock", "PreStage Recovery Lock password"),
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
        runTask?.cancel()
        let dest = tenantStore.client(for: destTenant)
        isPlanning = true
        plan = nil
        report = nil
        lastError = nil
        let mode = mode
        let typeKeys = selectedTypeKeys
        let secrets = serviceSecrets
        let mappings = mappings
        runTask = Task { [weak self] in
            guard let self else { return }
            let progress: @Sendable (String) -> Void = { name in
                Task { @MainActor [weak self] in self?.planningStatus = name }
            }
            if mode == .delete {
                let planner = MigrationPlanner(source: dest, dest: dest, secrets: secrets, mappings: mappings, progress: progress)
                let plan = await planner.planDeletion(typeKeys: typeKeys)
                guard !Task.isCancelled, self.mode == mode else { return }
                self.plan = plan
            } else if let sourceTenant {
                let source = tenantStore.client(for: sourceTenant)
                let preflight = await Preflight.run(source: source, dest: dest, typeKeys: typeKeys)
                let planner = MigrationPlanner(source: source, dest: dest, secrets: secrets, mappings: mappings, progress: progress)
                let plan = await planner.plan(typeKeys: typeKeys)
                guard !Task.isCancelled, self.mode == mode else { return }
                self.preflight = preflight
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
        let mappings = mappings
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
                                         export: export, secrets: secrets, mappings: mappings, progress: progress)
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
        let exporter = activeExporter
        Task {
            await migration?.cancel()
            await delete?.cancel()
            await exporter?.cancel()
        }
    }

    private func finishRun(report: RunReport, journal: JournalStore) async {
        self.report = report
        self.isRunning = false
        self.activeMigration = nil
        self.activeDelete = nil
        if report.retryableFailures.isEmpty {
            // done: remove the journal and discard the now-stale plan
            await journal.finish()
            plan = nil
        }
        // on real failures the plan stays, so Resume run can retry
    }

    // MARK: Mappings

    private var mappingsKey: String? {
        guard let source = sourceTenantID, let dest = destTenantID else { return nil }
        return "mappings-\(source.uuidString)-\(dest.uuidString)"
    }

    func loadMappingCandidates() {
        guard let sourceTenant, let destTenant else { return }
        if let key = mappingsKey,
           let data = UserDefaults.standard.data(forKey: key),
           let stored = try? JSONDecoder().decode(TenantMappings.self, from: data) {
            mappings = stored
        } else if !mappings.isEmpty {
            // nothing stored for this pair: don't carry the previous pair's ids
            mappings = TenantMappings()
        }
        isLoadingMappings = true
        let source = tenantStore.client(for: sourceTenant)
        let dest = tenantStore.client(for: destTenant)
        Task { [weak self] in
            let sourceADE = (try? await MappingCatalog.adeInstances(on: source)) ?? []
            let destADE = (try? await MappingCatalog.adeInstances(on: dest)) ?? []
            let sourceDPs = (try? await MappingCatalog.distributionPoints(on: source)) ?? []
            let destDPs = (try? await MappingCatalog.distributionPoints(on: dest)) ?? []
            guard let self else { return }
            self.sourceADEInstances = sourceADE
            self.destADEInstances = destADE
            self.sourceDistributionPoints = sourceDPs
            self.destDistributionPoints = destDPs
            if self.mappings.isEmpty {
                self.mappings = MappingCatalog.propose(sourceADE: sourceADE, destADE: destADE,
                                                       sourceDPs: sourceDPs, destDPs: destDPs)
            }
            self.isLoadingMappings = false
        }
    }

    private func saveMappings() {
        guard let key = mappingsKey, let data = try? JSONEncoder().encode(mappings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    // MARK: Backup and verify

    /// Full backup of the destination tenant, required before a wipe.
    func backup() {
        guard let destTenant, !isBackingUp else { return }
        isBackingUp = true
        backupResult = nil
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let root = URL(fileURLWithPath: AppInfo.appSupportPath, isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent("\(destTenant.name)-\(formatter.string(from: Date()))", isDirectory: true)
        let exporter = TenantExporter(client: tenantStore.client(for: destTenant)) { name in
            Task { @MainActor [weak self] in self?.planningStatus = name }
        }
        activeExporter = exporter
        let typeKeys = selectedTypeKeys
        Task { [weak self] in
            let result = await exporter.backup(typeKeys: typeKeys, to: root)
            guard let self else { return }
            self.backupResult = result
            self.isBackingUp = false
            self.activeExporter = nil
        }
    }

    /// Plans again after a clone; clean means a second run would write nothing.
    func verify() {
        guard let sourceTenant, let destTenant, !isVerifying else { return }
        isVerifying = true
        verifyReport = nil
        let source = tenantStore.client(for: sourceTenant)
        let dest = tenantStore.client(for: destTenant)
        let typeKeys = selectedTypeKeys
        let excluding = excludedObjectIds
        let secrets = serviceSecrets
        let mappings = mappings
        let progress: @Sendable (String) -> Void = { [weak self] name in
            Task { @MainActor [weak self] in self?.planningStatus = name }
        }
        Task { [weak self] in
            let report = await Verifier.verify(source: source, dest: dest,
                                               typeKeys: typeKeys, excluding: excluding,
                                               secrets: secrets, mappings: mappings,
                                               progress: progress)
            guard let self else { return }
            self.verifyReport = report
            self.isVerifying = false
        }
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
