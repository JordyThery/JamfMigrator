//
//  UpdateCheckerTests.swift
//  JamfMigratorTests
//
//  The GitHub update check: version comparison, the once-a-day automatic
//  check, and what it offers.
//

import Foundation
import Testing
@testable import JamfMigrator

@Suite("Update check")
@MainActor
struct UpdateCheckerTests {

    @Test("Versions compare numerically, component by component",
          arguments: [
              ("1.0.2", "1.0.1", true), ("1.1", "1.0.9", true), ("1.10", "1.9", true), ("2.0", "1.99.99", true),
              ("1.0.1", "1.0.1", false), ("1.0", "1.0.0", false), ("1.0.0", "1.0", false), ("1.0.1", "1.0.2", false),
          ])
    func isNewer(candidate: String, current: String, expected: Bool) {
        #expect(UpdateChecker.isNewer(candidate, than: current) == expected)
    }

    @Test("A newer release is offered once, with notes and the zip asset")
    func offersNewerRelease() async throws {
        let requests = Locked<[URLRequest]>([])
        let session = MockHTTP.session { request in
            requests.withLock { $0.append(request) }
            return releaseReply(tag: "v1.0.3")
        }
        let defaults = freshDefaults()
        let checker = UpdateChecker(defaults: defaults, session: session, currentVersion: "1.0.2")

        await checker.checkAutomatically()

        let request = try #require(requests.value.first)
        #expect(request.url?.absoluteString == "https://api.github.com/repos/JordyThery/JamfMigrator/releases/latest")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        guard case let .available(release) = checker.status else {
            Issue.record("expected an available release, got \(checker.status)"); return
        }
        #expect(release.version == "1.0.3", "the leading v is dropped")
        #expect(release.notes == "**Fixed** things.")
        #expect(release.downloadURL?.lastPathComponent == "JamfMigrator-1.0.3.zip")
        #expect(checker.isPresented)

        // the next day the same release is not offered again
        defaults.set(Date.distantPast, forKey: "lastUpdateCheck")
        checker.isPresented = false
        await checker.checkAutomatically()
        #expect(requests.value.count == 2)
        #expect(!checker.isPresented)
    }

    @Test("The installed or an older release is not offered", arguments: ["v1.0.2", "v1.0.1"])
    func ignoresOlderRelease(tag: String) async {
        let session = MockHTTP.session { _ in releaseReply(tag: tag) }
        let checker = UpdateChecker(defaults: freshDefaults(), session: session, currentVersion: "1.0.2")
        await checker.checkAutomatically()
        #expect(!checker.isPresented)
        #expect(checker.status == .idle)
    }

    @Test("Nothing is sent when the daily check is off, or already ran today")
    func respectsSettings() async {
        let requests = Locked(0)
        let session = MockHTTP.session { _ in
            requests.withLock { $0 += 1 }
            return releaseReply(tag: "v9.0")
        }

        let off = freshDefaults()
        off.set(false, forKey: UpdateChecker.automaticCheckKey)
        await UpdateChecker(defaults: off, session: session, currentVersion: "1.0").checkAutomatically()

        let recent = freshDefaults()
        recent.set(Date(), forKey: "lastUpdateCheck")
        await UpdateChecker(defaults: recent, session: session, currentVersion: "1.0").checkAutomatically()

        #expect(requests.value == 0)
    }

    @Test("A failed automatic check stays silent")
    func silentFailure() async {
        let session = MockHTTP.session { _ in MockHTTP.Reply(status: 503) }
        let checker = UpdateChecker(defaults: freshDefaults(), session: session, currentVersion: "1.0")
        await checker.checkAutomatically()
        #expect(!checker.isPresented)
        #expect(checker.status == .idle)
    }

    @Test("A manual check reports up to date")
    func manualUpToDate() async throws {
        let session = MockHTTP.session { _ in releaseReply(tag: "v1.0.2") }
        let checker = UpdateChecker(defaults: freshDefaults(), session: session, currentVersion: "1.0.2")
        checker.checkManually()
        #expect(checker.isPresented)
        for _ in 0..<100 where checker.status == .checking {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(checker.status == .upToDate)
    }
}

private func releaseReply(tag: String) -> MockHTTP.Reply {
    let version = tag.dropFirst()
    return MockHTTP.Reply(status: 200, data: MockHTTP.json([
        "tag_name": tag,
        "name": "Jamf Migrator \(version)",
        "body": "**Fixed** things.",
        "html_url": "https://github.com/JordyThery/JamfMigrator/releases/tag/\(tag)",
        "assets": [["name": "JamfMigrator-\(version).zip",
                    "browser_download_url": "https://github.com/JordyThery/JamfMigrator/releases/download/\(tag)/JamfMigrator-\(version).zip"]],
    ]))
}

private func freshDefaults() -> UserDefaults {
    let name = "jamfmigrator-update-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name) ?? .standard
    defaults.removePersistentDomain(forName: name)
    return defaults
}
