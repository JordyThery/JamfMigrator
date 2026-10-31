//
//  AppState.swift
//  JamfMigrator
//
//  The app's observable state: tenant selection, the sticky delete mode
//  (memory only — the app always starts in Copy), the current plan and the
//  running engine. In demo mode the tenants are JTKit's two demo tenants,
//  and nothing the app saves goes into its real files or settings.
//

import Foundation
import JTKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AppState {

    let tenantStore: TenantStore
    private let secretStore: any SecretStore
    /// The app's settings: the real ones, or a sandbox run's (`-JTKitSandbox`).
    private let defaults: UserDefaults

    // MARK: Demo mode

    /// JTKit's demo mode, saved under "demoMode". While it's on, Source and
    /// Destination are "Contoso Source (Demo)" and "Contoso Destination
    /// (Demo)", the saved choices are left as they were, and run reports,
    /// journals, backups and exports go to demo mode's temporary folder.
    let demo: DemoMode
    /// The demo tenants each role can choose; Source starts on Contoso
    /// Source, Destination (and delete mode's Tenant) on Contoso Destination.
    let sourceDemo: DemoConnectionChoice
    let destDemo: DemoConnectionChoice

    /// The roles of the sidebar pickers, the Connection menu and Settings ›
    /// Connections: Source and Destination, or delete mode's Tenant (which
    /// uses Destination's choice), each with both demo tenants.
    var sourceRole: ConnectionRole {
        ConnectionRole("Source", selection: binding(\.sourceTenantID), demo: sourceDemo)
    }

    var destinationRole: ConnectionRole {
        ConnectionRole(mode == .copy ? "Destination" : "Tenant", selection: binding(\.destTenantID), demo: destDemo)
    }

    var connectionRoles: [ConnectionRole] {
        mode == .copy ? [sourceRole, destinationRole] : [destinationRole]
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<AppState, Tenant.ID?>) -> Binding<Tenant.ID?> {
        Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }

    /// The two demo tenants, in the pickers' order.
    static let demoTenants: [Connection] = [.demoJamfProSource, .demoJamfProDestination]

    /// The app for this launch: a sandbox run (`-JTKitSandbox YES`, UI tests)
    /// keeps tenants, secrets and settings in memory. So does the unit tests'
    /// host: under tests the saved tenants aren't even loaded.
    static func forLaunch() -> AppState {
        let isUnitTestHost = TestRun.isActive && !DemoMode.isSandboxLaunch(ProcessInfo.processInfo.arguments)
        let demo = isUnitTestHost
            ? DemoMode(key: "demoMode", arguments: ProcessInfo.processInfo.arguments + ["-JTKitSandbox", "YES"])
            : DemoMode(key: "demoMode")
        guard demo.isSandbox else { return AppState(demo: demo) }
        let secrets = SandboxSecretStore()
        let store = TenantStore(secrets: secrets, demo: demo, storage: InMemoryConnectionStorage<Tenant>())
        return AppState(tenantStore: store, secretStore: secrets, demo: demo, defaults: DemoMode.sandboxDefaults())
    }

    /// Where the app keeps journals, backups, exports and run reports:
    /// Application Support, or demo mode's temporary folder.
    var dataDirectory: URL {
        if demo.isOn { return demo.scratchDirectory }
        // a sandbox run (UI tests) never writes into the real folder
        if demo.isSandbox { return Self.sandboxDirectory }
        return URL(fileURLWithPath: AppInfo.appSupportPath, isDirectory: true)
    }

    /// A sandbox run's folder for journals, backups, exports and run reports,
    /// one per launch, in the temporary folder.
    private static let sandboxDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("JamfMigrator-sandbox-\(UUID().uuidString)", isDirectory: true)

    /// Where run reports go, in words, for the run sheet's help.
    var runReportsLocation: String {
        if demo.isOn { return "demo mode's temporary folder (Run Reports)" }
        if demo.isSandbox { return "this sandbox run's temporary folder (Run Reports)" }
        return "Application Support › JamfMigrator › Run Reports"
    }

    /// Settings › Export: "Save payloads during runs", in the app's own
    /// settings (a sandbox run's are in memory).
    var exportOnRun: Bool {
        get { access(keyPath: \.exportOnRun); return defaults.bool(forKey: "exportOnRun") }
        set { withMutation(keyPath: \.exportOnRun) { defaults.set(newValue, forKey: "exportOnRun") } }
    }

    /// Identifies the tenants in use and the mode, so a change of either
    /// (demo mode on or off included) clears the plan.
    var tenantPairKey: String {
        "\(mode.rawValue)-\(demo.isOn)-\(sourceTenant?.id.uuidString ?? "")-\(destTenant?.id.uuidString ?? "")"
    }

    /// Demo mode was turned on or off, or another demo tenant chosen: the
    /// plan goes, and the selection and mappings are the ones of the new
    /// tenants (demo mode's stay in memory).
    func tenantsChanged(demoSwitched: Bool) {
        invalidateDerivedState()
        if demoSwitched, !demo.isOn, let stored = defaults.stringArray(forKey: "selectedTypeKeys") {
            selectedTypeKeys = Set(stored)
        }
        savesMappings = false
        mappings = storedMappings() ?? TenantMappings()
        savesMappings = true
    }

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
                defaults.set(sourceTenantID.uuidString, forKey: "sourceTenantID")
                if oldValue != nil && oldValue != sourceTenantID { invalidateDerivedState() }
            }
        }
    }
    var destTenantID: Tenant.ID? {
        didSet {
            if let destTenantID {
                defaults.set(destTenantID.uuidString, forKey: "destTenantID")
                if oldValue != nil && oldValue != destTenantID { invalidateDerivedState() }
            }
        }
    }

    var selectedTypeKeys: Set<String> {
        // demo mode's choice is kept in memory only
        didSet { if !demo.isOn { defaults.set(Array(selectedTypeKeys), forKey: "selectedTypeKeys") } }
    }
    /// The ticked rows, per registry key: what Run carries out. After a
    /// Preview every Create, Update, Replace and Delete row starts ticked;
    /// anything else (Unchanged, Blocked, objects that appear later) is never
    /// in it.
    var includedObjectIds: [String: Set<String>] = [:]

    func isIncluded(_ entry: ObjectPlan) -> Bool {
        includedObjectIds[entry.typeKey]?.contains(entry.objectId) == true
    }

    func setIncluded(_ included: Bool, _ entry: ObjectPlan) {
        guard entry.change.isRunnable else { return }
        if included {
            includedObjectIds[entry.typeKey, default: []].insert(entry.objectId)
        } else {
            includedObjectIds[entry.typeKey]?.remove(entry.objectId)
        }
    }

    /// Check all / Uncheck all for one type.
    func setAllIncluded(_ included: Bool, typeKey: String) {
        let runnable = plan?.entries(for: typeKey).filter(\.change.isRunnable).map(\.objectId) ?? []
        includedObjectIds[typeKey] = included ? Set(runnable) : []
    }

    /// What Preview read besides the tenants, to tell at Run whether it
    /// changed: the mappings, and a SHA-256 of each Settings › Secrets value
    /// (in memory only; a value itself is never kept in the plan, a journal
    /// or a run report).
    private struct PlanInputs {
        var mappings: TenantMappings
        var secretDigests: [String: String]
    }
    private var planInputs: PlanInputs?

    /// Set when a run stopped because something changed since Preview: Run
    /// stays off until the next Preview.
    var planIsStale = false

    /// The types a Preview plans: the selection without the gateway-only
    /// types the tenants can't reach (they stay selected for when both
    /// tenants use the gateway again).
    var previewTypeKeys: Set<String> {
        selectedTypeKeys.filter { key in
            !(ObjectRegistry.type(key)?.requiresGateway ?? false) || gatewayAvailable
        }
    }

    /// Sidebar and list selection.
    var selectedTypeKey: String?
    var selectedObjectID: ObjectPlan.ID?
    var searchText = ""

    // MARK: Plan and run state

    var preflight: PreflightReport?
    var plan: MigrationPlan?
    var isPlanning = false
    var planningStatus = ""
    /// Which selected type the planner is on (1-based) and how many there
    /// are, for the progress view; 0 while the tenants are being checked.
    var planningStep = 0
    var planningTotal = 0

    /// Sidebar selection that shows the plan summary instead of one type.
    static let summaryKey = "summary"

    var isRunning = false
    var runEvents: [ProgressEvent] = []
    var report: RunReport?
    /// Where the last run's report was saved (Run Reports), or why it wasn't.
    var reportFileURL: URL?
    var reportSaveError: String?
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
        reportFileURL = nil
        reportSaveError = nil
        verifyReport = nil
        backupResult = nil
        includedObjectIds = [:]
        planInputs = nil
        planIsStale = false
        selectedObjectID = nil
        searchText = ""
    }

    // MARK: Guided tour

    /// Starts automatically on first launch and can be replayed from
    /// Help › Guided Tour. The "tour seen" key is the one the app has always
    /// used, so people who saw the tour don't get it again.
    let tour = TourState(steps: TourStep.all, firstLaunchDefaultsKey: "hasSeenGuidedTour")

    // MARK: Clone / Wipe wizard state

    /// ADE and distribution-point mappings for the current tenant pair.
    var mappings = TenantMappings() {
        didSet { if savesMappings { saveMappings() } }
    }
    /// Off while mappings are swapped for another tenant pair's.
    @ObservationIgnored private var savesMappings = true
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

    init(tenantStore: TenantStore? = nil, secretStore: any SecretStore = TenantStore.keychain(),
         demo: DemoMode? = nil, defaults: UserDefaults = .standard) {
        let demo = demo ?? DemoMode(key: "demoMode", defaults: defaults)
        self.demo = demo
        self.tenantStore = tenantStore ?? TenantStore(demo: demo)
        self.secretStore = secretStore
        self.defaults = defaults
        sourceDemo = DemoConnectionChoice(mode: demo, connections: Self.demoTenants)
        destDemo = DemoConnectionChoice(mode: demo, connections: Self.demoTenants)
        destDemo.selectedID = Connection.demoJamfProDestination.id
        self.sourceTenantID = (defaults.string(forKey: "sourceTenantID")).flatMap(UUID.init)
        self.destTenantID = (defaults.string(forKey: "destTenantID")).flatMap(UUID.init)
        if let stored = defaults.stringArray(forKey: "selectedTypeKeys") {
            self.selectedTypeKeys = Set(stored)
        } else {
            self.selectedTypeKeys = Set(ObjectRegistry.types.map(\.key))
        }
    }

    var sourceTenant: Tenant? {
        if demo.isOn { return sourceDemo.selected.map(Tenant.init(connection:)) }
        return sourceTenantID.flatMap(tenantStore.tenant(id:))
    }

    var destTenant: Tenant? {
        if demo.isOn { return destDemo.selected.map(Tenant.init(connection:)) }
        return destTenantID.flatMap(tenantStore.tenant(id:))
    }

    /// Clears the selections and stored defaults of a removed tenant.
    func forgetTenant(_ id: Tenant.ID) {
        tenantStore.forgetClient(for: id)
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
        guard !isPlanning && !isRunning, tour.index == nil,
              destTenant != nil, !selectedTypeKeys.isEmpty else { return false }
        if mode == .delete { return true }
        // copying a tenant onto itself is never meaningful
        return sourceTenant != nil && sourceTenant?.id != destTenant?.id
    }

    var canRun: Bool {
        // the plan must match the current mode — a stale plan from before a
        // mode switch must never drive a run
        plan?.mode == mode && !isRunning && !isPlanning && tour.index == nil
            && effectiveChangeCount > 0 && runBlockedReason == nil
    }

    /// Why Run is off although there is a plan with ticked changes.
    var runBlockedReason: String? {
        guard let plan else { return nil }
        if planIsStale {
            return "Something changed since Preview. Preview again before running."
        }
        if previewTypeKeys != plan.typeKeys {
            return "The selected types changed since Preview. Preview again."
        }
        if let (entry, needs) = untickedDependency {
            let type = ObjectRegistry.type(needs.typeKey)?.displayName ?? needs.typeKey
            return "\"\(entry.name)\" needs \(type) › \"\(needs.name)\", which this run would create but is unticked. Tick it, or untick \"\(entry.name)\"."
        }
        return nil
    }

    /// A ticked row that refers to an object this run would create, while
    /// that object is unticked.
    var untickedDependency: (entry: ObjectPlan, needs: PlannedDependency)? {
        guard let plan else { return nil }
        var creates = [PlannedDependency: ObjectPlan]()
        for entry in plan.entries {
            if case .create = entry.change { creates[PlannedDependency(typeKey: entry.typeKey, name: entry.name)] = entry }
        }
        for entry in plan.entries where isIncluded(entry) {
            for needs in entry.plannedDependencies {
                if let dependency = creates[needs], !isIncluded(dependency) { return (entry, needs) }
            }
        }
        return nil
    }

    /// The rows of `plan` that need `entry`'s object, when it is unticked.
    func waitingOn(_ entry: ObjectPlan) -> [ObjectPlan] {
        guard let plan, case .create = entry.change, !isIncluded(entry) else { return [] }
        let me = PlannedDependency(typeKey: entry.typeKey, name: entry.name)
        return plan.entries.filter { isIncluded($0) && $0.plannedDependencies.contains(me) }
    }

    /// The plan's actionable changes minus the unchecked objects — what a run
    /// would actually touch (e.g. one specific script).
    var effectiveCounts: (create: Int, update: Int, replace: Int, delete: Int) {
        guard let plan else { return (0, 0, 0, 0) }
        var create = 0, update = 0, replace = 0, delete = 0
        for entry in plan.entries where isIncluded(entry) {
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

    @discardableResult
    func setServiceSecret(_ value: String, for key: String) -> Bool {
        secretStore.setSecret(value.isEmpty ? nil : value, for: "service-\(key)")
    }

    /// Settings › Secrets; demo runs never read them (the Keychain), so
    /// they write the placeholder.
    private var serviceSecrets: [String: String] {
        guard !demo.isOn else { return [:] }
        var secrets = [String: String]()
        for (key, _) in Self.serviceSecretKeys {
            let value = serviceSecret(key)
            if !value.isEmpty { secrets[key] = value }
        }
        return secrets
    }

    /// A SHA-256 of each Settings › Secrets value, to tell at Run whether
    /// one changed since Preview without keeping the value.
    static func digests(of secrets: [String: String]) -> [String: String] {
        secrets.mapValues { MigrationPlanner.digest(["value": $0]) }
    }

    /// Whether Settings › Secrets or the mappings changed since Preview, in
    /// words. Only digests are compared; the words never name a value.
    static func inputChange(secrets: [String: String], mappings: TenantMappings, mode: RunMode,
                            previewDigests: [String: String], previewMappings: TenantMappings) -> String? {
        if digests(of: secrets) != previewDigests { return "Secrets changed since Preview." }
        if mode == .copy && mappings != previewMappings { return "Mappings changed since Preview." }
        return nil
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
        let typeKeys = previewTypeKeys
        let secrets = serviceSecrets
        let mappings = mappings
        planInputs = PlanInputs(mappings: mappings, secretDigests: Self.digests(of: secrets))
        includedObjectIds = [:]
        planIsStale = false
        planningStep = 0
        planningTotal = ObjectRegistry.types.filter { typeKeys.contains($0.key) }.count
        planningStatus = mode == .copy ? "Checking both tenants" : "Listing the tenant"
        runTask = Task { [weak self] in
            guard let self else { return }
            // the planner reports each type as it starts on it
            let progress: @Sendable (String) -> Void = { name in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.planningStatus = name
                    self.planningStep = min(self.planningStep + 1, self.planningTotal)
                }
            }
            if mode == .delete {
                let planner = MigrationPlanner(source: dest, dest: dest, secrets: secrets, mappings: mappings, progress: progress)
                let plan = await planner.planDeletion(typeKeys: typeKeys)
                guard !Task.isCancelled, self.mode == mode else { return }
                self.adopt(plan)
            } else if let sourceTenant {
                let source = tenantStore.client(for: sourceTenant)
                let preflight = await Preflight.run(source: source, dest: dest, typeKeys: typeKeys)
                let planner = MigrationPlanner(source: source, dest: dest, secrets: secrets, mappings: mappings, progress: progress)
                let plan = await planner.plan(typeKeys: typeKeys)
                guard !Task.isCancelled, self.mode == mode else { return }
                self.preflight = preflight
                self.adopt(plan)
            }
            self.isPlanning = false
            // land on the overview, not on whichever type happened to be
            // selected before
            self.selectedTypeKey = Self.summaryKey
            self.selectedObjectID = nil
        }
    }

    /// A finished Preview: every actionable row starts ticked.
    private func adopt(_ plan: MigrationPlan) {
        includedObjectIds = plan.runnableIds
        self.plan = plan
    }

    // MARK: Run

    /// What the run carried out, for Verify afterwards: the types, and the
    /// rows of the plan that were left unticked.
    private var lastRunTypeKeys: Set<String>?
    private var lastRunExcluded: [String: Set<String>] = [:]

    func run() {
        guard canRun, let destTenant, let plan, let planInputs else { return }
        guard mode == .copy || !destTenant.isProtected else {
            lastError = "\(destTenant.name) is protected; switch protection off in Settings before deleting from it."
            return
        }
        let dest = tenantStore.client(for: destTenant)
        isRunning = true
        runEvents = []
        report = nil
        reportFileURL = nil
        reportSaveError = nil
        runWasStopped = false
        lastError = nil
        // decided now: switching demo mode during the run doesn't move its report
        runReportsFolder = dataDirectory.appendingPathComponent("Run Reports", isDirectory: true)
        let reportFile = RunReportFile(report: RunReport(),
                                       mode: mode,
                                       sourceName: mode == .copy ? sourceTenant?.name : nil,
                                       destinationName: destTenant.name,
                                       started: Date(),
                                       finished: Date(),
                                       wasStopped: false)
        let including = includedObjectIds
        let secrets = serviceSecrets
        let mappings = mappings
        lastRunTypeKeys = plan.typeKeys
        lastRunExcluded = Dictionary(grouping: plan.entries.filter { $0.change.isRunnable && !isIncluded($0) },
                                     by: \.typeKey).mapValues { Set($0.map(\.objectId)) }
        // Settings › Secrets and the mappings must be what Preview used
        if let changedInput = Self.inputChange(secrets: secrets, mappings: mappings, mode: mode,
                                               previewDigests: planInputs.secretDigests,
                                               previewMappings: planInputs.mappings) {
            var stopped = RunReport()
            stopped.stopReason = changedInput + " Nothing was written; Preview again."
            AppActivity.record(stopped.stopReason ?? "", category: "Migration", level: .warning)
            Task { [weak self] in
                await self?.finishRun(report: stopped, journal: nil, file: reportFile)
            }
            return
        }
        let journal = JournalStore(url: journalURL(destTenant: destTenant),
                                   mode: mode,
                                   sourceTenantId: mode == .copy ? sourceTenant?.id : nil,
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
                let report = await engine.run(plan, including: including)
                await self?.finishRun(report: report, journal: journal, file: reportFile)
            }
        case .delete:
            let engine = DeleteEngine(client: dest, journal: journal, progress: progress)
            activeDelete = engine
            runTask = Task { [weak self] in
                let report = await engine.run(plan, including: including)
                await self?.finishRun(report: report, journal: journal, file: reportFile)
            }
        }
    }

    /// The run confirmation's title and message, naming the tenant (the demo
    /// one in demo mode) and what the run will do.
    var runConfirmationTitle: String {
        let tenant = destTenant?.name ?? "the destination"
        return mode == .delete
            ? "Delete objects from \(tenant)?"
            : "Copy to \(tenant)?"
    }

    var runConfirmationMessage: String {
        guard let planCounts = plan?.counts else { return "" }
        let effective = effectiveCounts
        if mode == .delete {
            return "\(effective.delete) objects will be deleted from \(destTenant?.name ?? "the destination"); \(planCounts.keep) built-ins are kept. This cannot be undone."
        }
        var message = "\(effective.create) to create, \(effective.update) to update, \(planCounts.unchanged) unchanged, \(planCounts.blocked) blocked."
        let planChangeCount = planCounts.create + planCounts.update + planCounts.replace + planCounts.delete
        let unchecked = planChangeCount - effectiveChangeCount
        if unchecked > 0 {
            message += " \(unchecked) unchecked objects are left out."
        }
        if effective.replace > 0 {
            message += " \(effective.replace) Compliance Benchmarks will be deleted and recreated — they can’t be updated in place."
        }
        return message
    }

    func cancel() {
        if isRunning { runWasStopped = true }
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

    /// Where the running run's report goes: Run Reports, or demo mode's folder.
    private var runReportsFolder: URL?

    /// Set by Stop, so the saved report says the run didn't finish.
    private var runWasStopped = false

    private func finishRun(report: RunReport, journal: JournalStore?, file: RunReportFile) async {
        self.report = report
        saveReport(report, file: file)
        self.isRunning = false
        self.activeMigration = nil
        self.activeDelete = nil
        if report.stopReason != nil {
            // something changed since Preview: Run stays off until the next
            // Preview; the journal keeps what was done for it
            planIsStale = true
            return
        }
        guard let journal else { return }
        if report.retryableFailures.isEmpty {
            // done: remove the journal and discard the now-stale plan
            await journal.finish()
            plan = nil
        }
        // on real failures the plan stays, so Resume run can retry
    }

    /// Saves the run's report to Run Reports. A failure is shown in the run
    /// sheet and the activity log; the run itself is not affected.
    private func saveReport(_ report: RunReport, file: RunReportFile) {
        var file = file
        file.report = report
        file.finished = Date()
        file.wasStopped = runWasStopped
        do {
            let url = try file.save(in: runReportsFolder ?? dataDirectory.appendingPathComponent("Run Reports", isDirectory: true))
            reportFileURL = url
            AppActivity.record("Run report saved: \(url.lastPathComponent)", category: "Run report",
                               connection: file.destinationName)
        } catch {
            reportSaveError = error.localizedDescription
            AppActivity.record("Could not save the run report: \(error.localizedDescription)",
                               category: "Run report", connection: file.destinationName, level: .error)
        }
    }

    // MARK: Mappings

    /// The pair's saved mappings; demo mode's are kept in memory only.
    private var mappingsKey: String? {
        guard !demo.isOn, let source = sourceTenant?.id, let dest = destTenant?.id else { return nil }
        return "mappings-\(source.uuidString)-\(dest.uuidString)"
    }

    private func storedMappings() -> TenantMappings? {
        guard let key = mappingsKey, let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TenantMappings.self, from: data)
    }

    func loadMappingCandidates() {
        guard let sourceTenant, let destTenant else { return }
        if let stored = storedMappings() {
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
        defaults.set(data, forKey: key)
    }

    // MARK: Backup and verify

    /// Full backup of the destination tenant, required before a wipe.
    func backup() {
        guard let destTenant, !isBackingUp else { return }
        isBackingUp = true
        backupResult = nil
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let root = dataDirectory
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
        // after a run: what it carried out; otherwise the selection
        let typeKeys = lastRunTypeKeys ?? previewTypeKeys
        let excluding = lastRunTypeKeys == nil ? [:] : lastRunExcluded
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
        dataDirectory
            .appendingPathComponent("journals", isDirectory: true)
            .appendingPathComponent("\(destTenant.id.uuidString)-\(mode.rawValue).json")
    }

    private func exportWriterIfEnabled() -> ExportWriter? {
        guard exportOnRun else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let root = dataDirectory
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        return ExportWriter(root: root)
    }
}
