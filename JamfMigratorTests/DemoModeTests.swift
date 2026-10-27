//
//  DemoModeTests.swift
//  JamfMigratorTests
//
//  Demo mode end to end: JTKit's two demo tenants through the real planner,
//  permission check, engine, verifier and delete engine, and what demo mode
//  must never touch (Keychain, saved settings, Run Reports, the real network).
//

import Foundation
import JTKit
import Testing
@testable import JamfMigrator

/// A secret store that records every read and refuses every write, so a test
/// sees whether anything reached the Keychain.
final class TrapSecretStore: SecretStore, @unchecked Sendable {
    let reads = Locked<[String]>([])
    func secret(for account: String) -> String? {
        reads.withLock { $0.append(account) }
        return nil
    }
    @discardableResult
    func setSecret(_ secret: String?, for account: String) -> Bool { false }
}

@MainActor
private struct DemoSetup {
    let demo: DemoMode
    let defaults: UserDefaults
    let secrets = TrapSecretStore()
    /// Every request that reached the real network's stand-in.
    let realRequests = Locked<[URL]>([])
    let store: TenantStore

    init() {
        let suite = "jamfmigrator-demo-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        demo = DemoMode(key: "demoMode", defaults: defaults, arguments: ["app"])
        let realRequests = realRequests
        let session = MockHTTP.session { request in
            realRequests.withLock { $0.append(request.url!) }
            if request.url?.path.hasSuffix("oauth/token") == true { return MockHTTP.tokenJSON() }
            return MockHTTP.Reply(status: 200, data: MockHTTP.json(["version": "11.30.0"]))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DemoModeTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = TenantStore(directory: directory, secrets: secrets, log: nil, session: session, demo: demo)
    }

    var source: JamfPlatform.Client { store.client(for: Tenant(connection: .demoJamfProSource)) }
    var dest: JamfPlatform.Client { store.client(for: Tenant(connection: .demoJamfProDestination)) }

    func appState() -> AppState {
        AppState(tenantStore: store, secretStore: secrets, demo: demo, defaults: defaults)
    }
}

private let allTypes = Set(ObjectRegistry.types.map(\.key))

private func describe(_ entries: [ObjectPlan]) -> String {
    entries.map { "\($0.typeKey) \($0.name): \($0.change)" }.joined(separator: "\n")
}

@Suite("Demo mode", .serialized)
@MainActor
struct DemoModeTests {

    @Test("A whole migration runs through the real engine; afterwards nothing is left to copy")
    func endToEnd() async throws {
        let setup = DemoSetup()
        let source = setup.source, dest = setup.dest
        #expect(!source.supportsPlatformEndpoints && !dest.supportsPlatformEndpoints, "direct Jamf Pro tenants")

        let preflight = await Preflight.run(source: source, dest: dest, typeKeys: allTypes)
        #expect(preflight.source.version?.hasPrefix("11.33") == true && preflight.destination.version?.hasPrefix("11.34") == true)
        #expect(preflight.missingPermissionTypes.isEmpty && preflight.notFoundTypes.isEmpty && preflight.uncheckedTypes.isEmpty)
        #expect(!preflight.destinationIsEmpty)

        let mappings = MappingCatalog.propose(
            sourceADE: try await MappingCatalog.adeInstances(on: source), destADE: try await MappingCatalog.adeInstances(on: dest),
            sourceDPs: try await MappingCatalog.distributionPoints(on: source), destDPs: try await MappingCatalog.distributionPoints(on: dest))
        #expect(mappings.adeInstances == ["1": "4"])

        let plan = await MigrationPlanner(source: source, dest: dest, mappings: mappings).plan(typeKeys: allTypes)
        let blocked = plan.entries.filter { if case .blocked = $0.change { true } else { false } }
        #expect(Set(blocked.map(\.typeKey)) == ["blueprints", "compliancebenchmarks"], "\(describe(blocked))")
        func change(_ type: String, _ name: String) -> PlannedChange? {
            plan.entries.first { $0.typeKey == type && $0.name == name }?.change
        }
        #expect(change("categories", "Contoso Apps").map { if case .unchanged = $0 { true } else { false } } == true)
        #expect(change("categories", "Contoso Security").map { if case .update = $0 { true } else { false } } == true)
        #expect(change("scripts", "Contoso – Set Dock").map { if case .update = $0 { true } else { false } } == true)
        #expect(change("policies", "Contoso – Install Notes").map { if case .create = $0 { true } else { false } } == true)
        #expect(change("checkin", "Check-in settings").map { if case .update = $0 { true } else { false } } == true)
        #expect(plan.entries.contains { $0.warnings.contains { $0.contains("LDAP") } }, "passwords Jamf never returns")

        let report = await MigrationEngine(source: source, dest: dest, journal: makeJournal(), mappings: mappings)
            .migrate(typeKeys: allTypes)
        let failed = report.failures.filter { if case .failed = $0.status { true } else { false } }
        #expect(failed.isEmpty, "\(failed.map { "\($0.type) \($0.objectName): \($0.status)" })")
        let objects = try #require(setup.demo.jamfProDestinationServer.objects)
        #expect(objects.names(at: "JSSResource/policies") == ["Contoso – Install Notes", "Contoso – Old Test Policy", "Contoso – Update Inventory"])
        #expect(objects.names(at: "api/v3/patch-software-title-configurations") == ["Google Chrome"])
        #expect(objects.names(at: "JSSResource/patchpolicies") == ["Contoso – Chrome updates"])
        let policy = try #require(objects.classicXML("policies", named: "Contoso – Install Notes"))
        #expect(policy.contains("<self_service_icon><id>") && policy.contains("Install Contoso Notes"), "the icon, and its display name kept")
        #expect(objects.proObject("v3/computer-prestages", named: "Contoso Macs")?["deviceEnrollmentProgramInstanceId"]?.stringValue == "4")

        let again = await MigrationPlanner(source: source, dest: dest, mappings: mappings).plan(typeKeys: allTypes)
        let left = again.entries.filter {
            switch $0.change {
            case .unchanged: false
            case .blocked: !["blueprints", "compliancebenchmarks"].contains($0.typeKey)
            default: true
            }
        }
        #expect(left.isEmpty, "\(describe(left))")
        let verify = await Verifier.verify(source: source, dest: dest, typeKeys: allTypes, mappings: mappings)
        #expect(verify.isClean, "\(verify.types.filter { !$0.discrepancies.isEmpty })")
        #expect(setup.demo.jamfProSourceServer.objects?.writeCount == 0, "the source is only read")
        #expect(setup.realRequests.value.isEmpty && setup.secrets.reads.value.isEmpty)
    }

    @Test("Delete mode on the demo destination removes everything but the built-ins")
    func deleteMode() async throws {
        let setup = DemoSetup()
        let dest = setup.dest
        let plan = await MigrationPlanner(source: dest, dest: dest).planDeletion(typeKeys: allTypes)
        #expect(plan.entries.contains { $0.name == "Contoso – Old Test Policy" && $0.change == .delete })
        #expect(plan.entries.contains { $0.name == "All Managed Clients" && { if case .keep = $0 { true } else { false } }($0.change) })
        let report = await DeleteEngine(client: dest, journal: makeJournal(mode: .delete)).delete(typeKeys: allTypes)
        let failed = report.failures.filter { if case .failed = $0.status { true } else { false } }
        #expect(failed.isEmpty, "\(failed)")
        let objects = try #require(setup.demo.jamfProDestinationServer.objects)
        #expect(objects.names(at: "JSSResource/policies").isEmpty && objects.names(at: "api/v1/scripts").isEmpty)
        #expect(objects.names(at: "api/v3/computer-groups/smart-groups") == ["All Managed Clients"])
    }

    @Test("In demo mode the app uses the demo tenants and names them in its confirmations")
    func appStateInDemo() throws {
        let setup = DemoSetup()
        let state = setup.appState()
        state.sourceTenantID = UUID()
        state.destTenantID = UUID()
        let savedSource = setup.defaults.string(forKey: "sourceTenantID")
        setup.demo.isOn = true
        defer { setup.demo.isOn = false }
        #expect(state.sourceTenant?.name == "Contoso Source (Demo)")
        #expect(state.destTenant?.name == "Contoso Destination (Demo)")
        #expect(state.destTenant?.isProtected == false && state.canPreview)
        #expect(state.runConfirmationTitle == "Copy to Contoso Destination (Demo)?")
        state.mode = .delete
        #expect(state.runConfirmationTitle == "Delete objects from Contoso Destination (Demo)?")
        #expect(state.destDemo.connections.map(\.name) == ["Contoso Source (Demo)", "Contoso Destination (Demo)"],
                "both demo tenants in delete mode")
        #expect(state.dataDirectory == setup.demo.scratchDirectory)
        #expect(setup.defaults.string(forKey: "sourceTenantID") == savedSource, "the saved choice is left as it was")
    }

    @Test("A demo run writes its report, journal and choices only to demo mode's folder and memory")
    func filesStayInDemo() async throws {
        let setup = DemoSetup()
        let realReports = URL(fileURLWithPath: AppInfo.appSupportPath).appendingPathComponent("Run Reports")
        let before = (try? FileManager.default.contentsOfDirectory(atPath: realReports.path)) ?? []
        let state = setup.appState()
        setup.demo.isOn = true
        defer { setup.demo.isOn = false }
        state.selectedTypeKeys = ["categories", "sites"]
        state.mappings = TenantMappings(adeInstances: ["1": "4"])
        state.preview()
        while state.isPlanning { try await Task.sleep(for: .milliseconds(50)) }
        #expect(state.canRun)
        state.run()
        while state.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        let report = try #require(state.reportFileURL)
        #expect(report.path.hasPrefix(setup.demo.scratchDirectory.path), "\(report.path)")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: realReports.path)) ?? []) == before)
        let keys = setup.defaults.dictionaryRepresentation().keys
        #expect(!keys.contains("selectedTypeKeys") && !keys.contains { $0.hasPrefix("mappings-") })
        #expect(!keys.contains("sourceTenantID") && !keys.contains("destTenantID"))
        #expect(setup.secrets.reads.value.isEmpty, "neither tenant secrets nor Settings › Secrets were read")
        #expect(setup.realRequests.value.isEmpty)
    }

    @Test("Test Connection stays real in demo mode; a saved tenant never reaches the demo")
    func testConnectionIsReal() async throws {
        let setup = DemoSetup()
        setup.demo.isOn = true
        defer { setup.demo.isOn = false }
        let saved = Tenant(name: "Real tenant", clientId: "client", serverURL: "https://real.example.test")
        let check = await Preflight.check(setup.store.testClient(for: saved, secretOverride: "typed"))
        #expect(check.reachable && check.version == "11.30.0")
        #expect(setup.realRequests.value.contains { $0.host() == "real.example.test" })
        _ = await Preflight.check(setup.store.client(for: saved))
        #expect(setup.secrets.reads.value == [saved.id.uuidString], "a saved tenant reads its own secret")
        #expect(setup.demo.jamfProDestinationServer.objects?.requestCount == 0)
        // and a demo tenant given to Test Connection never gets the demo's answers
        _ = await Preflight.check(setup.store.testClient(for: Tenant(connection: .demoJamfProDestination), secretOverride: "x"))
        #expect(setup.demo.jamfProDestinationServer.objects?.requestCount == 0)
    }
}
