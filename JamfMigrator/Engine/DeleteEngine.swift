//
//  DeleteEngine.swift
//  JamfMigrator
//
//  Deletes the selected object types from one tenant, in exact reverse
//  migration order. Objects the gateway refuses because something still
//  references them (422/409/406) are retried after everything else.
//

import Foundation
import JTKit

actor DeleteEngine {

    let client: JamfPlatform.Client
    private let journal: JournalStore
    private let progress: (@Sendable (ProgressEvent) -> Void)?
    private var isCancelled = false

    /// Built-in objects that can't or shouldn't be deleted.
    static let protectedNames: [String: Set<String>] = [
        "smartcomputergroups": ["All Managed Clients", "All Managed Servers"],
        "smartmobiledevicegroups": ["All Managed iPads", "All Managed iPhones", "All Managed iPod touches"],
    ]

    init(client: JamfPlatform.Client,
         journal: JournalStore,
         progress: (@Sendable (ProgressEvent) -> Void)? = nil) {
        self.client = client
        self.journal = journal
        self.progress = progress
    }

    func cancel() {
        isCancelled = true
    }

    /// Deletes exactly the ticked Delete rows of Preview's plan, in deletion
    /// order. Right before each delete the object must still be on the
    /// tenant with the same id and name; otherwise the run stops before
    /// deleting it and the report says why. An object added after Preview is
    /// never deleted.
    ///
    /// - Parameter including: the ticked object ids per registry key.
    func run(_ plan: MigrationPlan, including: [String: Set<String>]) async -> RunReport {
        var report = RunReport()
        stopReason = nil
        var retryQueue = [(ObjectType, ObjectRef)]()

        for type in ObjectRegistry.deletionOrder where plan.typeKeys.contains(type.key) {
            guard !isCancelled, stopReason == nil else { break }
            if type.requiresGateway && !client.supportsPlatformEndpoints {
                report.add(type: type, ref: ObjectRef(id: "-", name: "(all objects)"),
                           status: .blocked(reason: "\(type.displayName) require the Jamf Platform API gateway"))
                continue
            }
            if case .singleton = type.listShape {
                // settings singletons can't be deleted
                continue
            }
            let planned = plan.entries(for: type.key).filter {
                $0.change == .delete && including[type.key]?.contains($0.objectId) == true
            }
            guard !planned.isEmpty else { continue }
            do {
                // the tenant as it is now, to check each object against Preview
                let current = Dictionary(try await ObjectLister.list(type, on: client).map { ($0.id, $0.name) },
                                         uniquingKeysWith: { first, _ in first })
                let refs = planned.map { ObjectRef(id: $0.objectId, name: $0.name) }
                var completed = 0
                for ref in refs {
                    guard !isCancelled, stopReason == nil else { break }
                    completed += 1
                    if Self.protectedNames[type.key]?.contains(ref.name) == true {
                        report.add(type: type, ref: ref, status: .blocked(reason: "Built-in object"))
                        continue
                    }
                    if let previous = await journal.status(type: type.key, objectId: ref.id), previous.isDone {
                        report.add(type: type, ref: ref, status: previous)
                        continue
                    }
                    guard current[ref.id] == ref.name else {
                        let change = current[ref.id] == nil ? "no longer on the tenant" : "renamed since Preview"
                        stopReason = "\(type.displayName) › \"\(ref.name)\": \(change). The run stopped before deleting it; Preview again."
                        AppActivity.record(stopReason ?? "", category: "Delete", level: .warning)
                        break
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
        while !queue.isEmpty && !isCancelled && stopReason == nil {
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
        report.stopReason = stopReason
        return report
    }

    /// Why the run stopped because an object changed since Preview; nil otherwise.
    private var stopReason: String?

    private func deleteObject(_ type: ObjectType, ref: ObjectRef) async -> ObjectStatus {
        do {
            _ = try await client.send(.delete, type.api.detailPath(id: ref.id), privileges: type.access.delete)
            return .deleted
        } catch let error as JamfPlatformError {
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
                                      accept: type.api.isClassic ? "application/xml" : "application/json",
                                      privileges: type.access.read)
            return false
        } catch let error as JamfPlatformError {
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
