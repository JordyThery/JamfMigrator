//
//  MigrationEngine.swift
//  JamfMigrator
//
//  Copies the selected object types from the source tenant to the
//  destination: list → fetch detail → transform → match by name → create or
//  update. Every outcome lands in the RunJournal, so a run can resume.
//

import Foundation
import JTKit

actor MigrationEngine {

    let source: JamfPlatform.Client
    let dest: JamfPlatform.Client
    private let journal: JournalStore
    private let export: ExportWriter?
    let secrets: [String: String]
    let mappings: TenantMappings
    private let progress: (@Sendable (ProgressEvent) -> Void)?
    private let icons: IconMigrator

    private var isCancelled = false
    /// Destination ids by name (and names by id, and names used more than
    /// once) and source names by id, per registry key.
    /// Filled per type as the run proceeds and reused by later transforms.
    private var destIdsByName = [String: [String: String]]()
    private var destNamesById = [String: [String: String]]()
    private var destDuplicateNames = [String: Set<String>]()
    private var sourceNamesById = [String: [String: String]]()
    /// Dependency lists a type may do without that couldn't be read, as in Preview.
    private var unreadableLists = [String: String]()
    /// Stops the run before writing `ref`, because it changed since Preview.
    private func stop(_ type: ObjectType, _ ref: ObjectRef, _ change: String) {
        stopReason = "\(type.displayName) › “\(ref.name)”: \(change). The run stopped before writing it. Preview again before running."
        AppActivity.record(stopReason ?? "", category: "Migration", level: .warning)
    }

    /// Destination patch source ids by name, loaded on the first patch title create.
    private var patchSourceIds = [String: String]()

    init(source: JamfPlatform.Client,
         dest: JamfPlatform.Client,
         journal: JournalStore,
         export: ExportWriter? = nil,
         secrets: [String: String] = [:],
         mappings: TenantMappings = TenantMappings(),
         progress: (@Sendable (ProgressEvent) -> Void)? = nil) {
        self.source = source
        self.dest = dest
        self.journal = journal
        self.export = export
        self.secrets = secrets
        self.mappings = mappings
        self.progress = progress
        self.icons = IconMigrator(source: source, dest: dest)
    }

    /// Stop: the object being written finishes, then the run stops. A
    /// watch after a write (a Blueprint deploy, a benchmark sync, a PreStage's
    /// profile UUID) ends at once; the write itself is never interrupted.
    func cancel() {
        isCancelled = true
        cancelWatch?()
    }

    /// Ends the watch after a write that is going on now.
    private var cancelWatch: (@Sendable () -> Void)?

    /// Runs a watch after a write so that Stop can end it at once.
    /// - Throws: `CancellationError` when Stop ended it, or the watch's own error.
    private func watch<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task { try await body() }
        cancelWatch = { task.cancel() }
        defer { cancelWatch = nil }
        if isCancelled { task.cancel() }
        return try await task.value
    }

    /// The warning of a watch Stop ended.
    static let watchStopped = "Stopped before Jamf confirmed it; check it on the destination."

    /// The reason of an object whose request was waiting to be tried again
    /// when Stop ended the wait.
    static let stoppedDuringWait = "Stopped while waiting to try again: it may not have been written. Preview again to check."

    /// Carries out exactly the plan Preview showed: the ticked Create,
    /// Update and Replace rows, in step order; Unchanged and Blocked rows are
    /// never touched, and nothing that wasn't in the plan is.
    ///
    /// Right before each write the object is compared again exactly as
    /// Preview compared it. If the source object, the destination object or
    /// the destination's use of the name changed since Preview, the run stops
    /// before writing it and the report says why (`stopReason`).
    ///
    /// - Parameter including: the ticked source object ids per registry key.
    func run(_ plan: MigrationPlan, including: [String: Set<String>]) async -> RunReport {
        var report = RunReport()
        stopReason = nil
        // a journal of another plan never makes this run skip a write
        await journal.begin(planId: plan.id)
        // the names Preview treated as "will exist" when it compared each object:
        // the planned creates before it, in plan order
        var precedingCreates = [String: Set<String>]()

        for type in ObjectRegistry.types where plan.typeKeys.contains(type.key) {
            guard !isCancelled, stopReason == nil else { break }
            let entries = plan.entries(for: type.key)
            let ticked = entries.filter { $0.change.isRunnable && including[type.key]?.contains($0.objectId) == true }
            defer {
                for entry in entries { if case .create = entry.change { precedingCreates[type.key, default: []].insert(entry.name) } }
            }
            guard !ticked.isEmpty else { continue }
            do {
                try await runType(type, entries: entries, ticked: Set(ticked.map(\.objectId)), plan: plan,
                                  precedingCreates: precedingCreates, report: &report)
            } catch is CancellationError where isCancelled {
                // Stop ended a wait before a retry while the type's lists were read
                break
            } catch {
                AppActivity.record("\(type.displayName) failed: \(error.localizedDescription)",
                                   category: "Migration", level: .error)
                report.add(type: type, ref: ObjectRef(id: "-", name: "(all objects)"),
                           status: .failed(reason: error.localizedDescription))
            }
        }
        report.stopReason = stopReason
        return report
    }

    /// Why the run stopped before the end because something changed since
    /// Preview; nil otherwise.
    private var stopReason: String?

    private func runType(_ type: ObjectType, entries: [ObjectPlan], ticked: Set<String>, plan: MigrationPlan,
                         precedingCreates: [String: Set<String>], report: inout RunReport) async throws {
        // lookups the transform needs, even when those types aren't being migrated
        for dependency in type.dependencies + ["sites"] {
            do {
                try await loadLookups(for: dependency, destination: true, source: true)
                unreadableLists[dependency] = nil
            } catch where MigrationPlanner.mayDoWithout(dependency, for: type) && !(error is CancellationError) {
                unreadableLists[dependency] = error.localizedDescription
            }
        }
        if ["blueprints", "compliancebenchmarks"].contains(type.key) {
            try await loadPlatformGroupLookups()
        }
        // the destination as it is now, also for names Preview planned
        try await loadLookups(for: type.key, destination: true, source: true, refresh: true)

        var creates = precedingCreates
        var completed = 0
        for entry in entries {
            defer { if case .create = entry.change { creates[type.key, default: []].insert(entry.name) } }
            guard ticked.contains(entry.objectId) else { continue }
            guard !isCancelled, stopReason == nil else { return }
            completed += 1
            let ref = ObjectRef(id: entry.objectId, name: entry.name)

            // resume: skip objects an interrupted run already finished
            if let previous = await journal.status(type: type.key, objectId: ref.id), previous.isDone {
                report.add(type: type, ref: ref, status: previous)
                progress?(ProgressEvent(type: type.key, objectName: ref.name,
                                        completed: completed, total: ticked.count, status: previous))
                continue
            }

            let (status, warnings) = await runObject(type, entry: entry, plan: plan, plannedCreates: creates)
            if stopReason != nil {
                // nothing was written for this object; it stays as it is
                return
            }
            await journal.record(type: type.key, objectId: ref.id, status: status)
            if let destId = status.destId {
                destIdsByName[type.key, default: [:]][ref.name] = destId
                destNamesById[type.key, default: [:]][destId] = ref.name
            }
            report.add(type: type, ref: ref, status: status, warnings: warnings)
            progress?(ProgressEvent(type: type.key, objectName: ref.name,
                                    completed: completed, total: ticked.count, status: status))
        }
    }

    /// What the object's check before writing found that differs from
    /// Preview, in words; nil when it is exactly what Preview saw.
    static func changeSincePreview(planned: ObjectPlan, now: ObjectPlan) -> String? {
        switch (planned.change, now.change) {
        case (.create, .create):
            break
        case (.create, .update), (.create, .replace), (.create, .unchanged):
            return "an object with this name now exists on the destination"
        case (.update(let was), .update(let id)), (.replace(let was), .replace(let id)):
            if was != id { return "the destination object with this name is now another one" }
        case (.update, .unchanged), (.replace, .unchanged):
            return "changed on the destination since Preview"
        case (.update, .create), (.replace, .create):
            return "no longer on the destination"
        case (_, .blocked(let reason)):
            return "can no longer be migrated: \(reason)"
        default:
            return "is no longer what Preview showed"
        }
        if planned.sourceDigest != now.sourceDigest { return "changed on the source since Preview" }
        if planned.destDigest != now.destDigest { return "changed on the destination since Preview" }
        return nil
    }

    private func runObject(_ type: ObjectType, entry: ObjectPlan, plan: MigrationPlan,
                           plannedCreates: [String: Set<String>]) async -> (ObjectStatus, [String]) {
        let ref = ObjectRef(id: entry.objectId, name: entry.name)
        // an object this one needs from the same run must exist now: if its
        // create failed, this row isn't written with a missing reference
        // (it fails, so Resume Run retries it once the other is there)
        let missing = entry.plannedDependencies.filter { destIdsByName[$0.typeKey]?[$0.name] == nil }
        if !missing.isEmpty {
            let names = missing.map { "\(ObjectRegistry.type($0.typeKey)?.displayName ?? $0.typeKey) › “\($0.name)”" }
            return (.failed(reason: "Not written: it needs \(names.joined(separator: ", ")), which this run didn’t create"), [])
        }
        // values the server may repeat in an error, kept out of the reason
        var secretValues = [String]()
        do {
            let payload = try await ObjectLister.detail(type, id: ref.id, on: source)
            if case .xml(let xml) = payload {
                secretValues = type.secretValues(in: xml)
            }

            // the check before writing: the same comparison as Preview, with
            // what this run created counted as "will exist", as Preview did
            if destDuplicateNames[type.key]?.contains(ref.name) == true {
                stop(type, ref, "more than one destination object is now named “\(ref.name)”")
                return (.failed(reason: "Not written"), [])
            }
            let existingDestId = destIdsByName[type.key]?[ref.name]
            var destPayload: ObjectPayload? = nil
            if let existingDestId {
                destPayload = try await ObjectLister.detail(type, id: existingDestId, on: dest)
            }
            // Preview saw the objects it planned to create as "will exist";
            // so does this check, whether they were created by this run, by
            // an interrupted earlier run of the same plan, or not yet
            var asPreviewSaw = destIdsByName
            for (typeKey, names) in plannedCreates {
                for name in names { asPreviewSaw[typeKey]?[name] = nil }
            }
            for name in MigrationPlanner.plannedDeviceGroups(plannedCreates) {
                asPreviewSaw[platformGroupsKey]?[name] = nil
            }
            let now = MigrationPlanner.compare(
                type, ref: ref, sourcePayload: payload, destId: existingDestId, destPayload: destPayload,
                inputs: MigrationPlanner.ComparisonInputs(destIdsByName: asPreviewSaw, destNamesById: destNamesById,
                                                          sourceNamesById: sourceNamesById, plannedCreates: plannedCreates,
                                                          secrets: secrets, included: plan.typeKeys, mappings: mappings,
                                                          unreadable: unreadableLists))
            if let change = Self.changeSincePreview(planned: entry, now: now) {
                stop(type, ref, change)
                return (.failed(reason: "Not written"), [])
            }

            var context = TransformContext()
            context.destIdsByName = destIdsByName
            context.sourceNamesById = sourceNamesById
            context.secrets = secrets
            context.includedTypes = plan.typeKeys
            context.mappings = mappings
            context.unreadableLists = unreadableLists

            if let existingDestId {
                context.action = .update(destId: existingDestId)
                // profile updates keep the destination's payload UUID
                if ["osxconfigurationprofiles", "mobiledeviceconfigurationprofiles"].contains(type.key),
                   case .xml(let xml)? = destPayload {
                    context.destProfileUUID = ClassicXML.value(of: "uuid", in: ClassicXML.value(of: "general", in: xml))
                }
                // PreStage PUTs must echo the destination's versionLocks
                if ["computerprestages", "mobiledeviceprestages"].contains(type.key),
                   case .json(let destJson)? = destPayload {
                    context.destVersionLocks = MigrationPlanner.versionLocks(in: destJson)
                    context.destPreStageIds = MigrationPlanner.nestedIds(in: destJson)
                }
                if type.key == "sso", case .json(let destJson)? = destPayload {
                    context.destEnabledFlags = ProTransformer.enabledFlags(in: destJson)
                }
            }

            // what an export must never hold: Settings › Secrets values and
            // license serial numbers (JTKit's redaction takes the passwords)
            let hidden = secretValues + Array(secrets.values)
            let outcome: TransformOutcome
            switch payload {
            case .xml(let xml):
                export?.writeRaw(type: type, ref: ref, payload: Data(xml.utf8), isXML: true, hiding: hidden)
                outcome = ClassicTransformer.transform(type: type, xml: xml, context: context)
            case .json(let json):
                if let raw = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                    export?.writeRaw(type: type, ref: ref, payload: raw, isXML: false, hiding: hidden)
                }
                outcome = ProTransformer.transform(type: type, json: json, context: context)
            }

            switch outcome {
            case .blocked(let reason):
                return (.blocked(reason: reason), [])
            case .write(let object):
                export?.writeTrimmed(type: type, ref: ref, payload: object.body, isXML: type.api.isClassic, hiding: hidden)
                var warnings = object.warnings

                // benchmarks have no update endpoint: delete, then recreate.
                // the DELETE can report a misleading status after doing the
                // work (see DeleteEngine); the destination's list decides
                var action = context.action
                var deletedForReplace = false
                if type.key == "compliancebenchmarks", case .update(let destId) = action {
                    do {
                        _ = try await dest.send(.delete, type.api.detailPath(id: destId))
                    } catch let error as JamfPlatform.APIError where error.status != nil {
                        guard await benchmarkIsGone(type, id: destId) else { throw error }
                    }
                    deletedForReplace = true
                    action = .create
                }

                let destId: String
                do {
                    destId = try await write(object, type: type, action: action)
                } catch is CancellationError {
                    // the benchmark's delete for the Replace already happened
                    let reason = deletedForReplace
                        ? "Deleted on the destination, but the new copy wasn’t created: Stop ended the wait before it was tried again. Preview again to create it."
                        : Self.stoppedDuringWait
                    return (.failed(reason: reason), warnings)
                } catch {
                    // a planned write that didn't happen is a failure, never
                    // "unchanged"; and the reason says what was done before it
                    var reason = Self.blankingOut(hidden, in: error.localizedDescription)
                    if type.key == "compliancebenchmarks", (error as? JamfPlatform.APIError)?.status == 409 {
                        reason = "A benchmark with this title already exists on the destination (\(reason))."
                    }
                    if deletedForReplace {
                        reason = "Deleted on the destination, but the new copy couldn’t be created: \(reason) Preview again to create it."
                    }
                    return (.failed(reason: reason), warnings)
                }
                if let icon = object.icon {
                    await copyIcon(icon, type: type, destObjectId: destId, warnings: &warnings)
                }
                try await runPostActions(type: type, destId: destId, sourcePayload: payload, warnings: &warnings)
                if case .update = context.action {
                    return (.updated(destId: destId), warnings)
                }
                return (.created(destId: destId), warnings)
            }
        } catch is CancellationError {
            return (.failed(reason: Self.stoppedDuringWait), [])
        } catch {
            return (.failed(reason: Self.blankingOut(secretValues + Array(secrets.values), in: error.localizedDescription)), [])
        }
    }

    /// `text` with each of `values` replaced by JTKit's placeholder, so a
    /// reason keeps what went wrong ("Duplicate name") but not the secret.
    static func blankingOut(_ values: [String], in text: String) -> String {
        values.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
            .reduce(text) { $0.replacingOccurrences(of: $1, with: Redaction.placeholder) }
    }

    /// Creates or updates the object and returns its destination id.
    private func write(_ object: TransformedObject, type: ObjectType, action: TransformAction) async throws -> String {
        let response: HTTPResponse
        // a merge-patch request still answers in plain JSON
        let accept = object.contentType == "application/merge-patch+json" ? "application/json" : object.contentType
        if case .create = action, let subscription = object.patchSubscription {
            let destId = try await subscribe(to: subscription, privileges: type.access.create)
            do {
                _ = try await dest.send(type.updateMethod, type.updatePath(destId: destId),
                                        body: object.body,
                                        contentType: object.contentType,
                                        accept: accept,
                                        privileges: type.access.privileges(for: type.updateMethod))
            } catch {
                throw SubscribedButNotWritten(reason: error.localizedDescription)
            }
            return destId
        }
        switch action {
        case .create:
            let path = object.createPathOverride ?? type.api.createPath
            response = try await dest.send(.post, path, body: object.body,
                                           contentType: object.contentType,
                                           accept: accept,
                                           privileges: type.access.create,
                                           withholdsContents: type.secretTagPrefix != nil)
        case .update(let destId):
            response = try await dest.send(type.updateMethod, type.updatePath(destId: destId),
                                           body: object.body,
                                           contentType: object.contentType,
                                           accept: accept,
                                           privileges: type.access.privileges(for: type.updateMethod),
                                           withholdsContents: type.secretTagPrefix != nil)
            return destId
        }

        if case .singleton = type.listShape {
            return "singleton"
        }
        // the created id: <id>n</id> on Classic, "id" in the JSON on Pro
        if type.api.isClassic {
            let id = ClassicXML.value(of: "id", in: String(decoding: response.data, as: UTF8.self))
            guard !id.isEmpty else { throw JamfPlatform.APIError(.invalidResponse("The new object’s ID is missing from the answer.")) }
            return id
        }
        let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        // benchmark create responses name the id "benchmarkId"; everything
        // else uses "id"
        guard let id = json?["id"] ?? json?["benchmarkId"] else {
            throw JamfPlatform.APIError(.invalidResponse("The new object’s ID is missing from the answer."))
        }
        return "\(id)"
    }

    /// Subscribes the destination to a patch title through the Classic API,
    /// which creates its configuration, and returns the new id. The Pro
    /// create needs a softwareTitleId, which only exists once the destination
    /// is subscribed.
    private func subscribe(to subscription: PatchSubscription, privileges: [JamfPro.Privilege]) async throws -> String {
        let sourceId = try await patchSourceId(named: subscription.sourceName)
        let xml = "<patch_software_title><name>\(ClassicXML.escape(subscription.displayName))</name>"
            + "<name_id>\(ClassicXML.escape(subscription.nameId))</name_id>"
            + "<source_id>\(sourceId)</source_id></patch_software_title>"
        let response = try await dest.send(.post, "proclassic/patchsoftwaretitles/id/0", body: Data(xml.utf8),
                                           contentType: "application/xml", accept: "application/xml",
                                           privileges: privileges)
        let id = ClassicXML.value(of: "id", in: String(decoding: response.data, as: UTF8.self))
        guard !id.isEmpty else { throw JamfPlatform.APIError(.invalidResponse("The new object’s ID is missing from the answer.")) }
        return id
    }

    /// The destination's id for a patch source, internal (Jamf) or external,
    /// matched by name.
    private func patchSourceId(named name: String) async throws -> String {
        if let cached = patchSourceIds[name] { return cached }
        let sources: [(path: String, container: String, privilege: JamfPro.Privilege)] = [
            ("proclassic/patchinternalsources", "patch_internal_sources", .readPatchInternalSource),
            ("proclassic/patchexternalsources", "patch_external_sources", .readPatchExternalSource),
        ]
        for (path, container, privilege) in sources {
            let response = try await dest.send(.get, path, accept: "application/json", privileges: [privilege])
            let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] ?? [:]
            for entry in root[container] as? [[String: Any]] ?? [] {
                if let id = entry["id"], let sourceName = entry["name"] as? String {
                    patchSourceIds[sourceName] = "\(id)"
                }
            }
        }
        guard let id = patchSourceIds[name] else {
            throw MissingPatchSource(name: name)
        }
        return id
    }

    /// A patch title create subscribed the destination, but writing the
    /// title's settings failed: the subscription stays on the destination.
    struct SubscribedButNotWritten: LocalizedError {
        let reason: String
        var errorDescription: String? {
            "The destination is now subscribed to this title, but its settings couldn’t be written: \(reason) Preview again; the title then shows as Update."
        }
    }

    struct MissingPatchSource: LocalizedError {
        let name: String
        var errorDescription: String? {
            "The patch source “\(name)” doesn’t exist on the destination; add it there first."
        }
    }

    /// Type-specific follow-ups after a successful write.
    private func runPostActions(type: ObjectType, destId: String, sourcePayload: ObjectPayload,
                                warnings: inout [String]) async throws {
        switch type.key {
        case "computerprestages", "mobiledeviceprestages":
            // further changes need the profileUuid, which lags the write; a
            // 404 just after the create means the PreStage isn't there yet
            let dest = dest
            let outcome = try? await watch {
                try await Self.poller(timeLimit: .seconds(30)).poll(
                    check: { () -> String? in
                        let detail = try await ObjectLister.detail(type, id: destId, on: dest)
                        guard case .json(let json) = detail,
                              let uuid = json["profileUuid"] as? String, !uuid.isEmpty else { return nil }
                        return uuid
                    },
                    isDone: { $0 != nil },
                    isNotReadyYet: { ($0 as? JamfPlatform.APIError)?.status == 404 })
            }
            if outcome == nil && isCancelled {
                warnings.append("The PreStage’s profile UUID: " + Self.watchStopped)
            } else if outcome?.isFinished != true {
                warnings.append("The PreStage’s profile UUID didn’t appear in time; check the PreStage on the destination.")
            }

        case "blueprints":
            // mirror the source's deploy state; a repeat deploy is harmless
            guard case .json(let sourceJson) = sourcePayload else { return }
            switch Self.blueprintDeployment(sourceJson) {
            case .leaveUndeployed:
                return
            case .deployWithWarning:
                warnings.append("The Blueprint is out of date on the source; it was deployed on the destination with its latest settings.")
            case .deploy:
                break
            }
            // JTKit's deploy-and-watch: it tells the new deployment from an
            // earlier one by its start time and waits until it succeeds or fails
            let blueprints = JamfPlatform.Blueprints(client: dest)
            let previousStart: String?
            do {
                previousStart = try await blueprints.startDeployment(id: destId)
            } catch {
                warnings.append("The Blueprint was written but couldn’t be deployed: \(error.localizedDescription)")
                return
            }
            let outcome = try? await watch {
                try await blueprints.watchDeployment(id: destId, previousStart: previousStart,
                                                     poller: Self.poller(timeLimit: .seconds(60)))
            }
            if outcome == nil && isCancelled {
                warnings.append("The Blueprint’s deployment was started. " + Self.watchStopped)
                return
            }
            switch outcome {
            case .finished(let status)? where status.didSucceed:
                break
            case .finished?:
                warnings.append("The Blueprint was written but its deployment failed on the destination; check it there.")
            default:
                warnings.append("The Blueprint was written but its deployment didn’t confirm in time; check it on the destination.")
            }

        case "compliancebenchmarks":
            // the benchmark syncs in the background; report a sync that fails.
            // syncState only appears on list entries, not the detail
            let dest = dest
            let outcome = try? await watch {
                try await Self.poller(timeLimit: .seconds(60)).poll(
                    check: { () -> Bool? in
                        let response = try await dest.send(.get, type.api.listPath)
                        let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] ?? [:]
                        let entries = root["benchmarks"] as? [[String: Any]] ?? []
                        guard let entry = entries.first(where: { "\($0["id"] ?? "")" == destId }) else { return nil }
                        let state = "\(entry["syncState"] ?? "")"
                        if state.localizedCaseInsensitiveContains("FAILED") { return false }
                        return state.localizedCaseInsensitiveContains("SYNCED") ? true : nil
                    },
                    isDone: { $0 != nil })
            }
            if outcome == nil && isCancelled {
                warnings.append("The benchmark’s sync: " + Self.watchStopped)
                return
            }
            let synced = outcome?.isFinished == true ? outcome?.value ?? nil : nil
            if synced == false {
                warnings.append("The benchmark reports syncState FAILED on the destination.")
            } else if synced == nil {
                warnings.append("The benchmark sync didn’t confirm in time; check its syncState on the destination.")
            }

        default:
            break
        }
    }

    /// What a Blueprint's run does after the write, from the source's
    /// deploy state (JTKit's `DeploymentState`): deployed → deploy; out of
    /// date → deploy with a warning; not deployed or anything else → leave
    /// it undeployed.
    enum BlueprintDeployment: Equatable {
        case deploy
        case deployWithWarning
        case leaveUndeployed
    }

    static func blueprintDeployment(_ sourceJson: [String: Any]) -> BlueprintDeployment {
        // deploymentState is an object: {"state": "DEPLOYED", "lastDeployment": …}
        let raw = (sourceJson["deploymentState"] as? [String: Any])?["state"] as? String
            ?? sourceJson["deploymentState"] as? String
        guard let raw else { return .leaveUndeployed }
        let state = JamfPlatform.DeploymentState(state: JamfPlatform.BlueprintState(rawValue: raw)).state
        switch state {
        case .deployed: return .deploy
        case .outOfDate: return .deployWithWarning
        case .notDeployed, .other: return .leaveUndeployed
        }
    }

    /// JTKit's wait for a job after a write (from 2 s, growing to 10 s), with
    /// the app's own time limit.
    private static func poller(timeLimit: Duration) -> JamfPlatform.Poller {
        JamfPlatform.Poller(policy: JamfPlatform.PollingPolicy(timeLimit: timeLimit))
    }

    /// Whether the benchmark is no longer in the destination's list. A GET
    /// can't tell: benchmarks answer 403 for a deleted id, and also for a
    /// refused one. A list that can't be read counts as "still there".
    private func benchmarkIsGone(_ type: ObjectType, id: String) async -> Bool {
        guard let refs = try? await ObjectLister.list(type, on: dest) else { return false }
        return !refs.contains { $0.id == id }
    }

    /// Blueprints and Benchmarks reference device groups by platform UUID.
    private func loadPlatformGroupLookups() async throws {
        guard destIdsByName[platformGroupsKey] == nil else { return }
        let destGroups = try await MappingCatalog.platformGroups(on: dest)
        destIdsByName[platformGroupsKey] = Dictionary(destGroups.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        destNamesById[platformGroupsKey] = Dictionary(destGroups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let sourceGroups = try await MappingCatalog.platformGroups(on: source)
        sourceNamesById[platformGroupsKey] = Dictionary(sourceGroups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    private func copyIcon(_ icon: SelfServiceIcon, type: ObjectType, destObjectId: String, warnings: inout [String]) async {
        do {
            let destIconId = try await icons.copy(icon)
            try await icons.assign(iconId: destIconId, displayName: icon.displayName,
                                   to: type, destObjectId: destObjectId, on: dest)
        } catch {
            warnings.append("The Self Service icon “\(icon.name)” couldn’t be copied: \(error.localizedDescription)")
        }
    }

    /// Lists a type on the destination and/or source purely to fill the
    /// lookup maps used by transforms.
    private func loadLookups(for typeKey: String, destination: Bool, source wantSource: Bool,
                             refresh: Bool = false) async throws {
        guard let type = ObjectRegistry.type(typeKey) else { return }
        if destination && (refresh || destIdsByName[typeKey] == nil) {
            let refs = try await ObjectLister.list(type, on: dest)
            destIdsByName[typeKey] = Dictionary(refs.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
            destNamesById[typeKey] = Dictionary(refs.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            let counts = Dictionary(refs.map { ($0.name, 1) }, uniquingKeysWith: +)
            destDuplicateNames[typeKey] = Set(counts.filter { $0.value > 1 }.keys)
        }
        if wantSource && sourceNamesById[typeKey] == nil {
            let refs = try await ObjectLister.list(type, on: source)
            sourceNamesById[typeKey] = Dictionary(refs.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        }
    }
}

// MARK: - Only these objects (tests only)
//
// A test-only limit on Preview, Run and Verify: only the named source
// objects take part; everything else on the source is left out, also
// objects that appear later. The release check's live checks use it, so a
// live run never relies on unchecking everything else.
//
// Only test code can make one. Its only way in exists in Debug builds and
// refuses outside tests; the app's screens, settings and launch arguments
// never create or read one.

struct OnlyObjects: Sendable, Equatable {

    /// Source object ids per registry key.
    let idsByType: [String: Set<String>]

    private init(unchecked idsByType: [String: Set<String>]) {
        self.idsByType = idsByType
    }

    /// The registry keys that have objects in the limit.
    var typeKeys: Set<String> {
        Set(idsByType.filter { !$0.value.isEmpty }.keys)
    }

    func includes(typeKey: String, id: String) -> Bool {
        idsByType[typeKey]?.contains(id) == true
    }
}

#if DEBUG
extension OnlyObjects {
    /// For tests only: stops the app when it isn't running under tests.
    init(testing idsByType: [String: Set<String>]) {
        precondition(TestRun.isActive, "OnlyObjects is for tests only")
        self.init(unchecked: idsByType)
    }
}
#endif

extension Array where Element == ObjectRef {
    /// The objects `only` lets through, or all of them without a limit.
    func limited(to only: OnlyObjects?, typeKey: String) -> [ObjectRef] {
        guard let only else { return self }
        return filter { only.includes(typeKey: typeKey, id: $0.id) }
    }
}
