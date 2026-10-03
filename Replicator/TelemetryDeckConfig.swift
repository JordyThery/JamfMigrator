//
//  TelemetryDeckConfig.swift
//  Replicator
//
//  Telemetry is disabled; set appId to a TelemetryDeck app id to enable it.
//

import Foundation
import TelemetryDeck

@MainActor struct TelemetryDeckConfig {
    static var appId      = ""
    static var optOut     = true
    static var parameters = [String: String]()
}

@MainActor class TelemetryDeckSignal {
    static let shared = TelemetryDeckSignal()

    func send(_ signalName: String, parameters: [String: String] = [:]) {
        if !TelemetryDeckConfig.optOut && !TelemetryDeckConfig.appId.isEmpty {
            TelemetryDeck.signal(signalName, parameters: parameters)
        }
    }
}
