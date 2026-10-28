//
//  TenantStore.swift
//  JamfMigrator
//
//  The configured tenants (JTKit's saved connections) and platform clients
//  for them.
//

import Foundation
import JTKit
import Observation
import Synchronization

/// The list of configured tenants. JTKit's `ConnectionStore` keeps them where
/// they have always been: tenants.json in Application Support, and each
/// tenant's client secret or password in the Keychain under service
/// "JamfMigrator-tenant", account = the tenant's id.
///
/// It also keeps one JTKit client per tenant, so Source and Destination each
/// have their own sign-in and token, reused by Preview, Run, Backup, Verify
/// and the mappings. A tenant's client is rebuilt after the tenant is edited
/// and dropped when it is deleted.
///
/// Demo mode's two tenants ("Contoso Source (Demo)", "Contoso Destination
/// (Demo)") get their client here too, from JTKit's demo: its private
/// network and a fake secret, never the Keychain or the real network. A
/// saved tenant always gets the real ones, Test Connection included.
@MainActor
@Observable
final class TenantStore {

    /// The Keychain items of tenants and service secrets. Builds before 1.0.1
    /// wrote to the data-protection keychain; such items move over on read.
    nonisolated static func keychain() -> KeychainSecretStore {
        KeychainSecretStore(service: "JamfMigrator-tenant",
                            accessibility: .afterFirstUnlock,
                            movesItemsFromDataProtectionKeychain: true,
                            log: { AppActivity.record($0, category: "Keychain", level: .warning) })
    }

    let connections: ConnectionStore<Tenant>
    /// The same items `connections` uses, read directly at token time, off
    /// the main actor.
    @ObservationIgnored private let secrets: any SecretStore
    /// Where requests are recorded; nil records nothing.
    @ObservationIgnored private let log: ActivityLog?
    @ObservationIgnored private let session: URLSession
    /// Answers demo mode's tenants; nil in tests that don't need it.
    @ObservationIgnored private let demo: DemoMode?
    /// Set while the app runs under tests and this store holds the saved
    /// tenants (the real tenants.json or Keychain items): their clients then
    /// refuse and record every request (see `SavedTenantGuard`).
    @ObservationIgnored private let savedTenantGuard: SavedTenantGuard?
    /// Each tenant's client, with the tenant as it was when the client was made.
    @ObservationIgnored private var clients: [Tenant.ID: (tenant: Tenant, client: JamfPlatform.Client)] = [:]

    init(directory: URL = URL(fileURLWithPath: AppInfo.appSupportPath, isDirectory: true),
         secrets: any SecretStore = TenantStore.keychain(),
         log: ActivityLog? = AppActivity.log,
         session: URLSession = URLSession(configuration: .ephemeral),
         demo: DemoMode? = nil,
         storage: (any ConnectionStorage<Tenant>)? = nil,
         savedTenantGuard: SavedTenantGuard? = nil) {
        self.secrets = secrets
        self.savedTenantGuard = savedTenantGuard
            ?? (UnderTest.isActive && Self.holdsSavedTenants(directory: directory, storage: storage, secrets: secrets)
                ? .shared : nil)
        self.log = log
        self.session = session
        self.demo = demo
        connections = ConnectionStore(
            storage: storage ?? JSONFileConnectionStorage<Tenant>(fileURL: directory.appendingPathComponent("tenants.json")),
            secrets: [.main: SecretLocation(store: secrets)],
            log: { AppActivity.record($0, category: "Tenants", level: .warning) })
    }

    /// Whether a store with these parts holds the saved tenants: the real
    /// tenants.json, or the real Keychain items.
    nonisolated static func holdsSavedTenants(directory: URL, storage: (any ConnectionStorage<Tenant>)?,
                                              secrets: any SecretStore) -> Bool {
        let real = URL(fileURLWithPath: AppInfo.appSupportPath, isDirectory: true).standardizedFileURL
        return (storage == nil && directory.standardizedFileURL.path == real.path) || secrets is KeychainSecretStore
    }

    var tenants: [Tenant] { connections.records }

    func tenant(id: Tenant.ID) -> Tenant? {
        connections.record(id: id)
    }

    // MARK: Clients

    /// The tenant's client, kept for as long as the tenant stays as it is.
    /// The secret (or password) is read from the Keychain at sign-in, so a
    /// corrected secret is used at the next sign-in.
    func client(for tenant: Tenant) -> JamfPlatform.Client {
        if let kept = clients[tenant.id], kept.tenant == tenant {
            return kept.client
        }
        let client = makeClient(for: tenant, secretOverride: nil)
        clients[tenant.id] = (tenant, client)
        return client
    }

    /// A one-off client for Test Connection in Settings, with the values in
    /// the editor and, if typed, a secret that isn't saved yet.
    /// It always uses the real network, also while demo mode is on.
    func testClient(for tenant: Tenant, secretOverride: String?) -> JamfPlatform.Client {
        makeClient(for: tenant, secretOverride: secretOverride.flatMap { $0.isEmpty ? nil : $0 }, usesDemo: false)
    }

    /// Drops a deleted tenant's client and its token.
    func forgetClient(for id: Tenant.ID) {
        clients[id] = nil
    }

    private func makeClient(for tenant: Tenant, secretOverride: String?, usesDemo: Bool = true) -> JamfPlatform.Client {
        let secrets = secrets
        let account = tenant.id.uuidString
        var connection = tenant.connection
        var recorder = RequestRecorder(session: session,
                                       log: log,
                                       service: connection.service.displayName,
                                       connection: tenant.name)

        @Sendable func storedSecret() throws -> String {
            guard let secret = secretOverride ?? secrets.secret(for: account), !secret.isEmpty else {
                throw MissingSecret()
            }
            return secret
        }
        var secret: @Sendable () throws -> String = storedSecret

        // a demo tenant: JTKit's demo network and fake secret, never the
        // Keychain; a saved tenant never gets a demo source, so it can't
        // reach the demo, nor a demo tenant the real network
        if usesDemo, let source = demo?.source(for: connection) {
            connection = source.connection
            secret = source.secret
            recorder = RequestRecorder(session: source.session, log: log,
                                       service: connection.service.displayName, connection: connection.name)
        } else if let savedTenantGuard {
            // under tests a saved tenant is never reached
            return savedTenantGuard.refusingClient(for: tenant)
        }

        do {
            return try JamfPlatform.Client(connection: connection, secret: secret, recorder: recorder,
                                           writeSpacing: JamfPlatform.Client.defaultWriteSpacing)
        } catch {
            // an unusable server URL or Environment ID surfaces at the first
            // request rather than silently falling back to the gateway
            let reason = error as? JamfPlatformError ?? JamfPlatformError(.invalidResponse(error.localizedDescription))
            // organization scope has no Environment ID to check, so this can't throw
            return try! JamfPlatform.Client(baseURL: connection.jamfBaseURL ?? tenant.region.gatewayURL,
                                            scope: .organization,
                                            server: tenant.usesGateway ? .platformAPI : .jamfPro,
                                            tokens: UnusableTokens(error: reason),
                                            recorder: recorder)
        }
    }
}

/// No client secret or password is saved for the tenant.
struct MissingSecret: LocalizedError {
    var errorDescription: String? {
        "No client secret or password is stored for this tenant. Enter it in Settings › Connections."
    }
}

/// The tokens of a tenant whose address can't be used: every request fails
/// with the reason.
private struct UnusableTokens: BearerTokenSource {
    let error: JamfPlatformError

    func token() async throws -> String { throw error }
    func forgetToken() async {}
}

// MARK: - Under tests
//
// What changes while the app runs under tests (the unit tests' host, the UI
// smoke tests, the release check's live checks): it never reaches a saved
// tenant.

enum UnderTest {

    /// The app runs under tests: it hosts the unit tests (Xcode's test
    /// configuration is in its environment) or the UI tests launched it as a
    /// sandbox run (`-JTKitSandbox YES`).
    static let isActive: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
            .contains(where: { environment[$0] != nil }) {
            return true
        }
        return isSandboxRun(ProcessInfo.processInfo.arguments)
    }()

    /// `-JTKitSandbox YES` (or true, 1), read the way JTKit's demo mode reads it.
    static func isSandboxRun(_ arguments: [String]) -> Bool {
        guard let index = arguments.lastIndex(of: DemoMode.sandboxArgument), arguments.indices.contains(index + 1) else {
            return false
        }
        return ["yes", "true", "1"].contains(arguments[index + 1].lowercased())
    }

    /// Where refused attempts to reach a saved tenant are written, one JSON
    /// line each, in the app's temporary folder (inside its container). The
    /// release check empties it before a run and fails the run if it isn't
    /// empty at the end.
    static let savedTenantAttemptsURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("JamfMigrator-under-test", isDirectory: true)
        .appendingPathComponent("saved-tenant-requests.jsonl")
}

/// Refuses, and records, every request to a saved tenant while the app runs
/// under tests: no sign-in, no token refresh, no read. A saved tenant is one
/// from the real tenants.json or the real Keychain items; the tests' own
/// tenants (in memory) and demo mode's tenants are not affected.
final class SavedTenantGuard: Sendable {

    /// One refused attempt. No names, hosts or secrets: the tenant's local id
    /// is shortened to its last four characters.
    struct Attempt: Codable, Equatable, Sendable {
        var time: Date
        var process: String
        var tenant: String
        var what: String
    }

    static let shared = SavedTenantGuard(fileURL: UnderTest.savedTenantAttemptsURL)

    let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The process the attempt came from, for the report.
    private static var process: String {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            ? "unit test host" : "UI test run"
    }

    func record(tenant: Tenant.ID, what: String) {
        let attempt = Attempt(time: Date(), process: Self.process,
                              tenant: "…" + tenant.uuidString.suffix(4), what: what)
        AppActivity.record("Refused under tests: \(what) for a saved tenant", category: "Tests", level: .error)
        guard var line = try? JSONEncoder().encode(attempt) else { return }
        line.append(0x0A)
        lock.withLock {
            let folder = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: fileURL, options: .atomic)
            }
        }
    }

    /// The attempts recorded so far.
    func attempts() -> [Attempt] {
        lock.withLock {
            guard let data = try? Data(contentsOf: fileURL) else { return [] }
            let decoder = JSONDecoder()
            return data.split(separator: 0x0A).compactMap { try? decoder.decode(Attempt.self, from: Data($0)) }
        }
    }

    /// A client for a saved tenant that never sends anything: every token
    /// request (sign-in or refresh) and every request is refused and recorded.
    func refusingClient(for tenant: Tenant) -> JamfPlatform.Client {
        let recorder = RequestRecorder(session: RefusedRequests.session(guard: self, tenant: tenant.id), log: nil)
        // organization scope has no Environment ID to check, so this can't throw
        return try! JamfPlatform.Client(baseURL: tenant.connection.jamfBaseURL ?? tenant.region.gatewayURL,
                                        scope: .organization,
                                        server: tenant.usesGateway ? .platformAPI : .jamfPro,
                                        tokens: RefusedTokens(guard: self, tenant: tenant.id),
                                        recorder: recorder)
    }
}

/// The error a refused request ends with.
struct SavedTenantRefused: LocalizedError {
    var errorDescription: String? {
        "A saved tenant is never reached while the app runs under tests."
    }
}

/// Tokens that are never fetched: each sign-in or refresh is recorded.
private struct RefusedTokens: BearerTokenSource {
    let `guard`: SavedTenantGuard
    let tenant: Tenant.ID

    func token() async throws -> String {
        self.guard.record(tenant: tenant, what: "sign-in")
        throw SavedTenantRefused()
    }

    func forgetToken() async {}
}

/// A session whose requests never leave the Mac: each one is recorded.
private enum RefusedRequests {
    static func session(guard: SavedTenantGuard, tenant: Tenant.ID) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefusingURLProtocol.self]
        configuration.httpAdditionalHeaders = [RefusingURLProtocol.tenantHeader: tenant.uuidString]
        RefusingURLProtocol.guards.withLock { $0[tenant] = `guard` }
        return URLSession(configuration: configuration)
    }
}

private final class RefusingURLProtocol: URLProtocol, @unchecked Sendable {
    static let tenantHeader = "X-JamfMigrator-Saved-Tenant"
    static let guards = Mutex<[Tenant.ID: SavedTenantGuard]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let value = request.value(forHTTPHeaderField: Self.tenantHeader), let tenant = UUID(uuidString: value),
           let tenantGuard = Self.guards.withLock({ $0[tenant] }) {
            tenantGuard.record(tenant: tenant, what: "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")")
        }
        client?.urlProtocol(self, didFailWithError: SavedTenantRefused())
    }

    override func stopLoading() {}
}
