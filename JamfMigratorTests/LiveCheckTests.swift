//
//  LiveCheckTests.swift
//  JamfMigratorTests
//
//  Live checks (JTKit ROADMAP step 11), run only by scripts/release-check.sh,
//  which switches them on (JTKIT_LIVE=1) and passes the credentials it read
//  from the login Keychain. ⌘U skips them. Tenants are named by role only:
//  jamf-test-a (the source, Jamf Platform API) and jamf-test-b (the
//  destination, over the Jamf Platform API and over its direct Jamf Pro
//  connection with a username and password).
//
//  Every request goes through JTKitLiveCheck's guarded network: creates only
//  with the run's JTKTEST prefix, changes and deletes only of objects this run
//  created. On top of that:
//  - the app's engine reads the source through a read-only copy of that
//    network, so the app itself never writes to the source;
//  - the app's engine reaches the destination through a fence that lets only
//    reads, sign-ins and creates through. Anything else (an update, a delete)
//    is refused before it leaves the Mac, stops the engine and fails the check;
//  - before a run, the destination must not have any of the run's names and
//    the app's Preview must plan exactly the test objects, all as Create.
//  Test objects are made and removed by the test code, never by the app.
//
//  The app runs in the App Sandbox, so the test host reaches only its own
//  container: the release check puts the allow-list copy, ledger and results
//  there (JTKit 0.12.2, `TEST_HOST_CONTAINER`). The app's journal goes to a
//  temporary folder of this run's; no export, no run report in Application
//  Support, never the saved tenants.
//

import Foundation
import JTKit
import JTKitLiveCheck
import JTKitTestSupport
import Synchronization
import Testing
@testable import JamfMigrator

private let live = LiveCheckRun.isEnabled

#if JTKIT_FAULT_BREAK_BUILD
// Set only by `release-check.sh --fault break-build`, to check that a broken
// build stops the release check before anything reaches a tenant.
#error("Build broken on purpose by the release check's --fault break-build")
#endif

// MARK: The connections

/// One allow-listed connection as the checks use it: an in-memory tenant
/// (never saved), the app's own client for it, and a client for the test code.
@MainActor
struct LiveConnection {
    let role: String
    let service: AllowList.Service
    let tenant: Tenant
    /// The ledger's name for this connection.
    let target: String
    /// The app's own client (its `TenantStore`), on the network given.
    let app: JamfPlatform.Client
    /// The test code's client (the app's `TenantStore` too) on the guarded
    /// network: the test objects, the read-back and the removal.
    let api: JamfPlatform.Client

    var label: String {
        "\(role) (\(service == .jamfPlatform ? "Platform API" : "Jamf Pro direct"))"
    }

    /// - Parameter appSession: the network the app's client uses.
    init(run: LiveCheckRun, role: String, service: AllowList.Service, folder: URL, appSession: URLSession) throws {
        self.role = role
        self.service = service
        let entry = try run.entry(role: role, service: service)
        let secret: String
        switch service {
        case .jamfPlatform:
            let region = try #require(JamfRegion(rawValue: entry.region ?? ""))
            tenant = Tenant(name: "Live check \(role)", region: region,
                            environmentId: try #require(entry.environmentID),
                            clientId: try run.credential(role, "client-id"))
            secret = try run.credential(role, "client-secret")
        case .jamfPro:
            let host = try #require(entry.host)
            tenant = Tenant(name: "Live check \(role) direct", serverURL: "https://\(host)",
                            username: try run.credential(role, "jamfpro-username"))
            secret = try run.credential(role, "jamfpro-password")
        default:
            throw LiveFailure("\(service) isn't used by Jamf Migrator")
        }
        target = try run.target(role: role, service: service)
        let tenant = tenant
        func store(_ name: String, session: URLSession) throws -> TenantStore {
            let secrets = InMemorySecretStore()
            _ = secrets.setSecret(secret, for: tenant.id.uuidString)
            let directory = folder.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return TenantStore(directory: directory, secrets: secrets, log: nil, session: session)
        }
        app = try store("app-\(role)-\(service.rawValue)", session: appSession).client(for: tenant)
        api = try store("api-\(role)-\(service.rawValue)", session: run.network.session).client(for: tenant)
    }

    /// Cancels the test code's token on a direct Jamf Pro connection (the
    /// gateway's tokens can't be cancelled; they end after 15 minutes).
    /// - Parameter includingApp: also the app's client's token (only when
    ///   the app's client signed in; otherwise this would sign it in first).
    func cancelTokens(includingApp: Bool = false) async throws -> String? {
        guard service == .jamfPro else { return nil }
        var notes: [String] = []
        for (name, client) in [("test code", api)] + (includingApp ? [("app", app)] : []) {
            do {
                let response = try await client.send(HTTPRequest(method: "POST", path: "pro/v1/auth/invalidate-token"))
                notes.append("\(name): \(response.status)")
            } catch let error as JamfPlatformError where error.status == 401 {
                // never signed in, or already cancelled
                notes.append("\(name): no token")
            }
        }
        return notes.joined(separator: ", ")
    }
}

/// The checks' error with a plain reason.
struct LiveFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: The destination fence

/// Lets the app's engine read, sign in and create on the destination, and
/// nothing else. A change or delete is refused before it is sent, the engine
/// is stopped, and the check fails: the migration may never change anything
/// on the destination this run didn't create, and in a test run it only
/// creates. Sits in front of the guarded network.
final class DestinationFence: @unchecked Sendable {
    static let header = "X-JTKTEST-Fence"
    static let fences = Mutex<[UUID: DestinationFence]>([:])

    let id = UUID()
    let inner: URLSession
    private let lock = NSLock()
    private var refused: [String] = []
    private var stop: (@Sendable () -> Void)?

    init(inner: URLSession) {
        self.inner = inner
        Self.fences.withLock { $0[id] = self }
    }

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FenceProtocol.self]
        configuration.httpAdditionalHeaders = [Self.header: id.uuidString]
        return URLSession(configuration: configuration)
    }

    var refusals: [String] { lock.withLock { refused } }

    /// What to do on a refusal: stop the engine.
    func onRefusal(_ stop: @escaping @Sendable () -> Void) {
        lock.withLock { self.stop = stop }
    }

    func refuse(_ request: String) {
        let stop = lock.withLock { () -> (@Sendable () -> Void)? in
            refused.append(request)
            return self.stop
        }
        stop?()
    }

    static let signInPaths: Set<String> = ["/auth/token", "/api/oauth/token", "/api/v1/auth/token",
                                           "/api/v1/auth/invalidate-token", "/api/v1/auth/keep-alive"]

    /// Reads, sign-ins, and a POST that creates: to a collection (no object
    /// id anywhere in the path) or Classic's `…/id/0`.
    static func allows(method: String, path: String) -> Bool {
        switch method.uppercased() {
        case "GET", "HEAD":
            return true
        case "POST":
            if signInPaths.contains(path) { return true }
            let segments = path.split(separator: "/").map(String.init)
            if let index = segments.lastIndex(of: "id") {
                return index == segments.count - 2 && segments.last == "0"
            }
            return !segments.contains { $0.allSatisfy(\.isNumber) || UUID(uuidString: $0) != nil }
        default:
            return false
        }
    }
}

private final class FenceProtocol: URLProtocol, @unchecked Sendable {
    private var forwarding: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let value = request.value(forHTTPHeaderField: DestinationFence.header), let id = UUID(uuidString: value),
              let fence = DestinationFence.fences.withLock({ $0[id] }) else {
            client?.urlProtocol(self, didFailWithError: LiveFailure("A request without its fence"))
            return
        }
        var forwarded = request
        forwarded.setValue(nil, forHTTPHeaderField: DestinationFence.header)
        let method = forwarded.httpMethod ?? "GET"
        let path = forwarded.url?.path(percentEncoded: false) ?? ""
        guard DestinationFence.allows(method: method, path: path) else {
            fence.refuse("\(method) \(path)")
            client?.urlProtocol(self, didFailWithError: LiveFailure("The fence refused \(method) \(path): the migration may only create on the destination"))
            return
        }
        let client = client
        forwarding = Task { [self] in
            do {
                let (data, response) = try await fence.inner.data(for: forwarded)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {
        forwarding?.cancel()
    }
}

// MARK: Test objects

/// The kinds of test object, with their paths and the privileges they need.
enum TestKind: String, CaseIterable {
    case profile, script, staticGroup, classicGroup, category

    /// The ledger's name for the kind (as the guarded network records it).
    var resource: String {
        switch self {
        case .profile: "osxconfigurationprofiles"
        case .script: "scripts"
        case .staticGroup: "static-groups"
        case .classicGroup: "computergroups"
        case .category: "categories"
        }
    }

    init?(resource: String) {
        let normalized = Ledger.Item(target: "", resource: resource, id: "", name: "").resource
        guard let kind = Self.allCases.first(where: {
            Ledger.Item(target: "", resource: $0.resource, id: "", name: "").resource == normalized
        }) else { return nil }
        self = kind
    }

    func deletePath(id: String) -> String {
        switch self {
        case .profile: JamfClassic.path("osxconfigurationprofiles", id: id)
        case .script: "pro/v1/scripts/\(id)"
        case .staticGroup: "pro/v3/computer-groups/static-groups/\(id)"
        case .classicGroup: JamfClassic.path("computergroups", id: id)
        case .category: "pro/v1/categories/\(id)"
        }
    }

    var deletePrivilege: JamfPro.Privilege {
        switch self {
        case .profile: .deleteMacOSConfigurationProfiles
        case .script: .deleteScripts
        case .staticGroup, .classicGroup: .deleteStaticComputerGroups
        case .category: .deleteCategories
        }
    }

    /// Removed in an order Jamf accepts: what uses a category or group first.
    var removalRank: Int {
        switch self {
        case .profile: 0
        case .script: 1
        case .staticGroup, .classicGroup: 2
        case .category: 3
        }
    }
}

@MainActor
extension LiveConnection {

    func createCategory(name: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["name": name, "priority": 9])
        let response = try await api.send(HTTPRequest(method: "POST", path: "pro/v1/categories", body: body,
                                                      contentType: "application/json"),
                                          privilege: .createCategories)
        return try #require(ObjectLister.text(try LosslessJSON(data: response.data)["id"]), "The category create returned no id")
    }

    func createScript(name: String, categoryID: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [
            "name": name, "categoryId": categoryID, "priority": "AFTER",
            "info": "Release check test object; removed after the run", "notes": "",
            "scriptContents": LiveMigrationTests.scriptContents,
        ])
        let response = try await api.send(HTTPRequest(method: "POST", path: "pro/v1/scripts", body: body,
                                                      contentType: "application/json"),
                                          privilege: .createScripts)
        return try #require(ObjectLister.text(try LosslessJSON(data: response.data)["id"]), "The script create returned no id")
    }

    /// An empty static computer group, never smart. Its name is the first `<name>`.
    func createEmptyStaticGroup(name: String) async throws -> String {
        let xml = "<computer_group><name>\(Self.escape(name))</name><is_smart>false</is_smart><computers/></computer_group>"
        let response = try await api.send(HTTPRequest(method: "POST", path: JamfClassic.createPath("computergroups"),
                                                      body: Data(xml.utf8), accept: "application/xml", contentType: "application/xml"),
                                          privilege: .createStaticComputerGroups)
        return try #require(JamfClassic.createdID(in: response.data), "The group create returned no id")
    }

    /// Whether the group named `name` is static with no members.
    func groupIsEmptyStatic(named name: String) async throws -> (empty: Bool, note: String) {
        guard let group = try await api.classicGroups(.computer).first(where: { $0.name == name }) else {
            return (false, "not listed")
        }
        let members = try await api.classicGroupMembers(group)
        return (!group.isSmart && members.isEmpty, "\(group.isSmart ? "smart" : "static"), \(members.count) members")
    }

    /// A macOS profile with one Managed Preferences payload (a made-up domain,
    /// one key) in the test category, scoped to nothing.
    func createProfile(name: String, category: String) async throws -> String {
        let top = UUID().uuidString, payload = UUID().uuidString
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\
        <plist version="1.0"><dict>\
        <key>PayloadUUID</key><string>\(top)</string><key>PayloadType</key><string>Configuration</string>\
        <key>PayloadIdentifier</key><string>\(top)</string><key>PayloadDisplayName</key><string>\(Self.escape(name))</string>\
        <key>PayloadVersion</key><integer>1</integer><key>PayloadScope</key><string>System</string>\
        <key>PayloadContent</key><array><dict>\
        <key>PayloadType</key><string>com.apple.ManagedClient.preferences</string>\
        <key>PayloadIdentifier</key><string>\(payload)</string><key>PayloadUUID</key><string>\(payload)</string>\
        <key>PayloadVersion</key><integer>1</integer><key>PayloadDisplayName</key><string>JTKTEST Preferences</string>\
        <key>PayloadContent</key><dict><key>\(LiveMigrationTests.domain)</key><dict><key>Forced</key><array><dict>\
        <key>mcx_preference_settings</key><dict><key>\(LiveMigrationTests.key)</key><true/></dict>\
        </dict></array></dict></dict>\
        </dict></array></dict></plist>
        """
        // the profile's own name comes first: the guarded network reads the first <name>
        let xml = """
        <os_x_configuration_profile><general><name>\(Self.escape(name))</name>\
        <description>Release check test object; removed after the run</description>\
        <category><name>\(Self.escape(category))</name></category>\
        <distribution_method>Install Automatically</distribution_method><user_removable>false</user_removable>\
        <level>System</level><redeploy_on_update>Newly Assigned</redeploy_on_update>\
        <payloads>\(Self.escape(plist))</payloads></general>\
        <scope><all_computers>false</all_computers><all_jss_users>false</all_jss_users></scope></os_x_configuration_profile>
        """
        let response = try await api.send(HTTPRequest(method: "POST", path: JamfClassic.createPath("osxconfigurationprofiles"),
                                                      body: Data(xml.utf8), accept: "application/xml", contentType: "application/xml"),
                                          privilege: .createMacOSConfigurationProfiles)
        return try #require(JamfClassic.createdID(in: response.data), "The profile create returned no id")
    }

    func profileXML(id: String) async throws -> String {
        let response = try await api.send(HTTPRequest(path: JamfClassic.path("osxconfigurationprofiles", id: id),
                                                      accept: "application/xml"),
                                          privilege: .readMacOSConfigurationProfiles)
        return String(decoding: response.data, as: UTF8.self)
    }

    /// Scoped to nothing: no computer, group, building, department, user or
    /// limitation; not all computers, not all users.
    static func isScopedToNothing(_ xml: String) -> Bool {
        let scope = ClassicXML.value(of: "scope", in: xml)
        guard !scope.isEmpty else { return false }
        return !scope.contains("<id>") && !scope.contains("<name>")
            && scope.contains("<all_computers>false</all_computers>")
            && !scope.contains("<all_jss_users>true</all_jss_users>")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Every category, script, static group and macOS profile named as a test object.
    func testObjects(_ run: LiveCheckRun) async throws -> [(kind: TestKind, id: String, name: String)] {
        var found: [(TestKind, String, String)] = []
        for (kind, key) in [(TestKind.category, "categories"), (.script, "scripts"),
                            (.staticGroup, "staticcomputergroups"), (.profile, "osxconfigurationprofiles")] {
            let type = try #require(ObjectRegistry.type(key))
            found += try await ObjectLister.list(type, on: api).filter { run.isSweepable($0.name) }.map { (kind, $0.id, $0.name) }
        }
        return found
    }

    /// Deletes a test object; already gone (404) counts as removed. A group
    /// or category still in use (409, 422) is retried for up to two minutes.
    func delete(_ kind: TestKind, id: String) async throws {
        let deadline = Date().addingTimeInterval(120)
        while true {
            do {
                _ = try await api.send(HTTPRequest(method: "DELETE", path: kind.deletePath(id: id),
                                                   accept: kind == .profile || kind == .classicGroup ? "application/xml" : nil,
                                                   safeToRepeat: true),
                                       privilege: kind.deletePrivilege)
                return
            } catch let error as JamfPlatformError where error.status == 404 {
                return
            } catch let error as JamfPlatformError where (error.status == 409 || error.status == 422) && Date() < deadline {
                try await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Deletes what the ledger still lists for this connection, in removal order.
    func removeOutstanding(_ run: LiveCheckRun) async -> [String] {
        var problems: [String] = []
        let items = run.ledger.outstanding.filter { $0.target == target }
            .sorted { (TestKind(resource: $0.resource)?.removalRank ?? 9) < (TestKind(resource: $1.resource)?.removalRank ?? 9) }
        for item in items {
            guard let kind = TestKind(resource: item.resource) else {
                problems.append("no way to remove \(item.resource) \(item.id)")
                continue
            }
            do {
                try await delete(kind, id: item.id)
            } catch {
                problems.append("\(item.resource) \(item.id): \(failure(error))")
            }
        }
        return problems
    }
}

/// This run's folder for the app's files, in the test host's temporary
/// directory (inside the app's container), never Application Support.
func liveFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "jm-live-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return folder
}

/// A failed step's reason, naming the missing Jamf privilege when the tenant refused one.
func failure(_ error: any Error) -> String {
    if let error = error as? JamfPlatformError, error.status == 401 || error.status == 403 {
        return "MISSING PRIVILEGE on the API client's role or the account: \(error.localizedDescription)"
    }
    return String(describing: error)
}

/// The app never reached a saved tenant while it ran under tests (unit test
/// host, smoke tests, live checks): recorded as a step, so any attempt is in
/// the report and fails the run.
@discardableResult
func checkNoSavedTenantRequests(_ run: LiveCheckRun, when: String) -> Bool {
    let attempts = SavedTenantGuard.shared.attempts()
    let note = attempts.isEmpty ? nil
        : attempts.prefix(10).map { "\($0.process): \($0.what) (tenant \($0.tenant))" }.joined(separator: "; ")
    run.record(step: "no request to a saved tenant under tests (\(when))", passed: attempts.isEmpty,
               note: attempts.isEmpty ? nil : "\(attempts.count) refused: \(note ?? "")")
    #expect(attempts.isEmpty, "\(attempts)")
    return attempts.isEmpty
}

/// A network for the app's source client: the guarded network's rules with
/// every write refused, so the app only ever reads the source.
func readOnlyNetwork(_ run: LiveCheckRun) -> LiveCheckNetwork {
    LiveCheckNetwork(policy: LiveCheckPolicy(allowList: run.allowList, roles: run.roles, includeProduction: false,
                                             prefix: run.prefix, ledger: run.ledger, writesAllowed: false))
}

enum LiveRoles {
    static let source = "jamf-test-a"
    static let destination = "jamf-test-b"
}

// MARK: Stage 1: sign in

@MainActor
@Suite("Live: sign in", .enabled(if: live), .serialized)
struct LiveSignInTests {
    /// A sign-in and a small read on each connection: jamf-test-a and
    /// jamf-test-b over the Platform API, jamf-test-b over Jamf Pro direct
    /// (username and password, token cancelled afterwards). Reads only.
    @Test func signInAndRead() async throws {
        let run = try LiveCheckRun.current()
        let folder = try liveFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        checkNoSavedTenantRequests(run, when: "start")
        let connections: [(String, AllowList.Service)] = [(LiveRoles.source, .jamfPlatform),
                                                          (LiveRoles.destination, .jamfPlatform),
                                                          (LiveRoles.destination, .jamfPro)]
        for (role, service) in connections where run.roles.contains(role) {
            let name = "sign in: \(role) (\(service == .jamfPlatform ? "Platform API" : "Jamf Pro direct"))"
            do {
                let connection = try LiveConnection(run: run, role: role, service: service, folder: folder,
                                                    appSession: run.network.session)
                let leftovers = try await connection.testObjects(run).count
                let version = await Preflight.check(connection.api).version ?? "unknown"
                let cancelled = try await connection.cancelTokens()
                run.record(step: name, passed: true,
                           note: "Jamf Pro \(version); \(leftovers) left-over test objects" + (cancelled.map { "; token cancelled (\($0))" } ?? ""))
            } catch {
                run.record(step: name, passed: false, note: failure(error))
                throw error
            }
        }
        #expect(run.network.refusals.isEmpty, "\(run.network.refusals)")
    }
}

// MARK: Stage 4: the main task, live

@MainActor
@Suite("Live: migrate test objects from jamf-test-a to jamf-test-b, read back, remove", .enabled(if: live), .serialized)
struct LiveMigrationTests {
    static let domain = "com.example.jtktest"
    static let key = "JTKTESTFlag"
    static let scriptContents = "#!/bin/sh\n# Release check test object; does nothing and is removed after the run\nexit 0\n"

    /// jamf-test-a → jamf-test-b over the Platform API: a category, an empty
    /// static group, a script in the category, a profile in the category scoped to nothing.
    @Test func platformToPlatform() async throws {
        try await migrate(over: .jamfPlatform, kinds: [.category, .staticGroup, .script, .profile], label: "")
    }

    /// jamf-test-a → jamf-test-b over its direct Jamf Pro connection
    /// (username and password): a category and a profile in it, scoped to
    /// nothing. Covers the Jamf Pro API and the Classic API on a direct server.
    @Test func platformToDirect() async throws {
        try await migrate(over: .jamfPro, kinds: [.category, .profile], label: "Direct ")
    }

    /// The same check for each destination connection.
    private func migrate(over destinationService: AllowList.Service, kinds: Set<TestKind>, label: String) async throws {
        let run = try LiveCheckRun.current()
        guard run.roles.contains(LiveRoles.source), run.roles.contains(LiveRoles.destination) else { return }
        let folder = try liveFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        checkNoSavedTenantRequests(run, when: "before the \(label.isEmpty ? "Platform" : "direct") migration")

        let sourceNetwork = readOnlyNetwork(run)
        let fence = DestinationFence(inner: run.network.session)
        let source = try LiveConnection(run: run, role: LiveRoles.source, service: .jamfPlatform, folder: folder,
                                        appSession: sourceNetwork.session)
        let destination = try LiveConnection(run: run, role: LiveRoles.destination, service: destinationService,
                                             folder: folder, appSession: fence.session)
        let step = { (name: String) in "\(source.role) → \(destination.label): \(name)" }
        func attempt<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
            do {
                return try await body()
            } catch {
                run.record(step: step(name), passed: false, note: failure(error))
                throw error
            }
        }
        func require(_ name: String, _ passed: Bool, note: String? = nil) throws {
            run.record(step: step(name), passed: passed, note: note)
            if !passed { throw LiveFailure("\(step(name)): \(note ?? "failed")") }
        }

        // 1. The test objects on the source, made by the test code.
        let names = [TestKind.category: "\(run.prefix) – \(label)Category", .staticGroup: "\(run.prefix) – \(label)Group",
                     .script: "\(run.prefix) – \(label)Script", .profile: "\(run.prefix) – \(label)Profile"]
            .filter { kinds.contains($0.key) }
        var sourceIDs: [TestKind: String] = [:]
        let categoryName = try #require(names[.category])
        sourceIDs[.category] = try await attempt("create the source category") { try await source.createCategory(name: categoryName) }
        if let name = names[.staticGroup] {
            sourceIDs[.staticGroup] = try await attempt("create an empty static group on the source") {
                try await source.createEmptyStaticGroup(name: name)
            }
            let group = try await source.groupIsEmptyStatic(named: name)
            try require("the source group is static with 0 members", group.empty, note: group.note)
        }
        if let name = names[.script], let categoryID = sourceIDs[.category] {
            sourceIDs[.script] = try await attempt("create the source script") { try await source.createScript(name: name, categoryID: categoryID) }
        }
        if let name = names[.profile] {
            let id = try await attempt("create the source profile") { try await source.createProfile(name: name, category: categoryName) }
            sourceIDs[.profile] = id
            try require("the source profile is scoped to nothing", LiveConnection.isScopedToNothing(try await source.profileXML(id: id)))
        }

        // The app's registry keys for the kinds, with the source ids to take.
        let typeKeys: [TestKind: String] = [.category: "categories", .staticGroup: "staticcomputergroups",
                                            .script: "scripts", .profile: "osxconfigurationprofiles"]
        var limit: [String: Set<String>] = [:]
        for (kind, id) in sourceIDs { limit[typeKeys[kind]!, default: []].insert(id) }
        let only = OnlyObjects(testing: limit)

        // 2. Before writing: none of the names on the destination, and the
        //    app's Preview plans exactly the test objects, all as Create.
        for (kind, name) in names {
            let type = try #require(ObjectRegistry.type(typeKeys[kind]!))
            let existing = try await ObjectLister.list(type, on: destination.app).filter { $0.name == name }
            try require("\(type.displayName): the name isn't on the destination", existing.isEmpty, note: name)
        }
        let plan = await MigrationPlanner(source: source.app, dest: destination.app).plan(typeKeys: only.typeKeys, only: only)
        let allCreates = plan.entries.allSatisfy { if case .create = $0.change { true } else { false } }
        let planned = Set(plan.entries.map { "\($0.typeKey) \($0.objectId)" })
        let wanted = Set(limit.flatMap { key, ids in ids.map { "\(key) \($0)" } })
        try require("Preview plans only the test objects, all as Create", allCreates && planned == wanted && plan.entries.count == wanted.count,
                    note: plan.entries.map { "\($0.typeKey) \($0.name): \($0.change)" }.joined(separator: "; "))

        // 3. Migrate with the app's own engine; its journal in this run's folder, no export.
        let engine = MigrationEngine(source: source.app, dest: destination.app,
                                     journal: JournalStore(url: folder.appending(path: "journal.json"), mode: .copy))
        fence.onRefusal { Task { await engine.cancel() } }
        let report = await engine.migrate(typeKeys: only.typeKeys, only: only)
        var destIDs: [TestKind: String] = [:]
        for entry in report.entries {
            if let kind = typeKeys.first(where: { $0.value == entry.type })?.key, case .created(let id) = entry.status {
                destIDs[kind] = id
            }
        }
        let onlyCreates = report.entries.count == wanted.count
            && report.entries.allSatisfy { if case .created = $0.status { true } else { false } }
        // On a failed write: the fields the app sent (names only), to tell a
        // Jamf hiccup from a payload Jamf refuses.
        var sentFields: [String] = []
        for entry in report.entries {
            guard case .failed = entry.status, let type = ObjectRegistry.type(entry.type),
                  case .json(let json)? = try? await ObjectLister.detail(type, id: entry.objectId, on: source.app) else { continue }
            var context = TransformContext()
            context.action = .create
            if case .write(let object) = ProTransformer.transform(type: type, json: json, context: context),
               let body = try? JSONSerialization.jsonObject(with: object.body) as? [String: Any] {
                sentFields.append("\(entry.type) sent fields: \(body.keys.sorted().joined(separator: ", ")); source fields: \(json.keys.sorted().joined(separator: ", "))")
            }
        }
        try require("the app's engine created exactly the test objects, nothing else",
                    onlyCreates && fence.refusals.isEmpty && sourceNetwork.refusals.isEmpty,
                    note: (report.entries.map { "\($0.type) \($0.objectName): \($0.status)" }
                           + fence.refusals.map { "fence refused \($0)" }
                           + sourceNetwork.refusals.map { "source write refused: \($0)" } + sentFields).joined(separator: "; "))
        // Only with `release-check.sh --fault fail-live-step`: fails with
        // objects on both tenants, so cleanup has to remove them.
        if label.isEmpty { try run.injectFault("fail-live-step", at: step("failure after creating objects")) }

        // 4. Read back on the destination.
        if let id = destIDs[.category] {
            let json = try await destination.api.json("pro/v1/categories/\(id)", privilege: .readCategories)
            try require("read back: the category", json["name"]?.stringValue == categoryName
                        && json["priority"]?.numberValue?.intValue == 9)
        }
        if let name = names[.staticGroup] {
            let group = try await destination.groupIsEmptyStatic(named: name)
            try require("read back: the group is static with 0 members", destIDs[.staticGroup] != nil && group.empty, note: group.note)
        }
        if let id = destIDs[.script], let name = names[.script] {
            let json = try await destination.api.json("pro/v1/scripts/\(id)", privilege: .readScripts)
            let sameCategory = ObjectLister.text(json["categoryId"]) == destIDs[.category]
            try require("read back: the script, its contents and category", json["name"]?.stringValue == name
                        && json["scriptContents"]?.stringValue == Self.scriptContents && sameCategory)
        }
        if let id = destIDs[.profile], let name = names[.profile] {
            let xml = try await destination.profileXML(id: id)
            let general = ClassicXML.value(of: "general", in: xml)
            let payloads = ClassicXML.value(of: "payloads", in: general)
            let holds = ClassicXML.value(of: "name", in: general) == name
                && ClassicXML.value(of: "name", in: ClassicXML.value(of: "category", in: general)) == categoryName
                && payloads.contains(Self.domain) && payloads.contains(Self.key)
            try require("read back: the profile, its setting and category", holds)
            try require("read back: the profile is scoped to nothing", LiveConnection.isScopedToNothing(xml))
        }

        // 5. The app's Verify, with the counts checked here too (Verify alone
        //    can pass a type it couldn't read).
        let verify = await Verifier.verify(source: source.app, dest: destination.app, typeKeys: only.typeKeys, only: only)
        // What differs, field by field (the planner's diff, as Preview shows it).
        let again = await MigrationPlanner(source: source.app, dest: destination.app).plan(typeKeys: only.typeKeys, only: only)
        let differences = again.entries.flatMap { entry in
            entry.diff.map { (typeKey: entry.typeKey, field: $0) }
        }
        // The one known Jamf difference, accepted only on a Jamf Pro 11.34.0
        // beta destination (decided by Jordy on 2026-10-28): the beta drops a
        // profile's Self Service notification settings on save; the app sends
        // them. Anything else must match. Recheck when 11.34 is released.
        let version = await Preflight.check(destination.api).version ?? ""
        let betaQuirk = { (difference: (typeKey: String, field: DiffEntry)) -> Bool in
            version.hasPrefix("11.34.0-b") && difference.typeKey == "osxconfigurationprofiles"
                && difference.field.path == "os_x_configuration_profile/self_service/notification"
                && difference.field.destination == nil
        }
        let accepted = differences.filter(betaQuirk)
        let unexpected = differences.filter { !betaQuirk($0) }
        let counted = verify.types.allSatisfy { result in
            result.sourceCount == (limit[result.typeKey]?.count ?? -1) && result.blocked.isEmpty && result.destCount > 0
        }
        // Verify's only discrepancies are profiles whose whole diff is the accepted field
        let explained = verify.types.allSatisfy { result in
            result.discrepancies.isEmpty || (result.typeKey == "osxconfigurationprofiles" && !accepted.isEmpty)
        }
        let describe = { (list: [(typeKey: String, field: DiffEntry)]) in
            list.map { "\($0.typeKey) \($0.field.path): source \(String(($0.field.source ?? "nil").prefix(120))) / destination \(String(($0.field.destination ?? "nil").prefix(120)))" }
        }
        try require("the app's Verify is clean", explained && unexpected.isEmpty && counted && verify.types.count == limit.count,
                    note: (verify.types.map { "\($0.typeKey): \($0.sourceCount) planned, \($0.discrepancies + $0.blocked)" }
                           + describe(unexpected)).joined(separator: "; "))
        if !accepted.isEmpty {
            run.record(step: step("known Jamf difference accepted"), passed: true,
                       note: "Jamf Pro \(version) (beta) drops the profile's Self Service notification settings on save; the app sent them: \(describe(accepted).joined(separator: "; "))")
        }
        try require("Verify made no write", fence.refusals.isEmpty && sourceNetwork.refusals.isEmpty)

        // 6. Remove the objects from both tenants.
        let problems = await destination.removeOutstanding(run) + (await source.removeOutstanding(run))
        let left = try await destination.testObjects(run).filter { names.values.contains($0.name) }
            + (try await source.testObjects(run).filter { names.values.contains($0.name) })
        try require("remove the test objects from both tenants", problems.isEmpty && left.isEmpty,
                    note: (problems + left.map { "still there: \($0.name)" }).joined(separator: "; "))
        if let cancelled = try await destination.cancelTokens(includingApp: true) {
            run.record(step: step("cancel the direct sign-in tokens"), passed: true, note: cancelled)
        }
        #expect(run.ledger.outstanding.filter { [source.target, destination.target].contains($0.target) }.isEmpty)
        #expect(run.network.refusals.isEmpty, "\(run.network.refusals)")
        checkNoSavedTenantRequests(run, when: "after the \(label.isEmpty ? "Platform" : "direct") migration")
    }
}

// MARK: Cleanup (every exit of stage 4)

@MainActor
@Suite("Live: cleanup", .enabled(if: live), .serialized)
struct LiveCleanupTests {
    /// Deletes what the run's ledger still lists (with what an earlier run's
    /// live folder left) on each connection, then sweeps both tenants for
    /// anything still named as a test object. Fails if anything is left. Also
    /// checks, at the very end, that the app never reached a saved tenant
    /// while it ran under tests (unit tests, smoke tests and live checks).
    @Test func removeTestObjects() async throws {
        let run = try LiveCheckRun.current()
        let temporary = FileManager.default.temporaryDirectory
        for folder in (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? [] where folder.hasPrefix("jm-live-") {
            try? FileManager.default.removeItem(at: temporary.appending(path: folder))
        }
        let folder = try liveFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var problems: [String] = []

        var connections: [LiveConnection] = []
        for (role, service) in [(LiveRoles.source, AllowList.Service.jamfPlatform), (LiveRoles.destination, .jamfPlatform),
                                (LiveRoles.destination, .jamfPro)] where run.roles.contains(role) {
            do {
                connections.append(try LiveConnection(run: run, role: role, service: service, folder: folder,
                                                      appSession: run.network.session))
            } catch {
                problems.append("\(role) \(service): \(failure(error))")
            }
        }
        // 1. The ledger, per connection (an object is removed through the
        //    connection that created it).
        let used = Set(run.ledger.outstanding.map(\.target))
        for connection in connections {
            problems += await connection.removeOutstanding(run)
        }
        // 2. The sweep, over the Platform API on both tenants (the direct
        //    connection reaches the same jamf-test-b).
        let platform = connections.filter { $0.service == .jamfPlatform }
        for connection in platform {
            do {
                for object in try await connection.testObjects(run) {
                    try run.adoptForSweep(role: connection.role, service: connection.service,
                                          resource: object.kind.resource, id: object.id, name: object.name)
                }
            } catch {
                problems.append("sweep \(connection.label): \(failure(error))")
            }
            problems += await connection.removeOutstanding(run)
        }
        // the direct sign-in's token, if cleanup signed in there
        for connection in connections where used.contains(connection.target) {
            _ = try? await connection.cancelTokens()
        }

        var still: [String] = []
        for connection in platform {
            still += ((try? await connection.testObjects(run)) ?? []).map { "\(connection.role): \($0.name)" }
        }
        let left = run.ledger.outstanding
        let clean = left.isEmpty && still.isEmpty && problems.isEmpty
        run.record(step: "cleanup", passed: clean,
                   note: clean ? nil : "\(left.count) in the ledger and \(still.count) on the tenants not removed; \(problems.joined(separator: "; "))")
        #expect(left.isEmpty, "\(left.map { "\($0.resource) \($0.id) \($0.name)" })")
        #expect(still.isEmpty, "\(still)")
        #expect(problems.isEmpty, "\(problems)")
        checkNoSavedTenantRequests(run, when: "end of the run")
    }
}
