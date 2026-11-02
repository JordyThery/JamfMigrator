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
    /// Application Support, or demo mode's temporary folder. Under JTKit's
    /// live-check switch (live UI tests), the release check's run folder.
    var dataDirectory: URL {
        if let live = Self.liveDirectory { return live }
        if demo.isOn { return demo.scratchDirectory }
        // a sandbox run (UI tests) never writes into the real folder
        if demo.isSandbox { return Self.sandboxDirectory }
        return URL(fileURLWithPath: AppInfo.appSupportPath, isDirectory: true)
    }

    /// A sandbox run's folder for journals, backups, exports and run reports,
    /// one per launch, in the temporary folder.
    private static let sandboxDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("JamfMigrator-sandbox-\(UUID().uuidString)", isDirectory: true)

    /// Under the live-check switch: the run's folder for the app's own files
    /// (decided once, so Resume finds the journal again); nil otherwise.
    private static let liveDirectory = LiveLaunch.appFilesFolder("JamfMigrator")

    /// Where run reports go, in words, for the run sheet's help.
    var runReportsLocation: String {
        if Self.liveDirectory != nil { return "the release check’s run folder (Run Reports)" }
        if demo.isOn { return "demo mode’s temporary folder (Run Reports)" }
        if demo.isSandbox { return "this sandbox run’s temporary folder (Run Reports)" }
        return "Application Support › JamfMigrator › Run Reports"
    }

    /// Settings › Export: "Save payloads during runs", in the app's own
    /// settings (a sandbox run's are in memory).
    var exportOnRun: Bool {
        get { access(keyPath: \.exportOnRun); return defaults.bool(forKey: "exportOnRun") }
        set { withMutation(keyPath: \.exportOnRun) { defaults.set(newValue, forKey: "exportOnRun") } }
    }

    /// Identifies the tenants in use, how each connects, and the mode, so a
    /// change of any of them (demo mode on or off, or an edited server URL,
    /// region, Environment ID or account included) clears the plan.
    var tenantPairKey: String {
        "\(mode.rawValue)-\(demo.isOn)-\(Self.connectionKey(sourceTenant))-\(Self.connectionKey(destTenant))"
    }

    /// A tenant and the fields that decide where and how it connects.
    static func connectionKey(_ tenant: Tenant?) -> String {
        guard let tenant else { return "" }
        return [tenant.id.uuidString, tenant.region.rawValue, tenant.environmentId, tenant.clientId,
                tenant.serverURL ?? "", tenant.username ?? ""].joined(separator: "|")
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

    /// Sticky for the session, but the app always starts in Copy mode. It
    /// can't change while a run is writing.
    var mode: RunMode = .copy {
        didSet {
            guard !isReverting else { return }
            if isRunning, mode != oldValue {
                revert { mode = oldValue }
                return
            }
            if mode != oldValue {
                invalidateDerivedState()
            }
        }
    }

    /// While a run writes, the mode and the tenants stay as they are.
    var canChangeTenants: Bool { !isRunning }

    /// Set while a refused change is put back, so that doesn't count as one.
    @ObservationIgnored private var isReverting = false

    private func revert(_ putBack: () -> Void) {
        isReverting = true
        putBack()
        isReverting = false
    }

    // Only non-nil selections persist: a transient Picker rebuild (e.g. the
    // delete-mode toggle recreating the tenant pickers) writes nil through
    // the binding and must not erase the stored selection.
    var sourceTenantID: Tenant.ID? {
        didSet {
            // a run keeps the tenants it started with
            guard !isReverting else { return }
            if isRunning, oldValue != nil, sourceTenantID != oldValue {
                revert { sourceTenantID = oldValue }
                return
            }
            if let sourceTenantID {
                defaults.set(sourceTenantID.uuidString, forKey: "sourceTenantID")
                if oldValue != nil && oldValue != sourceTenantID { invalidateDerivedState() }
            }
        }
    }
    var destTenantID: Tenant.ID? {
        didSet {
            guard !isReverting else { return }
            if isRunning, oldValue != nil, destTenantID != oldValue {
                revert { destTenantID = oldValue }
                return
            }
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
    /// The checked rows, per registry key: what Run carries out. After a
    /// Preview every Create, Update, Replace and Delete row starts checked;
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

    /// Check All / Uncheck All for one type.
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
    /// Set by Stop while a run finishes the object it is writing.
    var isStopping = false
    var runEvents: [ProgressEvent] = []
    var report: RunReport?
    /// Where the last run's report was saved (Run Reports), or why it wasn't.
    var reportFileURL: URL?
    var reportSaveError: String?
    var lastError: String?
    /// Set by the Migration › Run menu command; ContentView turns it into the
    /// same confirmation dialog the toolbar button shows.
    var runRequested = false
    /// Set by Migration › Clone Tenant… and Wipe Tenant…; ContentView opens
    /// the same wizards as the toolbar buttons.
    var cloneRequested = false
    var wipeRequested = false

    /// Whether Clone Tenant can open: copy mode, both tenants, no run.
    var canClone: Bool { mode == .copy && sourceTenant != nil && destTenant != nil && !isRunning }
    /// Whether Wipe Tenant can open: delete mode, a tenant, no run.
    var canWipe: Bool { mode == .delete && destTenant != nil && !isRunning }

    /// Everything derived from the current mode and tenant pair. Called when
    /// either changes, so a stale plan can never run against the wrong tenant.
    private func invalidateDerivedState() {
        // a running run keeps its plan, report and journal; whatever changed
        // (a demo tenant chosen from the menu) takes effect when it ends
        if isRunning {
            invalidatesAfterRun = true
            return
        }
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
        lastRunTypeKeys = nil
        lastRunExcluded = [:]
    }

    /// Set when the tenants changed while a run was writing.
    @ObservationIgnored private var invalidatesAfterRun = false

    // MARK: Guided tour

    /// Starts automatically on first launch and can be replayed from
    /// Help › Guided Tour. "Tour seen" is kept in the app's settings (a
    /// sandbox run's are in memory), so people who saw it don't get it again.
    let tour: TourState<TourAnchorID>

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
        tour = TourState(steps: TourStep.all, firstLaunchDefaultsKey: "hasSeenGuidedTour", defaults: defaults)
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
        // a Preview uses the mappings proposed for the pair, so it waits for them
        guard !isPlanning && !isRunning && !isLoadingMappings, tour.index == nil,
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

    /// Why Run is off although there is a plan with checked changes.
    var runBlockedReason: String? {
        guard let plan else { return nil }
        if planIsStale {
            return "Something changed since Preview. Preview again before running."
        }
        if plan.mode == .copy, let planInputs, mappings != planInputs.mappings {
            return "The ADE instance or distribution point mappings changed since Preview. Preview again before running."
        }
        if previewTypeKeys != plan.typeKeys {
            return "The selected types changed since Preview. Preview again before running."
        }
        if let (entry, needs) = untickedDependency {
            let type = ObjectRegistry.type(needs.typeKey)?.displayName ?? needs.typeKey
            return "“\(entry.name)” needs \(type) › “\(needs.name)”, which this run would create but is unchecked. Check it, or uncheck “\(entry.name)”."
        }
        return nil
    }

    /// A checked row that refers to an object this run would create, while
    /// that object is unchecked.
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

    /// The rows of `plan` that need `entry`'s object, when it is unchecked.
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

    /// The value, "" when none is stored.
    /// - Throws: `SecretStoreError` when the Keychain can't read it.
    func serviceSecret(_ key: String) throws -> String {
        try secretStore.readSecret(for: "service-\(key)") ?? ""
    }

    @discardableResult
    func setServiceSecret(_ value: String, for key: String) -> Bool {
        secretStore.setSecret(value.isEmpty ? nil : value, for: "service-\(key)")
    }

    /// Settings › Secrets: saves `value` only when it differs from what the
    /// Keychain holds (`stored`, the value shown or last saved), so opening
    /// the tab never writes. Nil: there was nothing to save.
    func saveServiceSecretIfChanged(_ value: String, for key: String, stored: inout String?) -> Bool? {
        guard let shown = stored, value != shown else {
            // not read yet (a Keychain that couldn't be read): typing saves
            if stored == nil, !value.isEmpty { return saveAndRemember(value, for: key, stored: &stored) }
            return nil
        }
        return saveAndRemember(value, for: key, stored: &stored)
    }

    private func saveAndRemember(_ value: String, for key: String, stored: inout String?) -> Bool {
        let saved = setServiceSecret(value, for: key)
        if saved { stored = value }
        return saved
    }

    /// Settings › Secrets; demo runs never read them (the Keychain), so
    /// they write the placeholder.
    /// - Throws: `SecretStoreError` when the Keychain can't read one: a
    ///   Preview or run then stops rather than writing the placeholder.
    private func serviceSecrets() throws -> [String: String] {
        guard !demo.isOn else { return [:] }
        var secrets = [String: String]()
        for (key, _) in Self.serviceSecretKeys {
            let value = try serviceSecret(key)
            if !value.isEmpty { secrets[key] = value }
        }
        return secrets
    }

    /// Settings › Secrets, or nil with `lastError` saying the Keychain
    /// couldn't be read.
    private func readServiceSecrets() -> [String: String]? {
        do {
            return try serviceSecrets()
        } catch {
            lastError = "Settings › Secrets couldn’t be read: \(error.localizedDescription)"
            AppActivity.record(lastError ?? "", category: "Keychain", level: .error)
            return nil
        }
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
        guard canPreview, let destTenant, let secrets = readServiceSecrets() else { return }
        runTask?.cancel()
        let dest = tenantStore.client(for: destTenant)
        isPlanning = true
        plan = nil
        report = nil
        lastError = nil
        let mode = mode
        let typeKeys = previewTypeKeys
        let mappings = mappings
        // a direct username-and-password tenant's account is never deleted
        let signedInUsername = destTenant.usesGateway ? nil : destTenant.username
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
                let plan = await planner.planDeletion(typeKeys: typeKeys, signedInUsername: signedInUsername)
                guard !Task.isCancelled, self.mode == mode else { return }
                self.adopt(plan)
            } else if let sourceTenant {
                let source = tenantStore.client(for: sourceTenant)
                let preflight = await Preflight.run(source: source, dest: dest, typeKeys: typeKeys)
                let planner = MigrationPlanner(source: source, dest: dest, secrets: secrets, mappings: mappings,
                                               destinationVersion: preflight.destination.version, progress: progress)
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

    /// A finished Preview: every actionable row starts checked.
    private func adopt(_ plan: MigrationPlan) {
        includedObjectIds = plan.runnableIds
        self.plan = plan
    }

    // MARK: Run

    /// What the run carried out, for Verify afterwards: the types, and the
    /// rows of the plan that were left unchecked.
    private var lastRunTypeKeys: Set<String>?
    private var lastRunExcluded: [String: Set<String>] = [:]

    /// - Returns: whether the run started (false: `lastError` says why, or
    ///   Run isn't possible now).
    @discardableResult
    func run() -> Bool {
        guard canRun, let destTenant, let plan, let planInputs, let secrets = readServiceSecrets() else { return false }
        guard mode == .copy || !destTenant.isProtected else {
            lastError = "\(destTenant.name) is protected and can’t be wiped or deleted from. Switch protection off in Settings › Connections first."
            return false
        }
        let dest = tenantStore.client(for: destTenant)
        isRunning = true
        runEvents = []
        report = nil
        reportFileURL = nil
        reportSaveError = nil
        runWasStopped = false
        isStopping = false
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
        let mappings = mappings
        lastRunTypeKeys = plan.typeKeys
        lastRunExcluded = Dictionary(grouping: plan.entries.filter { $0.change.isRunnable && !isIncluded($0) },
                                     by: \.typeKey).mapValues { Set($0.map(\.objectId)) }
        // Settings › Secrets and the mappings must be what Preview used
        if let changedInput = Self.inputChange(secrets: secrets, mappings: mappings, mode: mode,
                                               previewDigests: planInputs.secretDigests,
                                               previewMappings: planInputs.mappings) {
            var stopped = RunReport()
            stopped.stopReason = changedInput + " Nothing was written. Preview again before running."
            AppActivity.record(stopped.stopReason ?? "", category: "Migration", level: .warning)
            Task { [weak self] in
                await self?.finishRun(report: stopped, journal: nil, file: reportFile)
            }
            return true
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
            guard let sourceTenant else { return false }
            let source = tenantStore.client(for: sourceTenant)
            let export = exportWriterIfEnabled()
            let engine = MigrationEngine(source: source, dest: dest, journal: journal,
                                         export: export, secrets: secrets, mappings: mappings,
                                         destinationVersion: preflight?.destination.version, progress: progress)
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
        return true
    }

    /// Wipe's last gate: delete mode, a tenant that isn't protected, a delete
    /// Preview with something to delete that Run can still carry out, a
    /// complete backup (or one skipped with its own confirmation), and the
    /// tenant's name typed exactly.
    func wipeGatesPass(typedName: String, backupSkipped: Bool) -> Bool {
        guard mode == .delete,
              let tenant = destTenant, !tenant.isProtected,
              let plan, plan.mode == .delete, effectiveCounts.delete > 0,
              canRun,
              typedName == tenant.name else { return false }
        return backupSkipped || backupResult?.isComplete == true
    }

    /// The run confirmation's title and message, naming the tenant (the demo
    /// one in demo mode) and what the run will do.
    var runConfirmationTitle: String {
        let tenant = destTenant?.name ?? "the destination"
        return mode == .delete
            ? "Delete objects from \(tenant)?"
            : "Copy to \(tenant)?"
    }

    /// The confirmation's button: what the run does, with its count.
    var runConfirmationButton: String {
        mode == .delete
            ? "Delete \(Plural.count(effectiveCounts.delete, "Object"))"
            : "Copy \(Plural.count(effectiveChangeCount, "Change"))"
    }

    var runConfirmationMessage: String {
        guard let planCounts = plan?.counts else { return "" }
        let effective = effectiveCounts
        if mode == .delete {
            return "\(Plural.count(effective.delete, "object")) will be deleted from \(destTenant?.name ?? "the tenant"); \(Plural.count(planCounts.keep, "object")) \(planCounts.keep == 1 ? "is" : "are") kept. This can’t be undone."
        }
        var message = "\(effective.create) to create, \(effective.update) to update, \(planCounts.unchanged) unchanged, \(planCounts.blocked) blocked."
        let planChangeCount = planCounts.create + planCounts.update + planCounts.replace + planCounts.delete
        let unchecked = planChangeCount - effectiveChangeCount
        if unchecked > 0 {
            message += " \(Plural.count(unchecked, "unchecked object")) \(unchecked == 1 ? "is" : "are") left out."
        }
        if effective.replace > 0 {
            message += " \(Plural.count(effective.replace, "Compliance Benchmark")) will be deleted and recreated — benchmarks can’t be updated in place."
        }
        return message
    }

    /// Stop: a run finishes the object it is writing, then stops (cancelling
    /// it mid-request would leave that object's state unknown); a wait before
    /// a retry or a watch after a write ends at once. Preview and the backup
    /// stop at once.
    func cancel() {
        if isRunning {
            runWasStopped = true
            isStopping = true
        } else {
            runTask?.cancel()
        }
        let migration = activeMigration
        let delete = activeDelete
        let exporter = activeExporter
        let waits = tenantStore.waits
        Task { [weak self] in
            await Self.stop(cancelEngines: {
                await migration?.cancel()
                await delete?.cancel()
                await exporter?.cancel()
            }, endWaits: {
                waits.cancelAll()
                // and, until the run has ended, any wait that begins later
                self?.endWaitsWhileStopping()
            })
        }
    }

    /// Stop's order: the engines first, so an object whose wait ends next
    /// is the last one and the run doesn't go on to the next object; then
    /// the waits before a retry ("Jamf asked to wait 40 s"), so a request
    /// waiting to be sent again isn't sent.
    static func stop(cancelEngines: () async -> Void, endWaits: () -> Void) async {
        await cancelEngines()
        endWaits()
    }

    /// Stop is clickable while a run stops: a second click ends the waits again.
    var canStop: Bool { isRunning }

    /// While a stopped run finishes its object, ends every wait before a
    /// retry as soon as it begins (that object's write, icon or watch).
    private func endWaitsWhileStopping() {
        guard isRunning, isStopping else { return }
        let waits = tenantStore.waits
        if !waits.current.isEmpty { waits.cancelAll() }
        withObservationTracking {
            _ = waits.current
        } onChange: {
            Task { @MainActor [weak self] in self?.endWaitsWhileStopping() }
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
        self.isStopping = false
        self.activeMigration = nil
        self.activeDelete = nil
        if invalidatesAfterRun {
            // the tenants changed during the run: its plan is for other tenants
            invalidatesAfterRun = false
            invalidateDerivedState()
            return
        }
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
        // on real failures the plan stays, so Resume Run can retry
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
            AppActivity.record("The run report couldn’t be saved: \(error.localizedDescription)",
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
        // a load belongs to this pair and is the newest one: a slower,
        // earlier load (Back and Continue), or one for tenants chosen since,
        // is dropped when it ends
        mappingLoad += 1
        let load = mappingLoad
        let pair = Self.connectionKey(sourceTenant) + ">" + Self.connectionKey(destTenant)
        let source = tenantStore.client(for: sourceTenant)
        let dest = tenantStore.client(for: destTenant)
        Task { [weak self] in
            let sourceADE = (try? await MappingCatalog.adeInstances(on: source)) ?? []
            let destADE = (try? await MappingCatalog.adeInstances(on: dest)) ?? []
            let sourceDPs = (try? await MappingCatalog.distributionPoints(on: source)) ?? []
            let destDPs = (try? await MappingCatalog.distributionPoints(on: dest)) ?? []
            guard let self, load == self.mappingLoad else { return }
            guard pair == Self.connectionKey(self.sourceTenant) + ">" + Self.connectionKey(self.destTenant) else {
                // the tenants changed while it loaded: none of this is theirs
                self.isLoadingMappings = false
                return
            }
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

    /// Counts mapping loads, so only the newest one applies its result.
    @ObservationIgnored private var mappingLoad = 0

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
        // the types Preview plans: never the gateway-only ones a direct tenant can't reach
        let typeKeys = previewTypeKeys
        Task { [weak self] in
            let result = await exporter.backup(typeKeys: typeKeys, to: root)
            guard let self else { return }
            self.backupResult = result
            self.isBackingUp = false
            self.activeExporter = nil
        }
    }

    /// Plans again after a clone; clean means a second run would write nothing.
    /// - Returns: whether Verify started (false: `lastError` says why).
    @discardableResult
    func verify() -> Bool {
        guard let sourceTenant, let destTenant, !isVerifying, let secrets = readServiceSecrets() else { return false }
        isVerifying = true
        verifyReport = nil
        let source = tenantStore.client(for: sourceTenant)
        let dest = tenantStore.client(for: destTenant)
        // after a run: what it carried out; otherwise the selection
        let typeKeys = lastRunTypeKeys ?? previewTypeKeys
        let excluding = lastRunTypeKeys == nil ? [:] : lastRunExcluded
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
        return true
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
