//
//  JamfProStep7Tests.swift
//  JamfMigratorTests
//
//  ROADMAP step 7 (JTKit 0.8.3): privileges from JTKit's table on every
//  request and in the pre-run check, JTKit's Jamf Pro page reader, Classic
//  error pages read as their message, the sign-in hint on a direct Jamf Pro
//  tenant, and licence serial numbers kept out of the activity log and the
//  run report.
//

import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import JamfMigrator

/// Two saved tenants in a tenant store, on one fake server that tells them
/// apart by host (direct) or Environment ID (gateway). Every request goes to
/// the activity log, as in the app.
@MainActor
private struct Tenants {
    let store: TenantStore
    let log: ActivityLog
    let source: Tenant
    let destination: Tenant
    let directory: URL
    let requests: Locked<[(tenant: String, method: String, path: String)]>

    /// - Parameter handler: answers ("src" or "dst", method, path as sent);
    ///   nil gives the empty answer of that kind of list.
    init(direct: Bool = true, username: String? = nil, tokenStatus: Int = 200,
         handler: @escaping @Sendable (_ tenant: String, _ method: String, _ path: String) -> MockHTTP.Reply?) throws {
        let requests = Locked<[(tenant: String, method: String, path: String)]>([])
        let session = MockHTTP.session { request in
            let path = request.url?.path ?? ""
            if ["/auth/token", "/api/oauth/token", "/api/v1/auth/token"].contains(path) {
                guard tokenStatus == 200 else {
                    return MockHTTP.Reply(status: tokenStatus, headers: ["Content-Type": "application/json"],
                                          data: Data(#"{"error":"invalid_client"}"#.utf8))
                }
                return path == "/api/v1/auth/token"
                    ? MockHTTP.Reply(status: 200, data: MockHTTP.json(["token": "user-token", "expires": "2099-01-01T00:00:00.000Z"]))
                    : MockHTTP.tokenJSON()
            }
            let tenant = switch (request.url?.host, request.value(forHTTPHeaderField: "X-Environment-Id")) {
            case ("src.jamfcloud.com"?, _), (_, TestEnvironment.source?): "src"
            default: "dst"
            }
            let method = request.httpMethod ?? ""
            requests.withLock { $0.append((tenant, method, path)) }
            if let reply = handler(tenant, method, path) { return reply }
            if method == "GET" && (path.hasPrefix("/JSSResource/") || path.hasPrefix("/proclassic/")) {
                return MockHTTP.Reply(status: 200, data: Data("{}".utf8))
            }
            if method == "GET" {
                return MockHTTP.Reply(status: 200, data: Data(#"{"totalCount":0,"results":[]}"#.utf8))
            }
            return MockHTTP.Reply(status: 404)
        }
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Step7-\(UUID().uuidString)", isDirectory: true)
        let secrets = InMemorySecretStore()
        log = ActivityLog()
        store = TenantStore(directory: directory, secrets: secrets, log: log, session: session)

        func tenant(_ name: String, host: String, environment: String) -> Tenant {
            var tenant = Tenant(name: name, environmentId: environment, clientId: "client-\(host)")
            if direct {
                tenant.serverURL = "https://\(host).jamfcloud.com"
                tenant.username = username
            }
            return tenant
        }
        source = tenant("Source", host: "src", environment: TestEnvironment.source)
        destination = tenant("Destination", host: "dst", environment: TestEnvironment.destination)
        for tenant in [source, destination] {
            try store.connections.save(tenant)
            _ = secrets.setSecret("s3cr3t-value", for: tenant.id.uuidString)
        }
        self.requests = requests
    }

    var sourceClient: JamfPlatform.Client { store.client(for: source) }
    var destinationClient: JamfPlatform.Client { store.client(for: destination) }

    /// Everything the activity log holds, as the bug-report export would see it.
    var logText: String {
        log.entries.map { "\($0.detail) \($0.note ?? "") \($0.request.map { "\($0)" } ?? "") \($0.identifiers)" }
            .joined(separator: "\n")
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func reason(_ status: ObjectStatus?) -> String {
    switch status {
    case .failed(let reason)?, .blocked(let reason)?: reason
    default: ""
    }
}

// MARK: - The object list's privileges

struct ObjectAccessTests {

    @Test func everyTypeNamesItsPermissionAndPrivileges() {
        for type in ObjectRegistry.types {
            let access = type.access
            #expect(!access.capability.isEmpty, "\(type.key)")
            #expect(access.readPermission.hasPrefix(access.capability + ":"), "\(type.key)")
            if type.requiresGateway {
                // Platform namespaces have no Jamf Pro privileges
                #expect(access.read.isEmpty && access.create.isEmpty, "\(type.key)")
                continue
            }
            #expect(!access.read.isEmpty, "\(type.key) has no read privilege")
            #expect(!access.update.isEmpty, "\(type.key) has no update privilege")
            if case .singleton = type.listShape {
                // settings are only read and updated
                #expect(access.create.isEmpty && access.delete.isEmpty, "\(type.key)")
            } else {
                #expect(!access.create.isEmpty && !access.delete.isEmpty, "\(type.key)")
            }
        }
    }

    @Test func privilegesFollowTheMethod() throws {
        let policies = try #require(ObjectRegistry.type("policies")).access
        #expect(policies.privileges(for: .get) == [.readPolicies])
        #expect(policies.privileges(for: .post) == [.createPolicies])
        #expect(policies.privileges(for: .put) == [.updatePolicies])
        #expect(policies.privileges(for: .delete) == [.deletePolicies])
        #expect(policies.readPermission == "policies:read")

        // Jamf's API asks for the update permission to read LAPS settings
        let laps = try #require(ObjectRegistry.type("lapssettings")).access
        #expect(laps.readPermission == "local-admin-passwords:update")
        #expect(laps.read.first == .updateLocalAdminPasswordSettings)
    }

    /// The check sends the real permission and privilege, no longer an empty one.
    @Test func thePermissionCheckNamesThePermission() throws {
        let check = Preflight.permissionCheck(try #require(ObjectRegistry.type("osxconfigurationprofiles")))
        #expect(check.permission == "configuration-profiles:read")
        #expect(check.jamfProPrivilege == "Read macOS Configuration Profiles")
        #expect(check.path == "proclassic/osxconfigurationprofiles")
        #expect(check.query.isEmpty)
    }
}

// MARK: - What to grant

@MainActor
struct WhatToGrantTests {

    private static let forbidden = MockHTTP.Reply(status: 403, data: MockHTTP.json(["httpStatus": 403, "errors": []]))
    private static let version = MockHTTP.Reply(status: 200, data: MockHTTP.json(["version": "11.33.1"]))

    private static func refusing(_ refused: Set<String>) -> @Sendable (String, String, String) -> MockHTTP.Reply? {
        { tenant, method, path in
            if path.hasSuffix("/v1/jamf-pro-version") { return version }
            return refused.contains("\(tenant) \(path)") ? forbidden : nil
        }
    }

    @Test func aGatewayTenantNamesTheJamfAccountPermissions() async throws {
        let tenants = try Tenants(direct: false, handler: Self.refusing(["src /pro/v1/buildings", "src /proclassic/policies"]))
        defer { tenants.cleanUp() }

        let report = await Preflight.run(source: tenants.sourceClient, dest: tenants.destinationClient,
                                         typeKeys: ["categories", "buildings", "policies"])

        #expect(report.missingPermissionTypes == ["buildings", "policies"])
        #expect(report.sourceGrant == "Add the “buildings:read” and “policies:read” permissions to the API integration in Jamf Account.")
        #expect(report.destinationGrant == nil)
        #expect(report.grants.map(\.tenant) == ["Source"])
    }

    @Test func aDirectTenantNamesTheAPIRolePrivileges() async throws {
        let tenants = try Tenants(handler: Self.refusing(["dst /api/v1/buildings", "dst /JSSResource/usergroups"]))
        defer { tenants.cleanUp() }

        let report = await Preflight.run(source: tenants.sourceClient, dest: tenants.destinationClient,
                                         typeKeys: ["buildings", "usergroups", "scripts"])

        #expect(report.sourceGrant == nil)
        // user groups need both their privileges
        #expect(report.destinationGrant == "Add the “Read Buildings”, “Read Smart User Groups” and “Read Static User Groups” privileges to the API role in Jamf Pro under Settings › API Roles and Clients.")
    }

    @Test func aUserAccountIsPointedToItsOwnPrivileges() async throws {
        let tenants = try Tenants(username: "admin", handler: Self.refusing(["src /JSSResource/policies"]))
        defer { tenants.cleanUp() }

        let report = await Preflight.run(source: tenants.sourceClient, dest: tenants.destinationClient, typeKeys: ["policies"])

        #expect(report.sourceGrant == "Add the “Read Policies” privilege to the user account in Jamf Pro under Settings › User Accounts and Groups.")
    }
}

// MARK: - A refused request names its privilege

@MainActor
struct RefusedRequestTests {

    @Test func aRefusedCreateNamesTheCreatePrivilege() async throws {
        let tenants = try Tenants { tenant, method, path in
            switch (tenant, method, path) {
            case ("src", "GET", "/api/v1/categories"):
                MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 1, "results": [["id": "5", "name": "Utilities"]]]))
            case ("src", "GET", "/api/v1/categories/5"):
                MockHTTP.Reply(status: 200, data: MockHTTP.json(["id": "5", "name": "Utilities", "priority": 9]))
            case ("dst", "POST", "/api/v1/categories"):
                MockHTTP.Reply(status: 403, data: MockHTTP.json(["httpStatus": 403, "errors": []]))
            default: nil
            }
        }
        defer { tenants.cleanUp() }

        let engine = MigrationEngine(source: tenants.sourceClient, dest: tenants.destinationClient, journal: makeJournal())
        let report = await engine.migrate(typeKeys: ["categories"])

        let text = reason(report.entries.first?.status)
        #expect(text.contains("The API role is missing the “Create Categories” privilege. Add it in Jamf Pro under Settings › API Roles and Clients."))
    }

    @Test func aRefusedDeleteNamesTheDeletePrivilege() async throws {
        let tenants = try Tenants { tenant, method, path in
            switch (method, path) {
            case ("GET", "/JSSResource/policies"):
                MockHTTP.Reply(status: 200, data: MockHTTP.json(["policies": [["id": 4, "name": "Install Chrome"]]]))
            case ("DELETE", "/JSSResource/policies/id/4"):
                MockHTTP.Reply(status: 403, data: Data("<html><body><p>Forbidden</p></body></html>".utf8))
            default: nil
            }
        }
        defer { tenants.cleanUp() }

        let engine = DeleteEngine(client: tenants.destinationClient, journal: makeJournal(mode: .delete))
        let report = await engine.delete(typeKeys: ["policies"])

        let text = reason(report.entries.first?.status)
        #expect(text.contains("The API role is missing the “Delete Policies” privilege."))
    }
}

// MARK: - Lists through JTKit's page reader

@MainActor
struct PagedListTests {

    @Test func everyPageIsRead() async throws {
        let pages = Locked([String]())
        // 450 scripts, 200 per page
        let session = MockHTTP.session { request in
            if request.url?.path == "/api/oauth/token" { return MockHTTP.tokenJSON() }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let page = Int(query.first { $0.name == "page" }?.value ?? "") ?? -1
            let size = Int(query.first { $0.name == "page-size" }?.value ?? "") ?? -1
            pages.withLock { $0.append("\(page)/\(size)") }
            let ids = (page * size)..<min((page + 1) * size, 450)
            return MockHTTP.Reply(status: 200, data: MockHTTP.json(
                ["totalCount": 450, "results": ids.map { ["id": $0, "name": "Script \($0)"] }]))
        }
        let client = JamfPlatform.Client.fakeDirect(session: session)

        let refs = try await ObjectLister.list(try #require(ObjectRegistry.type("scripts")), on: client)

        #expect(refs.count == 450)
        #expect(refs.first == ObjectRef(id: "0", name: "Script 0"))
        #expect(pages.value == ["0/200", "1/200", "2/200"])
    }

    /// An answer without a list used to read as "nothing there", which in
    /// delete mode or Wipe meant "nothing to delete".
    @Test func anAnswerWithoutAListIsAnErrorNotAnEmptyList() async throws {
        let session = MockHTTP.session { request in
            if request.url?.path == "/api/oauth/token" { return MockHTTP.tokenJSON() }
            return MockHTTP.Reply(status: 200, data: MockHTTP.json(["message": "maintenance"]))
        }
        let client = JamfPlatform.Client.fakeDirect(session: session)

        await #expect(throws: JamfPlatformError.self) {
            _ = try await ObjectLister.list(try #require(ObjectRegistry.type("scripts")), on: client)
        }
    }

    @Test func aListThatNeverEndsStopsWithAnError() async throws {
        let session = MockHTTP.session { request in
            if request.url?.path == "/api/oauth/token" { return MockHTTP.tokenJSON() }
            // always a full page, and always more to come
            return MockHTTP.Reply(status: 200, data: MockHTTP.json(
                ["totalCount": 1_000_000, "results": (0..<200).map { ["id": $0, "name": "x"] }]))
        }
        let client = JamfPlatform.Client.fakeDirect(session: session)

        await #expect {
            _ = try await ObjectLister.list(try #require(ObjectRegistry.type("scripts")), on: client)
        } throws: { error in
            guard let error = error as? JamfPlatformError, case .pageLimitReached = error.kind else { return false }
            return true
        }
    }

    @Test func deviceGroupsAreReadPageByPage() async throws {
        let session = MockHTTP.session { request in
            if request.url?.path == "/auth/token" { return MockHTTP.tokenJSON() }
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "page" }?.value
            let results: [[String: Any]] = page == "0"
                ? (0..<200).map { ["groupPlatformId": "uuid-\($0)", "groupName": "Group \($0)"] }
                : [["groupPlatformId": "uuid-200", "groupName": "Last"], ["groupName": "No id"]]
            return MockHTTP.Reply(status: 200, data: MockHTTP.json(["totalCount": 202, "results": results]))
        }
        let groups = try await MappingCatalog.platformGroups(on: JamfPlatform.Client.fake(session: session))

        #expect(groups.count == 201)
        #expect(groups.last == ObjectRef(id: "uuid-200", name: "Last"))
    }
}

// MARK: - Classic error pages and the sign-in hint

@MainActor
struct ReadableErrorTests {

    @Test func aClassicErrorPageReadsAsItsMessage() async throws {
        let page = """
            <html><head><title>Status page</title></head><body style="font-family:sans-serif;">
            <p style="font-size:1.2em;font-weight:bold;">Conflict</p>
            <p>Error: Duplicate name</p>
            <p>You can get technical details <a href="http://www.w3.org/Protocols/rfc2616/rfc2616-sec10.html#sec10.4.10">here</a>.<br></p>
            </body></html>
            """
        let tenants = try Tenants { tenant, method, path in
            switch (tenant, method, path) {
            case ("src", "GET", "/JSSResource/policies"):
                MockHTTP.Reply(status: 200, data: MockHTTP.json(["policies": [["id": 10, "name": "Install Chrome"]]]))
            case ("src", "GET", "/JSSResource/policies/id/10"):
                MockHTTP.Reply(status: 200, data: Data("<policy><general><id>10</id><name>Install Chrome</name></general></policy>".utf8))
            case ("dst", "POST", "/JSSResource/policies/id/0"):
                MockHTTP.Reply(status: 409, headers: ["Content-Type": "text/html"], data: Data(page.utf8))
            default: nil
            }
        }
        defer { tenants.cleanUp() }

        let engine = MigrationEngine(source: tenants.sourceClient, dest: tenants.destinationClient, journal: makeJournal())
        let report = await engine.migrate(typeKeys: ["policies"])
        let text = reason(report.entries.first?.status)

        #expect(text.hasPrefix("HTTP 409 Conflict"))
        #expect(text.contains("Error: Duplicate name"))
        #expect(!text.contains("<p"))
        #expect(!text.contains("technical details"))
        let file = RunReportFile(report: report, mode: .copy, sourceName: "Source", destinationName: "Destination",
                                 started: .now, finished: .now, wasStopped: false)
        #expect(file.text.contains("Error: Duplicate name"))
        #expect(!file.text.contains("<html"))
    }

    @Test func aWrongSecretOnADirectTenantMentionsNoRegion() async throws {
        let tenants = try Tenants(tokenStatus: 401) { _, _, _ in nil }
        defer { tenants.cleanUp() }

        let check = await Preflight.check(tenants.sourceClient)

        let message = try #require(check.error)
        #expect(message.contains("Check the client ID and client secret, and that the API client is enabled in Jamf Pro under Settings › API Roles and Clients."))
        #expect(!message.localizedCaseInsensitiveContains("region"))
        #expect(!message.contains("Jamf Account"))
    }

    @Test func aWrongPasswordOnADirectTenantSaysJustThat() async throws {
        let tenants = try Tenants(username: "admin", tokenStatus: 401) { _, _, _ in nil }
        defer { tenants.cleanUp() }

        let message = try #require(await Preflight.check(tenants.sourceClient).error)
        #expect(message.contains("Check the username and password."))
        #expect(!message.localizedCaseInsensitiveContains("region"))
        #expect(!message.contains("client secret"))
    }
}

// MARK: - Licence serial numbers

@MainActor
struct LicenceSerialTests {

    static let serials = ["SERIAL-AAAA-1111-ZZ", "SERIAL-BBBB-2222-YY"]

    /// Licensed software as the Classic API returns it, with its serials.
    static let licensedSoftware = """
        <licensed_software><general><id>3</id><name>Office</name><publisher>Microsoft</publisher>\
        <platform>Mac</platform><send_email_on_violation>false</send_email_on_violation></general>\
        <software_definitions/><font_definitions/><plugin_definitions/>\
        <licenses><license><size>10</size><serial_number_1>\(serials[0])</serial_number_1>\
        <serial_number_2>\(serials[1])</serial_number_2><organization_name>Lab</organization_name>\
        <registered_to>IT</registered_to><license_type>Standard</license_type></license></licenses>\
        <computers><computer><id>1</id><name>Mac</name></computer></computers></licensed_software>
        """

    private static func tenants(destinationAnswer: MockHTTP.Reply, destinationHasIt: Bool = false) throws -> Tenants {
        try Tenants { tenant, method, path in
            switch (tenant, method, path) {
            case ("src", "GET", "/JSSResource/licensedsoftware"), ("dst", "GET", "/JSSResource/licensedsoftware") where tenant == "src" || destinationHasIt:
                MockHTTP.Reply(status: 200, data: MockHTTP.json(["licensed_software": [["id": 3, "name": "Office"]]]))
            case ("src", "GET", "/JSSResource/licensedsoftware/id/3"):
                MockHTTP.Reply(status: 200, data: Data(licensedSoftware.utf8))
            case ("dst", "GET", "/JSSResource/licensedsoftware/id/3"):
                // an older copy (another licence size), so Preview plans an update
                MockHTTP.Reply(status: 200, data: Data(licensedSoftware.replacingOccurrences(of: "<size>10</size>", with: "<size>5</size>").utf8))
            case ("dst", "POST", "/JSSResource/licensedsoftware/id/0"), ("dst", "PUT", "/JSSResource/licensedsoftware/id/3"):
                destinationAnswer
            default: nil
            }
        }
    }

    private func expectNoSerial(in text: String, _ comment: Comment) {
        for serial in Self.serials {
            #expect(!text.contains(serial), comment)
        }
    }

    private func runReport(_ report: RunReport) -> String {
        RunReportFile(report: report, mode: .copy, sourceName: "Source", destinationName: "Destination",
                      started: .now, finished: .now, wasStopped: false).text
    }

    @Test func aCopiedLicenceKeepsItsSerialsOutOfTheLogAndTheReport() async throws {
        let tenants = try Self.tenants(destinationAnswer: MockHTTP.Reply(
            status: 201, data: Data("<licensed_software><id>8</id></licensed_software>".utf8)))
        defer { tenants.cleanUp() }

        let engine = MigrationEngine(source: tenants.sourceClient, dest: tenants.destinationClient, journal: makeJournal())
        let report = await engine.migrate(typeKeys: ["licensedsoftware"])

        #expect(report.entries.first?.status == .created(destId: "8"))
        #expect(!tenants.log.entries.isEmpty)
        expectNoSerial(in: tenants.logText, "activity log")
        expectNoSerial(in: runReport(report), "run report")
    }

    @Test func anUpdatedLicenceKeepsItsSerialsOutOfTheLogAndTheReport() async throws {
        let tenants = try Self.tenants(destinationAnswer: MockHTTP.Reply(
            status: 201, data: Data("<licensed_software><id>3</id></licensed_software>".utf8)), destinationHasIt: true)
        defer { tenants.cleanUp() }

        let engine = MigrationEngine(source: tenants.sourceClient, dest: tenants.destinationClient, journal: makeJournal())
        let report = await engine.migrate(typeKeys: ["licensedsoftware"])

        #expect(report.entries.first?.status == .updated(destId: "3"))
        expectNoSerial(in: tenants.logText, "activity log")
        expectNoSerial(in: runReport(report), "run report")
    }

    /// The hard case: Jamf Pro refuses the write and its error page repeats
    /// a serial number. Error answers are recorded and shown, so the serial
    /// must be taken out of both.
    @Test func aRefusedLicenceKeepsItsSerialsOutEvenWhenTheServerRepeatsThem() async throws {
        let page = "<html><body><p>Conflict</p><p>Error: Serial number \(Self.serials[0]) is invalid</p></body></html>"
        let tenants = try Self.tenants(destinationAnswer: MockHTTP.Reply(
            status: 409, headers: ["Content-Type": "text/html"], data: Data(page.utf8)))
        defer { tenants.cleanUp() }

        let engine = MigrationEngine(source: tenants.sourceClient, dest: tenants.destinationClient, journal: makeJournal())
        let report = await engine.migrate(typeKeys: ["licensedsoftware"])

        guard case .failed(let reason) = report.entries.first?.status else {
            Issue.record("Expected a failure, got \(String(describing: report.entries.first?.status))")
            return
        }
        expectNoSerial(in: tenants.logText, "activity log")
        expectNoSerial(in: runReport(report), "run report")
        // what went wrong stays readable
        #expect(reason.hasPrefix("HTTP 409 Conflict"))
        #expect(reason.contains("Error: Serial number <redacted> is invalid"))
        // the write is recorded without contents; the other requests as usual
        let write = try #require(tenants.log.entries.first { $0.detail == "/JSSResource/licensedsoftware/id/0" })
        #expect(write.status == 409)
        #expect(write.request?.contentsWithheld == true)
        #expect(tenants.log.entries.first { $0.detail == "/JSSResource/licensedsoftware" }?.request?.contentsWithheld == false)
    }

    @Test func onlyTheSerialsAreBlankedOut() throws {
        let type = try #require(ObjectRegistry.type("licensedsoftware"))
        let values = type.secretValues(in: Self.licensedSoftware)
        #expect(Set(values) == Set(Self.serials))
        #expect(MigrationEngine.blankingOut(values, in: "Error: Duplicate name") == "Error: Duplicate name")
        #expect(ObjectRegistry.type("policies")?.secretValues(in: Self.licensedSoftware).isEmpty == true)
    }
}
