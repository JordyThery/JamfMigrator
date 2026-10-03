//
//  Poll.swift
//  JamfMigrator
//
//  Waits for gateway state that isn't ready straight after a write:
//  PreStage profileUuid, benchmark syncState, 404s just after a create.
//

import Foundation

enum Poll {
    /// Runs `operation` until it returns a value, sleeping `interval` between
    /// tries. Returning nil means "not ready yet". Throws
    /// `GatewayError.pollTimeout` once `timeout` has passed.
    static func until<T: Sendable>(_ what: String,
                                   timeout: Duration = .seconds(30),
                                   interval: Duration = .seconds(1),
                                   operation: @Sendable () async throws -> T?) async throws -> T {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            if let value = try await operation() {
                return value
            }
            guard clock.now + interval <= deadline else {
                throw GatewayError.pollTimeout(what)
            }
            try await clock.sleep(for: interval)
        }
    }
}
