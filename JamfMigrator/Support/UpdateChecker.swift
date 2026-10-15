//
//  UpdateChecker.swift
//  JamfMigrator
//
//  Checks GitHub for a newer Jamf Migrator release.
//

import Foundation
import Observation

/// A notifier and downloader, not an installer: the sandbox prevents the app
/// from replacing itself, so the update is saved where the user chooses and
/// swapped in by hand. Talks only to GitHub, and sends nothing but the request.
@MainActor
@Observable
final class UpdateChecker {

    /// A published release, reduced to what the update sheet shows.
    struct Release: Sendable, Equatable {
        let version: String
        let name: String
        /// GitHub's release notes, as written (Markdown).
        let notes: String
        /// The release's .zip asset, when it has one.
        let downloadURL: URL?
        let pageURL: URL?
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case failed(String)
    }

    /// `UserDefaults` key for the automatic check. Absent means on.
    static let automaticCheckKey = "checksForUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let lastOfferedKey = "lastOfferedUpdate"
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/JordyThery/JamfMigrator/releases/latest")
    /// At most one automatic check per day.
    private static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    private(set) var status: Status = .idle
    /// Whether the update sheet is shown: always for a manual check, and for
    /// the automatic one only when it finds a new release.
    var isPresented = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let installedVersion: String?

    /// `currentVersion` overrides the bundle's version, for tests.
    init(defaults: UserDefaults = .standard, session: URLSession = .shared, currentVersion: String? = nil) {
        self.defaults = defaults
        self.session = session
        self.installedVersion = currentVersion
    }

    var currentVersion: String {
        installedVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
    }

    /// At most once a day; interrupts only for a release not offered before.
    /// Failures are logged but not shown: a missed check is not worth an alert.
    func checkAutomatically() async {
        guard defaults.object(forKey: Self.automaticCheckKey) == nil || defaults.bool(forKey: Self.automaticCheckKey) else { return }
        let lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastCheck) >= Self.automaticCheckInterval else { return }
        defaults.set(Date(), forKey: Self.lastCheckKey)
        guard let release = try? await fetchLatestRelease() else { return }
        guard Self.isNewer(release.version, than: currentVersion),
              release.version != defaults.string(forKey: Self.lastOfferedKey) else { return }
        defaults.set(release.version, forKey: Self.lastOfferedKey)
        status = .available(release)
        isPresented = true
    }

    /// Checks now and shows the result either way.
    func checkManually() {
        isPresented = true
        status = .checking
        Task {
            do {
                let release = try await fetchLatestRelease()
                status = Self.isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func fetchLatestRelease() async throws -> Release {
        struct Response: Decodable {
            let tag_name: String
            let name: String?
            let body: String?
            let html_url: String?
            let assets: [Asset]?
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
            }
        }
        guard let url = Self.latestReleaseURL else { throw UpdateError(message: "The release address is invalid.") }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                throw UpdateError(message: "GitHub did not answer (HTTP \(status)).")
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let version = decoded.tag_name.hasPrefix("v") ? String(decoded.tag_name.dropFirst()) : decoded.tag_name
            WriteToLog.shared.message("[UpdateChecker] latest release \(version), installed \(currentVersion)")
            return Release(
                version: version,
                name: decoded.name ?? "Jamf Migrator \(version)",
                notes: decoded.body ?? "",
                downloadURL: decoded.assets?.first { $0.name.hasSuffix(".zip") }
                    .flatMap { URL(string: $0.browser_download_url) },
                pageURL: decoded.html_url.flatMap(URL.init(string:))
            )
        } catch {
            WriteToLog.shared.message("[UpdateChecker] check failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Numeric component comparison, so 1.10 is newer than 1.9 and a missing
    /// component counts as zero.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
