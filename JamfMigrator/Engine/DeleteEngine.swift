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
            if type.requiresGateway && !client.supportsPlatformEndpoints {
                report.add(type: type, ref: ObjectRef(id: "-", name: "(all objects)"),
                           status: .blocked(reason: "\(type.displayName) require the Jamf Platform API gateway"))
                continue
            }
            if case .singleton = type.listShape {
                // settings singletons can't be deleted
                continue
            }
            let excluded = excluding[type.key] ?? []
            do {
                let refs = try await ObjectLister.list(type, on: client)
                    .filter { !excluded.contains($0.id) }
                var completed = 0
                for ref in refs {
                    guard !isCancelled else { break }
                    completed += 1
                    if Self.protectedNames[type.key]?.contains(ref.name) == true {
                        report.add(type: type, ref: ref, status: .blocked(reason: "Built-in object"))
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
                report.add(type: type, ref: ObjectRef(id: "-", name: "(all objects)"),
                           status: .failed(reason: error.localizedDescription))
            }
        }

        // objects held by a dependency get repeated passes until a full pass
        // deletes nothing more
        var queue = retryQueue
        while !queue.isEmpty && !isCancelled {
            var held = [(ObjectType, ObjectRef)]()
            var completed = 0
            for (type, ref) in queue {
                guard !isCancelled else { break }
                completed += 1
                let status = await deleteObject(type, ref: ref)
                if case .failed(let reason) = status, isDependencyFailure(reason) {
                    held.append((type, ref))
                    continue
                }
                await journal.record(type: type.key, objectId: ref.id, status: status)
                report.add(type: type, ref: ref, status: status)
                progress?(ProgressEvent(type: type.key, objectName: ref.name,
                                        completed: completed, total: queue.count, status: status))
            }
            if held.count == queue.count {
                // no progress: record what is still referenced and stop
                for (type, ref) in held {
                    let status = ObjectStatus.failed(reason: "Still referenced by another object after every retry")
                    await journal.record(type: type.key, objectId: ref.id, status: status)
                    report.add(type: type, ref: ref, status: status)
                }
                break
            }
            queue = held
        }
        return report
    }

    private func deleteObject(_ type: ObjectType, ref: ObjectRef) async -> ObjectStatus {
        do {
            _ = try await client.send(.delete, type.api.detailPath(id: ref.id))
            return .deleted
        } catch let error as GatewayError {
            // a Classic DELETE sometimes reports a misleading 400 after doing
            // the work, and a Blueprint DELETE a misleading 500; a follow-up
            // GET decides
            if error.status == 400 || error.status == 500 {
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
