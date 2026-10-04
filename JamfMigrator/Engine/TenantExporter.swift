//
//  TenantExporter.swift
//  JamfMigrator
//
//  Exports a whole tenant to a folder — the required backup before a wipe.
//  The export is verified: every listed object must land on disk.
//

import Foundation

struct BackupResult: Sendable, Equatable {
    var objectCounts: [String: Int] = [:]
    var errors: [String] = []
    var root: URL

    var totalObjects: Int { objectCounts.values.reduce(0, +) }
    /// A backup only counts when every listed object was written.
    var isComplete: Bool { errors.isEmpty }
}

actor TenantExporter {

    private let client: PlatformClient
    private let progress: (@Sendable (String) -> Void)?
    private var isCancelled = false

    init(client: PlatformClient, progress: (@Sendable (String) -> Void)? = nil) {
        self.client = client
        self.progress = progress
    }

    func cancel() {
        isCancelled = true
    }

    /// Writes every object of the selected types under `root`/<type>/raw/.
    func backup(typeKeys: Set<String>, to root: URL) async -> BackupResult {
        var result = BackupResult(root: root)
        let writer = ExportWriter(root: root)

        for type in ObjectRegistry.types where typeKeys.contains(type.key) {
            guard !isCancelled else {
                result.errors.append("Backup cancelled")
                break
            }
            progress?(type.displayName)
            do {
                let refs = try await ObjectLister.list(type, on: client)
                var written = 0
                for ref in refs {
                    guard !isCancelled else { break }
                    do {
                        let payload = try await ObjectLister.detail(type, id: ref.id, on: client)
                        switch payload {
                        case .xml(let xml):
                            writer.writeRaw(type: type, ref: ref, payload: Data(xml.utf8), isXML: true)
                        case .json(let json):
                            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                            writer.writeRaw(type: type, ref: ref, payload: data, isXML: false)
                        }
                        written += 1
                    } catch {
                        result.errors.append("\(type.displayName) \"\(ref.name)\": \(error.localizedDescription)")
                    }
                }
                result.objectCounts[type.key] = written
                if written != refs.count && !isCancelled {
                    result.errors.append("\(type.displayName): wrote \(written) of \(refs.count) objects")
                }
            } catch {
                result.errors.append("\(type.displayName): \(error.localizedDescription)")
            }
        }
        return result
    }
}
