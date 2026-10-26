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

    private let source: JamfPlatform.Client
    private let dest: JamfPlatform.Client
    private let journal: JournalStore
    private let export: ExportWriter?
    private let secrets: [String: String]
    private let mappings: TenantMappings
    private let progress: (@Sendable (ProgressEvent) -> Void)?
    private let icons: IconMigrator

    private var isCancelled = false
    /// Destination ids by name and source names by id, per registry key.
    /// Filled per type as the run proceeds and reused by later transforms.
    private var destIdsByName = [String: [String: String]]()
    private var sourceNamesById = [String: [String: String]]()
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

    func cancel() {
        isCancelled = true
    }

    /// Migrates the selected types in registry order and returns the report.
    /// `excluding` holds per-type source object ids that were unchecked.
    func migrate(typeKeys: Set<String>, excluding: [String: Set<String>] = [:]) async -> RunReport {
        var report = RunReport()
        let types = ObjectRegistry.types.filter { typeKeys.contains($0.key) }

        for type in types {
            guard !isCancelled else { break }
            if type.requiresGateway && !(source.supportsPlatformEndpoints && dest.supportsPlatformEndpoints) {
                report.add(type: type, ref: ObjectRef(id: "-", name: "(all objects)"),
                           status: .blocked(reason: "\(type.displayName) require the Jamf Platform API gateway"))
                continue
            }
            do {
                try await migrateType(type, included: typeKeys,
                                      excluded: excluding[type.key] ?? [], report: &report)
            } catch {
                AppActivity.record("\(type.displayName) failed: \(error.localizedDescription)",
                                   category: "Migration", level: .error)
                report.add(type: type, ref: ObjectRef(id: "-", name: "(all objects)"),
                           status: .failed(reason: error.localizedDescription))
            }
        }
        return report
    }

    private func migrateType(_ type: ObjectType, included: Set<String>, excluded: Set<String>, report: inout RunReport) async throws {
        // lookups the transform needs, even when those types aren't being migrated
        for dependency in type.dependencies + ["sites"] {
            try await loadLookups(for: dependency, destination: true, source: true)
        }

        if ["blueprints", "compliancebenchmarks"].contains(type.key) {
            try await loadPlatformGroupLookups()
        }
        let sourceRefs = try await ObjectLister.list(type, on: source)
        sourceNamesById[type.key] = Dictionary(sourceRefs.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        try await loadLookups(for: type.key, destination: true, source: false)

        var completed = 0
        var seenNames = Set<String>()
        let includedRefs = sourceRefs.filter { !excluded.contains($0.id) }
        for ref in includedRefs {
            guard !isCancelled else { return }
            completed += 1

            // name matching can't tell same-named source objects apart; only
            // the first one migrates
            if !seenNames.insert(ref.name).inserted {
                let status = ObjectStatus.blocked(reason: "Duplicate name on the source; rename one of the two objects to migrate both")
                await journal.record(type: type.key, objectId: ref.id, status: status)
                report.add(type: type, ref: ref, status: status)
                progress?(ProgressEvent(type: type.key, objectName: ref.name,
                                        completed: completed, total: includedRefs.count, status: status))
                continue
            }

            // resume: skip objects an interrupted run already finished
            if let previous = await journal.status(type: type.key, objectId: ref.id), previous.isDone {
                report.add(type: type, ref: ref, status: previous)
                progress?(ProgressEvent(type: type.key, objectName: ref.name,
                                        completed: completed, total: includedRefs.count, status: previous))
                continue
            }

            let (status, warnings) = await migrateObject(type, ref: ref, included: included)
            await journal.record(type: type.key, objectId: ref.id, status: status)
            if let destId = status.destId {
                destIdsByName[type.key, default: [:]][ref.name] = destId
            }
            report.add(type: type, ref: ref, status: status, warnings: warnings)
            progress?(ProgressEvent(type: type.key, objectName: ref.name,
                                    completed: completed, total: includedRefs.count, status: status))
        }
    }

    private func migrateObject(_ type: ObjectType, ref: ObjectRef, included: Set<String>) async -> (ObjectStatus, [String]) {
        // values the server may repeat in an error, kept out of the reason
        var secretValues = [String]()
        do {
            let payload = try await ObjectLister.detail(type, id: ref.id, on: source)
            if case .xml(let xml) = payload {
                secretValues = type.secretValues(in: xml)
            }

            var context = TransformContext()
            context.destIdsByName = destIdsByName
            context.sourceNamesById = sourceNamesById
            context.secrets = secrets
            context.includedTypes = included
            context.mappings = mappings

            let existingDestId = destIdsByName[type.key]?[ref.name]
            if let existingDestId {
                context.action = .update(destId: existingDestId)
                // profile updates keep the destination's payload UUID
                if ["osxconfigurationprofiles", "mobiledeviceconfigurationprofiles"].contains(type.key) {
                    let destXml = try await ObjectLister.detail(type, id: existingDestId, on: dest)
                    if case .xml(let xml) = destXml {
                        context.destProfileUUID = ClassicXML.value(of: "uuid", in: ClassicXML.value(of: "general", in: xml))
                    }
                }
                // PreStage PUTs must echo the destination's versionLocks
                if ["computerprestages", "mobiledeviceprestages"].contains(type.key) {
                    let destDetail = try await ObjectLister.detail(type, id: existingDestId, on: dest)
                    if case .json(let destJson) = destDetail {
                        context.destVersionLocks = MigrationPlanner.versionLocks(in: destJson)
                        context.destPreStageIds = MigrationPlanner.nestedIds(in: destJson)
                    }
                }
            }

            let outcome: TransformOutcome
            switch payload {
            case .xml(let xml):
                export?.writeRaw(type: type, ref: ref, payload: Data(xml.utf8), isXML: true)
                outcome = ClassicTransformer.transform(type: type, xml: xml, context: context)
            case .json(let json):
                if let raw = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                    export?.writeRaw(type: type, ref: ref, payload: raw, isXML: false)
                }
                outcome = ProTransformer.transform(type: type, json: json, context: context)
            }

            switch outcome {
            case .blocked(let reason):
                return (.blocked(reason: reason), [])
            case .write(let object):
                export?.writeTrimmed(type: type, ref: ref, payload: object.body, isXML: type.api.isClassic)
                var warnings = object.warnings

                // benchmarks have no update endpoint: delete, then recreate.
                // the DELETE can report a misleading status after doing the
                // work (see DeleteEngine); a follow-up GET decides
                var action = context.action
                if type.key == "compliancebenchmarks", case .update(let destId) = action {
                    do {
                        _ = try await dest.send(.delete, type.api.detailPath(id: destId))
                    } catch let error as JamfPlatformError where error.status != nil {
                        guard await objectIsGone(type, id: destId) else { throw error }
                    }
                    action = .create
                }

                let destId: String
                do {
                    destId = try await write(object, type: type, action: action)
                } catch let error as JamfPlatformError where error.status == 409 && type.key == "compliancebenchmarks" {
                    // a duplicate title means a benchmark with this name already
                    // exists: treat it as the match
                    let refs = try await ObjectLister.list(type, on: dest)
                    if let existing = refs.first(where: { $0.name == ref.name }) {
                        return (.unchanged(destId: existing.id), warnings)
                    }
                    throw error
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
        } catch {
            return (.failed(reason: Self.blankingOut(secretValues, in: error.localizedDescription)), [])
        }
    }

    /// `text` with each of `values` replaced by JTKit's placeholder, so a
    /// reason keeps what went wrong ("Duplicate name") but not the secret.
    static func blankingOut(_ values: [String], in text: String) -> String {
        values.reduce(text) { $0.replacingOccurrences(of: $1, with: Redaction.placeholder) }
    }

    /// Creates or updates the object and returns its destination id.
    private func write(_ object: TransformedObject, type: ObjectType, action: TransformAction) async throws -> String {
        let response: HTTPResponse
        // a merge-patch request still answers in plain JSON
        let accept = object.contentType == "application/merge-patch+json" ? "application/json" : object.contentType
        if case .create = action, let subscription = object.patchSubscription {
            let destId = try await subscribe(to: subscription, privileges: type.access.create)
            _ = try await dest.send(type.updateMethod, type.updatePath(destId: destId),
                                    body: object.body,
                                    contentType: object.contentType,
                                    accept: accept,
                                    privileges: type.access.privileges(for: type.updateMethod))
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
            guard !id.isEmpty else { throw JamfPlatformError(.invalidResponse("The new object’s ID is missing from the answer.")) }
            return id
        }
        let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        // benchmark create responses name the id "benchmarkId" (verified live
        // 2026-10-04); everything else uses "id"
        guard let id = json?["id"] ?? json?["benchmarkId"] else {
            throw JamfPlatformError(.invalidResponse("The new object’s ID is missing from the answer."))
        }
        return "\(id)"
    }

    /// Subscribes the destination to a patch title through the Classic API,
    /// which creates its configuration, and returns the new id. The Pro
    /// create needs a softwareTitleId, which only exists once the destination
    /// is subscribed (verified live 2026-10-22).
    private func subscribe(to subscription: PatchSubscription, privileges: [JamfPro.Privilege]) async throws -> String {
        let sourceId = try await patchSourceId(named: subscription.sourceName)
        let xml = "<patch_software_title><name>\(ClassicXML.escape(subscription.displayName))</name>"
            + "<name_id>\(ClassicXML.escape(subscription.nameId))</name_id>"
            + "<source_id>\(sourceId)</source_id></patch_software_title>"
        let response = try await dest.send(.post, "proclassic/patchsoftwaretitles/id/0", body: Data(xml.utf8),
                                           contentType: "application/xml", accept: "application/xml",
                                           privileges: privileges)
        let id = ClassicXML.value(of: "id", in: String(decoding: response.data, as: UTF8.self))
        guard !id.isEmpty else { throw JamfPlatformError(.invalidResponse("The new object’s ID is missing from the answer.")) }
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

    struct MissingPatchSource: LocalizedError {
        let name: String
        var errorDescription: String? {
            "The patch source \"\(name)\" does not exist on the destination; add it there first."
        }
    }

    /// Type-specific follow-ups after a successful write.
    private func runPostActions(type: ObjectType, destId: String, sourcePayload: ObjectPayload,
                                warnings: inout [String]) async throws {
        switch type.key {
        case "computerprestages", "mobiledeviceprestages":
            // further changes need the profileUuid, which lags the write; a
            // 404 just after the create means the PreStage isn't there yet
            let outcome = try? await Self.poller(timeLimit: .seconds(30)).poll(
                check: { [dest] () -> String? in
                    let detail = try await ObjectLister.detail(type, id: destId, on: dest)
                    guard case .json(let json) = detail,
                          let uuid = json["profileUuid"] as? String, !uuid.isEmpty else { return nil }
                    return uuid
                },
                isDone: { $0 != nil },
                isNotReadyYet: { ($0 as? JamfPlatformError)?.status == 404 })
            if outcome?.isFinished != true {
                warnings.append("The PreStage's profile UUID did not appear in time; check the PreStage on the destination.")
            }

        case "blueprints":
            // mirror the source's deploy state; a repeat deploy is harmless.
            // deploymentState is an object: {"state": "DEPLOYED", "lastDeployment": …}
            guard case .json(let sourceJson) = sourcePayload else { return }
            let state: String
            if let dict = sourceJson["deploymentState"] as? [String: Any] {
                state = "\(dict["state"] ?? "")"
            } else {
                state = "\(sourceJson["deploymentState"] ?? "")"
            }
            guard state.localizedCaseInsensitiveContains("DEPLOYED") || state.localizedCaseInsensitiveContains("SUCCEEDED") else {
                return
            }
            // JTKit's deploy-and-watch: it tells the new deployment from an
            // earlier one by its start time and waits until it succeeds or fails
            let blueprints = JamfPlatform.Blueprints(client: dest)
            let previousStart: String?
            do {
                previousStart = try await blueprints.startDeployment(id: destId)
            } catch {
                warnings.append("The blueprint was created but could not be deployed: \(error.localizedDescription)")
                return
            }
            let outcome = try? await blueprints.watchDeployment(id: destId, previousStart: previousStart,
                                                                poller: Self.poller(timeLimit: .seconds(60)))
            switch outcome {
            case .finished(let status)? where status.didSucceed:
                break
            case .finished?:
                warnings.append("The blueprint was created but its deployment failed on the destination; check it there.")
            default:
                warnings.append("The blueprint was created but its deployment did not confirm in time; check it on the destination.")
            }

        case "compliancebenchmarks":
            // the benchmark syncs in the background; report a sync that fails.
            // syncState only appears on list entries, not the detail
            // (verified live 2026-10-04)
            let outcome = try? await Self.poller(timeLimit: .seconds(60)).poll(
                check: { [dest] () -> Bool? in
                    let response = try await dest.send(.get, type.api.listPath)
                    let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] ?? [:]
                    let entries = root["benchmarks"] as? [[String: Any]] ?? []
                    guard let entry = entries.first(where: { "\($0["id"] ?? "")" == destId }) else { return nil }
                    let state = "\(entry["syncState"] ?? "")"
                    if state.localizedCaseInsensitiveContains("FAILED") { return false }
                    return state.localizedCaseInsensitiveContains("SYNCED") ? true : nil
                },
                isDone: { $0 != nil })
            let synced = outcome?.isFinished == true ? outcome?.value ?? nil : nil
            if synced == false {
                warnings.append("The benchmark reports syncState FAILED on the destination.")
            } else if synced == nil {
                warnings.append("The benchmark sync did not confirm in time; check its syncState on the destination.")
            }

        default:
            break
        }
    }

    /// JTKit's wait for a job after a write (from 2 s, growing to 10 s), with
    /// the app's own time limit.
    private static func poller(timeLimit: Duration) -> JamfPlatform.Poller {
        JamfPlatform.Poller(policy: JamfPlatform.PollingPolicy(timeLimit: timeLimit))
    }

    /// Whether a GET of the object now fails with "not found" (benchmarks
    /// answer 403 for a deleted id).
    private func objectIsGone(_ type: ObjectType, id: String) async -> Bool {
        do {
            _ = try await dest.send(.get, type.api.detailPath(id: id),
                                    accept: type.api.isClassic ? "application/xml" : "application/json",
                                    privileges: type.access.read)
            return false
        } catch let error as JamfPlatformError {
            return error.status == 404 || error.status == 403
        } catch {
            return false
        }
    }

    /// Blueprints and Benchmarks reference device groups by platform UUID.
    private func loadPlatformGroupLookups() async throws {
        guard destIdsByName[platformGroupsKey] == nil else { return }
        let destGroups = try await MappingCatalog.platformGroups(on: dest)
        destIdsByName[platformGroupsKey] = Dictionary(destGroups.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        let sourceGroups = try await MappingCatalog.platformGroups(on: source)
        sourceNamesById[platformGroupsKey] = Dictionary(sourceGroups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    private func copyIcon(_ icon: SelfServiceIcon, type: ObjectType, destObjectId: String, warnings: inout [String]) async {
        do {
            let destIconId = try await icons.copy(icon)
            try await icons.assign(iconId: destIconId, displayName: icon.displayName,
                                   to: type, destObjectId: destObjectId, on: dest)
        } catch {
            warnings.append("The self-service icon \"\(icon.name)\" could not be copied: \(error.localizedDescription)")
        }
    }

    /// Lists a type on the destination and/or source purely to fill the
    /// lookup maps used by transforms.
    private func loadLookups(for typeKey: String, destination: Bool, source wantSource: Bool) async throws {
        guard let type = ObjectRegistry.type(typeKey) else { return }
        if destination && destIdsByName[typeKey] == nil {
            let refs = try await ObjectLister.list(type, on: dest)
            destIdsByName[typeKey] = Dictionary(refs.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        }
        if wantSource && sourceNamesById[typeKey] == nil {
            let refs = try await ObjectLister.list(type, on: source)
            sourceNamesById[typeKey] = Dictionary(refs.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        }
    }
}
