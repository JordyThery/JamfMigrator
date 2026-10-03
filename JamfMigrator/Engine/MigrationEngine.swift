//
//  MigrationEngine.swift
//  JamfMigrator
//
//  Copies the selected object types from the source tenant to the
//  destination: list → fetch detail → transform → match by name → create or
//  update. Every outcome lands in the RunJournal, so a run can resume.
//

import Foundation

actor MigrationEngine {

    private let source: PlatformClient
    private let dest: PlatformClient
    private let journal: JournalStore
    private let export: ExportWriter?
    private let secrets: [String: String]
    private let progress: (@Sendable (ProgressEvent) -> Void)?
    private let icons: IconMigrator

    private var isCancelled = false
    /// Destination ids by name and source names by id, per registry key.
    /// Filled per type as the run proceeds and reused by later transforms.
    private var destIdsByName = [String: [String: String]]()
    private var sourceNamesById = [String: [String: String]]()

    init(source: PlatformClient,
         dest: PlatformClient,
         journal: JournalStore,
         export: ExportWriter? = nil,
         secrets: [String: String] = [:],
         progress: (@Sendable (ProgressEvent) -> Void)? = nil) {
        self.source = source
        self.dest = dest
        self.journal = journal
        self.export = export
        self.secrets = secrets
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
            do {
                try await migrateType(type, included: typeKeys,
                                      excluded: excluding[type.key] ?? [], report: &report)
            } catch {
                WriteToLog.shared.message("[MigrationEngine] \(type.key) failed: \(error.localizedDescription)")
                report.add(type: type, ref: ObjectRef(id: "-", name: "(whole step)"),
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

        let sourceRefs = try await ObjectLister.list(type, on: source)
        sourceNamesById[type.key] = Dictionary(sourceRefs.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        try await loadLookups(for: type.key, destination: true, source: false)

        var completed = 0
        for ref in sourceRefs where !excluded.contains(ref.id) {
            guard !isCancelled else { return }
            completed += 1

            // resume: skip objects an interrupted run already finished
            if let previous = await journal.status(type: type.key, objectId: ref.id), previous.isDone {
                report.add(type: type, ref: ref, status: previous)
                continue
            }

            let (status, warnings) = await migrateObject(type, ref: ref, included: included)
            await journal.record(type: type.key, objectId: ref.id, status: status)
            if let destId = status.destId {
                destIdsByName[type.key, default: [:]][ref.name] = destId
            }
            report.add(type: type, ref: ref, status: status, warnings: warnings)
            progress?(ProgressEvent(type: type.key, objectName: ref.name,
                                    completed: completed, total: sourceRefs.count, status: status))
        }
    }

    private func migrateObject(_ type: ObjectType, ref: ObjectRef, included: Set<String>) async -> (ObjectStatus, [String]) {
        do {
            let payload = try await ObjectLister.detail(type, id: ref.id, on: source)

            var context = TransformContext()
            context.destIdsByName = destIdsByName
            context.sourceNamesById = sourceNamesById
            context.secrets = secrets
            context.includedTypes = included

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
                let destId = try await write(object, type: type, action: context.action)
                if let icon = object.icon {
                    await copyIcon(icon, type: type, destObjectId: destId, warnings: &warnings)
                }
                if case .update = context.action {
                    return (.updated(destId: destId), warnings)
                }
                return (.created(destId: destId), warnings)
            }
        } catch {
            return (.failed(reason: error.localizedDescription), [])
        }
    }

    /// Creates or updates the object and returns its destination id.
    private func write(_ object: TransformedObject, type: ObjectType, action: TransformAction) async throws -> String {
        let response: PlatformClient.Response
        switch action {
        case .create:
            let path = object.createPathOverride ?? type.api.createPath
            response = try await dest.send(.post, path, body: object.body,
                                           contentType: object.contentType,
                                           accept: object.contentType)
        case .update(let destId):
            response = try await dest.send(type.updateMethod, type.api.detailPath(id: destId),
                                           body: object.body,
                                           contentType: object.contentType,
                                           accept: object.contentType)
            return destId
        }

        // the created id: <id>n</id> on Classic, "id" in the JSON on Pro
        if type.api.isClassic {
            let id = ClassicXML.value(of: "id", in: String(decoding: response.data, as: UTF8.self))
            guard !id.isEmpty else { throw GatewayError.decoding(URLError(.cannotParseResponse)) }
            return id
        }
        let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        guard let id = json?["id"] else { throw GatewayError.decoding(URLError(.cannotParseResponse)) }
        return "\(id)"
    }

    private func copyIcon(_ icon: SelfServiceIcon, type: ObjectType, destObjectId: String, warnings: inout [String]) async {
        do {
            let destIconId = try await icons.copy(icon)
            try await icons.assign(iconId: destIconId, to: type, destObjectId: destObjectId, on: dest)
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
