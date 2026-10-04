//
//  JamfMigratorTests.swift
//  JamfMigratorTests
//
//  Unit tests for Jamf Migrator. New service-layer sources are compiled
//  into both the app and this bundle; the bundle has no test host, so
//  running tests does not launch the app.
//

import Testing

struct JamfMigratorTests {

    @Test func harnessRuns() {
        #expect(Bool(true), "Swift Testing harness is wired up")
    }

}
