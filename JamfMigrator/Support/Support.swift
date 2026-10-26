//
//  Support.swift
//  JamfMigrator
//
//  App metadata, filesystem paths, and the app's lines in the activity log.
//

import Foundation
import JTKit

enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let userAgentHeader = "JamfMigrator/\(version)"

    /// Application Support/JamfMigrator (inside the sandbox container).
    static let appSupportPath: String = {
        let path = NSHomeDirectory() + "/Library/Application Support/JamfMigrator"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()
}

/// The app's activity log (Window › Activity Log, ⇧⌘L): every sign-in and
/// request, written by JTKit, plus the app's own lines. In memory only.
/// Earlier versions wrote these lines to Library/Logs/JamfMigrator/jamfmigrator.log;
/// that file stays on disk and is no longer written.
enum AppActivity {
    enum Level: Sendable {
        case info, warning, error
    }

    @MainActor static let log = ActivityLog()

    /// Adds one of the app's own lines, redacted, from any thread.
    /// - Parameters:
    ///   - category: the entry's source, e.g. "Migration".
    ///   - connection: the tenant it concerns, if any.
    nonisolated static func record(_ message: String,
                                   category: String = "App",
                                   connection: String? = nil,
                                   level: Level = .info) {
        let safe = Redaction.text(message)
        let entry = ActivityLogEntry(category: category,
                                     operation: "",
                                     detail: safe,
                                     failedWithoutStatus: level == .error,
                                     isWarning: level == .warning,
                                     connection: connection,
                                     identifiers: IdentifierMasker.identifiers(inText: safe))
        Task { @MainActor in log.append(entry) }
    }
}
