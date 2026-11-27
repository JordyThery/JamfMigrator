//
//  TenantExporter.swift
//  JamfMigrator
//
//  Exports a whole tenant to a folder — the required backup before a wipe.
//  The export is verified: every listed object must land on disk.
//

import Foundation
import JTKit

struct BackupResult: Sendable, Equatable {
    var objectCounts: [String: Int] = [:]
    var errors: [String] = []
    var root: URL
    /// The types it covers.
    var typeKeys: Set<String> = []
    /// The Preview it was made for (Wipe's backup gate); nil without one.
    var planId: UUID? = nil

    var totalObjects: Int { objectCounts.values.reduce(0, +) }
    /// A backup only counts when every listed object was written.
    var isComplete: Bool { errors.isEmpty }

    /// Wipe's backup gate: complete, made for this Preview, and covering
    /// every type the plan deletes from.
    func covers(_ plan: MigrationPlan) -> Bool {
        isComplete && planId == plan.id && plan.typeKeys.isSubset(of: typeKeys)
    }
}

actor TenantExporter {

    private let client: JamfPlatform.Client
    private let progress: (@Sendable (String) -> Void)?
    private var isCancelled = false

    init(client: JamfPlatform.Client, progress: (@Sendable (String) -> Void)? = nil) {
        self.client = client
        self.progress = progress
    }

    func cancel() {
        isCancelled = true
    }

    /// Writes every object of the selected types under `root`/<type>/raw/.
    func backup(typeKeys: Set<String>, to root: URL) async -> BackupResult {
        var result = BackupResult(root: root, typeKeys: typeKeys)
        let writer = ExportWriter(root: root)

        for type in ObjectRegistry.types where typeKeys.contains(type.key) {
            guard !isCancelled else {
                result.errors.append("Backup canceled.")
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
                        let wrote: Bool
                        switch payload {
                        // license serial numbers never reach the backup
                        case .xml(let xml):
                            wrote = writer.writeRaw(type: type, ref: ref, payload: Data(xml.utf8), isXML: true,
                                                    hiding: type.secretValues(in: xml))
                        case .json(let json):
                            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                            wrote = writer.writeRaw(type: type, ref: ref, payload: data, isXML: false,
                                                    hiding: type.secretValues(in: String(decoding: data, as: UTF8.self)))
                        }
                        if wrote {
                            written += 1
                        } else {
                            result.errors.append("\(type.displayName) “\(ref.name)”: the file couldn’t be written")
                        }
                    } catch {
                        result.errors.append("\(type.displayName) “\(ref.name)”: \(error.localizedDescription)")
                    }
                }
                result.objectCounts[type.key] = written
                if written != refs.count && !isCancelled {
                    result.errors.append("\(type.displayName): wrote \(written) of \(Plural.count(refs.count, "object"))")
                }
            } catch {
                result.errors.append("\(type.displayName): \(error.localizedDescription)")
            }
        }
        return result
    }
}
