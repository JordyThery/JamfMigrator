//
//  RunReportFileTests.swift
//  JamfMigratorTests
//
//  The report each run saves to Run Reports: what was created, changed,
//  deleted, skipped and failed, redacted.
//

import Foundation
import Testing
@testable import JamfMigrator

struct RunReportFileTests {

    private static let started = ISO8601DateFormatter().date(from: "2026-10-26T13:32:05Z")!

    private func file(_ entries: [RunReportEntry], mode: RunMode = .copy, stopped: Bool = false) -> RunReportFile {
        RunReportFile(report: RunReport(entries: entries),
                      mode: mode,
                      sourceName: mode == .copy ? "Acme Prod" : nil,
                      destinationName: "Acme Test",
                      started: Self.started,
                      finished: Self.started.addingTimeInterval(585),
                      wasStopped: stopped,
                      appVersion: "9.9.9")
    }

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RunReports-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func aCopyRunListsEveryOutcome() {
        let text = file([
            RunReportEntry(type: "categories", objectId: "5", objectName: "Utilities", status: .created(destId: "18")),
            RunReportEntry(type: "scripts", objectId: "7", objectName: "Dock", status: .updated(destId: "9"),
                           warnings: ["Check the parameters"]),
            RunReportEntry(type: "scripts", objectId: "8", objectName: "Same", status: .unchanged(destId: "10")),
            RunReportEntry(type: "blueprints", objectId: "-", objectName: "(all objects)",
                           status: .blocked(reason: "requires the Jamf Platform API gateway")),
            RunReportEntry(type: "scripts", objectId: "12", objectName: "Install Rosetta",
                           status: .failed(reason: "HTTP 400: bad")),
        ]).text

        #expect(text.contains("Copy · Source: Acme Prod → Destination: Acme Test"))
        #expect(text.contains("Jamf Migrator 9.9.9"))
        #expect(text.contains("Created 1 · Changed 1 · Skipped 2 · Failed 1"))
        #expect(text.contains("## Failed\n- Scripts › \"Install Rosetta\" (id 12): HTTP 400: bad"))
        #expect(text.contains("- Scripts › \"Same\" (id 8): unchanged"))
        #expect(text.contains("- Blueprints › (all objects): requires the Jamf Platform API gateway"))
        #expect(text.contains("## Created\n- Categories › \"Utilities\" (id 5) → id 18 on the destination"))
        #expect(text.contains("## Changed\n- Scripts › \"Dock\" (id 7) → id 9 on the destination"))
        #expect(text.contains("## Review after the run\n- Scripts › \"Dock\" (id 7): Check the parameters"))
        #expect(!text.contains("## Deleted"))
        #expect(!text.contains("stopped"))
    }

    @Test func aDeleteRunCountsDeletions() {
        let text = file([
            RunReportEntry(type: "scripts", objectId: "3", objectName: "Old", status: .deleted),
        ], mode: .delete).text

        #expect(text.contains("Delete · Tenant: Acme Test"))
        #expect(text.contains("Deleted 1 · Skipped 0 · Failed 0"))
        #expect(text.contains("## Deleted\n- Scripts › \"Old\" (id 3)\n"))
    }

    @Test func aStoppedRunSaysSo() {
        let text = file([], stopped: true).text
        #expect(text.contains("· Stopped "))
        #expect(text.contains("The run was stopped before the end"))
        #expect(text.contains("Nothing was done."))
    }

    @Test func secretsInReasonsAreRedacted() {
        let text = file([
            RunReportEntry(type: "scripts", objectId: "1", objectName: "A",
                           status: .failed(reason: #"client_secret=abc123 "password": "hunter2" Bearer eyJhbGci"#)),
        ]).text
        #expect(!text.contains("abc123"))
        #expect(!text.contains("hunter2"))
        #expect(!text.contains("eyJhbGci"))
        #expect(text.contains("<redacted>"))
    }

    @Test func eachRunGetsItsOwnFile() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = file([])

        let first = try report.save(in: folder)
        let second = try report.save(in: folder)

        #expect(first.lastPathComponent.hasSuffix("-copy.md"))
        #expect(first.lastPathComponent.hasPrefix("2026102"))
        #expect(second != first)
        #expect(second.lastPathComponent.hasSuffix("-copy-2.md"))
        #expect(try String(contentsOf: first, encoding: .utf8) == report.text)
    }
}
