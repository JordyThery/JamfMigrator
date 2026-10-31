//
//  JamfMigratorTests.swift
//  JamfMigratorTests
//
//  Unit tests for Jamf Migrator. The app is the test host; it starts like a
//  sandbox run and never reaches a saved tenant (see `SavedTenantGuard`).
//

import Testing

struct JamfMigratorTests {

    @Test func harnessRuns() {
        #expect(Bool(true), "Swift Testing harness is wired up")
    }

}
