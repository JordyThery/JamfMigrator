//
//  Support.swift
//  JamfMigrator
//
//  The small shared pieces the app rests on: app metadata, paths, and the
//  file logger. This replaces the legacy Globals.swift and WriteToLog.swift.
//

import Foundation

enum AppInfo {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "JamfMigrator"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    static let userAgentHeader = "JamfMigrator/\(version)"

    /// Application Support/JamfMigrator (inside the sandbox container).
    static let appSupportPath: String = {
        let path = NSHomeDirectory() + "/Library/Application Support/JamfMigrator"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()

    /// Library/Logs/JamfMigrator (inside the sandbox container).
    static let logPath: String = {
        let path = NSHomeDirectory() + "/Library/Logs/JamfMigrator"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()
}

/// Appends timestamped lines to the app's log file. The API is kept from the
/// legacy logger so call sites read the same.
final class WriteToLog: @unchecked Sendable {

    static let shared = WriteToLog()

    private let queue = DispatchQueue(label: "be.jordythery.jamfmigrator.log")
    private let logURL = URL(fileURLWithPath: AppInfo.logPath + "/jamfmigrator.log")
    private lazy var timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    func message(_ message: String) {
        queue.async { [self] in
            let line = "\(timestampFormatter.string(from: Date())) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }
    }
}
