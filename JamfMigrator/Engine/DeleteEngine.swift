//
//  DeleteEngine.swift
//  JamfMigrator
//
//  Deletes the selected object types from one tenant, in exact reverse
//  migration order. Objects the gateway refuses because something still
//  references them (422/409/406) are retried after everything else.
//

import Foundation

actor DeleteEngine {

    private let client: PlatformClient
    private let journal: JournalStore
    private let progress: (@Sendable (ProgressEvent) -> Void)?
    private var isCancelled = false

    /// Built-in objects that can't or shouldn't be deleted.
    static let protectedNames: [String: Set<String>] = [
        "smartcomputergroups": ["All Managed Clients", "All Managed Servers"],
        "smartmobiledevicegroups": ["All Managed iPads", "All Managed iPhones", "All Managed iPod touches"],
    ]

    init(client: PlatformClient,
         journal: JournalStore,
         progress: (@Sendable (ProgressEvent) -> Void)? = nil) {
        self.client = client
        self.journal = journal
        self.progress = progress
    }

    func cancel() {
        isCancelled = true
    }

    func delete(typeKeys: Set<String>, excluding: [String: Set<String>] = [:]) async -> RunReport {
        var report = RunReport()
        var retryQueue = [(ObjectType, ObjectRef)]()

        for type in ObjectRegistry.deletionOrder where typeKeys.contains(type.key) {
            guard !isCancelled else { break }
            let excluded = excluding[type.key] ?? []
            do {
                let refs = try await ObjectLister.list(type, on: client)
                var completed = 0
                for ref in refs where !excluded.contains(ref.id) {
                    guard !isCancelled else { break }
                    completed += 1
                    if Self.protectedNames[type.key]?.contains(ref.name) == true {
                        continue
                    }
                    if let previous = await journal.status(type: type.key, objectId: ref.id), previous == .deleted {
                        report.add(type: type, ref: ref, status: .deleted)
                        continue
                    }
                    let status = await deleteObject(type, ref: ref)
                    if case .failed(let reason) = status, isDependencyFailure(reason) {
                        retryQueue.append((type, ref))
                        continue
                    }
                    await journal.record(type: type.key, objectId: ref.id, status: status)
                    report.add(type: type, ref: ref, status: status)
                    progress?(ProgressEvent(type: type.key, objectName: ref.name,
                                            completed: completed, total: refs.count, status: status))
                }
            } catch {
                report.add(type: type, ref: ObjectRef(id: "-", name: "(whole step)"),
                           status: .failed(reason: error.localizedDescription))
            }
        }

        // whatever was held by a dependency gets one more pass now that the
        // dependent steps have run
        for (type, ref) in retryQueue {
            guard !isCancelled else { break }
            let status = await deleteObject(type, ref: ref)
            await journal.record(type: type.key, objectId: ref.id, status: status)
            report.add(type: type, ref: ref, status: status)
            progress?(ProgressEvent(type: type.key, objectName: ref.name,
                                    completed: 1, total: 1, status: status))
        }
        return report
    }

    private func deleteObject(_ type: ObjectType, ref: ObjectRef) async -> ObjectStatus {
        do {
            _ = try await client.send(.delete, type.api.detailPath(id: ref.id))
            return .deleted
        } catch let error as GatewayError {
            // a Classic DELETE sometimes reports a misleading 400 after doing
            // the work; a follow-up GET decides
            if type.api.isClassic, error.status == 400 {
                if await objectIsGone(type, ref: ref) {
                    return .deleted
                }
            }
            return .failed(reason: error.localizedDescription)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    private func objectIsGone(_ type: ObjectType, ref: ObjectRef) async -> Bool {
        do {
            _ = try await client.send(.get, type.api.detailPath(id: ref.id),
                                      accept: type.api.isClassic ? "application/xml" : "application/json")
            return false
        } catch let error as GatewayError {
            return error.status == 404
        } catch {
            return false
        }
    }

    private func isDependencyFailure(_ reason: String) -> Bool {
        reason.contains("HTTP 422") || reason.contains("HTTP 409") || reason.contains("HTTP 406")
            || reason.contains("HAS_DEPENDENCIES")
    }
}
