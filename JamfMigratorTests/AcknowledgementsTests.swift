import Foundation
import JTKit
import Testing
@testable import JamfMigrator

@Suite("Acknowledgements")
struct AcknowledgementsTests {

    private static var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The licence shown in About must be the one in THIRD-PARTY-NOTICES.md, unchanged.
    @Test func licenceMatchesThirdPartyNotices() throws {
        let notices = try String(contentsOf: Self.repository.appendingPathComponent("THIRD-PARTY-NOTICES.md"), encoding: .utf8)
        let start = try #require(notices.range(of: "```\nMIT License"))
        let end = try #require(notices.range(of: "\n```", range: start.upperBound..<notices.endIndex))
        let fromNotices = String(notices[notices.index(start.lowerBound, offsetBy: 4)..<end.lowerBound])
        let inApp = try #require(Acknowledgement.replicator.license)
        #expect(inApp == fromNotices)
    }

    /// LICENSE keeps Jamf's 2017 notice next to Jordy's; the credit carries the
    /// same notice and the same licence wording.
    @Test func licenceMatchesTheJamfNoticeInLICENSE() throws {
        let license = try String(contentsOf: Self.repository.appendingPathComponent("LICENSE"), encoding: .utf8)
        let jamfNotice = "Copyright (c) 2017 Jamf Professional Services"
        let inApp = try #require(Acknowledgement.replicator.license)
        #expect(license.contains(jamfNotice))
        #expect(inApp.contains(jamfNotice))
        // Without the copyright lines, the two texts are the same word for word.
        func withoutCopyrightLines(_ text: String) -> String {
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix("Copyright (c)") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #expect(withoutCopyrightLines(inApp) == withoutCopyrightLines(license))
    }

    @Test func linksPointToTheOriginalProject() {
        #expect(Acknowledgement.replicator.links.map(\.url.absoluteString) == ["https://github.com/jamf/Replicator"])
    }

    @Test func aboutCreditsReplicator() {
        let about = AboutConfiguration.jamfMigrator
        #expect(about.appName == "Jamf Migrator")
        #expect(about.acknowledgements == [.replicator])
        #expect(Acknowledgement.replicator.heading == "Replicator by Jamf Professional Services")
        #expect(about.links.map(\.url.absoluteString) == ["https://github.com/JordyThery/JamfMigrator"])
    }

    @Test func aboutShowsTheCopyrightLine() {
        #expect(AboutConfiguration.jamfMigrator.copyright?.text == "© 2026 Jordy Thery. Released under the MIT License.")
    }
}
