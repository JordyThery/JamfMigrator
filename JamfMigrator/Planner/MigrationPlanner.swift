//
//  MigrationPlanner.swift
//  JamfMigrator
//
//  The dry run: reads both tenants, changes nothing, and decides one outcome
//  per object. "Update vs Unchanged" compares the source object and the
//  destination object after both went through the same transform, so the
//  diff only shows differences that a real run would actually write.
//

import Foundation

actor MigrationPlanner {

    private let source: PlatformClient
    private let dest: PlatformClient
    private let secrets: [String: String]
    private let mappings: TenantMappings
    private let progress: (@Sendable (String) -> Void)?

    /// Real destination lookups per registry key.
    private var destIdsByName = [String: [String: String]]()
    private var destNamesById = [String: [String: String]]()
    private var destDuplicateNames = [String: Set<String>]()
    private var sourceNamesById = [String: [String: String]]()
    /// Names that will exist on the destination after the run (existing plus
    /// planned creates), so later steps aren't Blocked on dependencies this
    /// same run creates.
    private var plannedNames = [String: Set<String>]()

    /// The sentinel id used for references to objects this run will create.
    private static let plannedId = "(planned)"

    init(source: PlatformClient,
         dest: PlatformClient,
         secrets: [String: String] = [:],
         mappings: TenantMappings = TenantMappings(),
         progress: (@Sendable (String) -> Void)? = nil) {
        self.source = source
        self.dest = dest
        self.secrets = secrets
        self.mappings = mappings
        self.progress = progress
    }

    // MARK: Copy plan

    func plan(typeKeys: Set<String>) async -> MigrationPlan {
        var plan = MigrationPlan(mode: .copy)
        for type in ObjectRegistry.types where typeKeys.contains(type.key) {
            progress?(type.displayName)
            do {
                try await planType(type, included: typeKeys, into: &plan)
            } catch {
                plan.entries.append(ObjectPlan(typeKey: type.key, objectId: "-", name: "(all objects)",
                                               change: .blocked(reason: error.localizedDescription)))
            }
        }
        return plan
    }

    private func planType(_ type: ObjectType, included: Set<String>, into plan: inout MigrationPlan) async throws {
        if type.requiresGateway && !(source.supportsPlatformEndpoints && dest.supportsPlatformEndpoints) {
            plan.entries.append(ObjectPlan(typeKey: type.key, objectId: "-", name: "(all objects)",
                                           change: .blocked(reason: "\(type.displayName) require the Jamf Platform API gateway; one of the selected tenants connects directly to Jamf Pro")))
            return
        }
        for dependency in type.dependencies + ["sites"] {
            try await loadLookups(for: dependency)
        }
        try await loadLookups(for: type.key)
        if ["blueprints", "compliancebenchmarks"].contains(type.key) {
            try await loadPlatformGroupLookups()
        }

        let sourceRefs = try await ObjectLister.list(type, on: source)
        sourceNamesById[type.key] = Dictionary(sourceRefs.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        var seenNames = Set<String>()
        for ref in sourceRefs {
            if !seenNames.insert(ref.name).inserted {
                plan.entries.append(ObjectPlan(typeKey: type.key, objectId: ref.id, name: ref.name,
                                               change: .blocked(reason: "Duplicate name on the source; rename one of the two objects to migrate both")))
                continue
            }
            let entry = await planObject(type, ref: ref, included: included)
            plan.entries.append(entry)
            if case .blocked = entry.change {} else {
                plannedNames[type.key, default: []].insert(ref.name)
            }
        }
    }

    private func planObject(_ type: ObjectType, ref: ObjectRef, included: Set<String>) async -> ObjectPlan {
        if destDuplicateNames[type.key]?.contains(ref.name) == true {
            return ObjectPlan(typeKey: type.key, objectId: ref.id, name: ref.name,
                              change: .blocked(reason: "More than one destination object is named \"\(ref.name)\""))
        }
        do {
            let payload = try await ObjectLister.detail(type, id: ref.id, on: source)
            let existingDestId = destIdsByName[type.key]?[ref.name]

            var context = TransformContext()
            context.isForComparison = true
            context.destIdsByName = lookupsIncludingPlanned()
            context.sourceNamesById = sourceNamesById
            context.secrets = secrets
            context.includedTypes = included
            context.mappings = mappings

            var destPayload: ObjectPayload? = nil
            if let existingDestId {
                context.action = .update(destId: existingDestId)
                destPayload = try await ObjectLister.detail(type, id: existingDestId, on: dest)
                if ["osxconfigurationprofiles", "mobiledeviceconfigurationprofiles"].contains(type.key),
                   case .xml(let destXml)? = destPayload {
                    context.destProfileUUID = ClassicXML.value(of: "uuid", in: ClassicXML.value(of: "general", in: destXml))
                }
                if ["computerprestages", "mobiledeviceprestages"].contains(type.key),
                   case .json(let destJson)? = destPayload {
                    context.destVersionLocks = Self.versionLocks(in: destJson)
                    context.destPreStageIds = Self.nestedIds(in: destJson)
                }
            }

            let outcome = transform(type, payload: payload, context: context)
            switch outcome {
            case .blocked(let reason):
                return ObjectPlan(typeKey: type.key, objectId: ref.id, name: ref.name,
                                  change: .blocked(reason: reason))
            case .write(let transformed):
                guard let existingDestId, let destPayload else {
                    return ObjectPlan(typeKey: type.key, objectId: ref.id, name: ref.name,
                                      change: .create, warnings: transformed.warnings)
                }
                // normalize the destination object the same way and compare —
                // same action, locks and nested ids so the echoed fields cancel
                // out, and identity mappings because the destination payload
                // already holds destination ids
                var destContext = TransformContext()
                destContext.isForComparison = true
                destContext.action = context.action
                destContext.destIdsByName = destIdsByName
                destContext.sourceNamesById = destNamesById
                destContext.secrets = secrets
                destContext.includedTypes = included
                destContext.mappings = mappings.identity
                destContext.destVersionLocks = context.destVersionLocks
                destContext.destPreStageIds = context.destPreStageIds
                guard case .write(let normalizedDest) = transform(type, payload: destPayload, context: destContext) else {
                    return ObjectPlan(typeKey: type.key, objectId: ref.id, name: ref.name,
                                      change: .update(destId: existingDestId), warnings: transformed.warnings)
                }
                let diff = PayloadDiff.diff(source: dictionary(from: transformed, isClassic: type.api.isClassic),
                                            destination: dictionary(from: normalizedDest, isClassic: type.api.isClassic))
                if diff.isEmpty {
                    return ObjectPlan(typeKey: type.key, objectId: ref.id, name: ref.name,
                                      change: .unchanged(destId: existingDestId))
                }
                // benchmarks have no update endpoint: delete and recreate
                if type.key == "compliancebenchmarks" {
                    return ObjectPlan(typeKey: type.key, objectId: ref.id, name: ref.name,
                                      change: .replace(destId: existingDestId),
                                      warnings: transformed.warnings, diff: diff)
                }
                return ObjectPlan(typeKey: type.key, objectId: ref.id, name: ref.name,
                                  change: .update(destId: existingDestId),
                                  warnings: transformed.warnings, diff: diff)
            }
        } catch {
            return ObjectPlan(typeKey: type.key, objectId: ref.id, name: ref.name,
                              change: .blocked(reason: error.localizedDescription))
        }
    }

    // MARK: Delete plan

    /// What delete mode would remove, in deletion order, with the built-ins kept.
    func planDeletion(typeKeys: Set<String>) async -> MigrationPlan {
        var plan = MigrationPlan(mode: .delete)
        for type in ObjectRegistry.deletionOrder where typeKeys.contains(type.key) {
            progress?(type.displayName)
            if type.requiresGateway && !dest.supportsPlatformEndpoints {
                continue
            }
            if case .singleton = type.listShape {
                // settings can't be deleted; they are left as they are
                continue
            }
            do {
                let refs = try await ObjectLister.list(type, on: dest)
                for ref in refs {
                    if DeleteEngine.protectedNames[type.key]?.contains(ref.name) == true {
                        plan.entries.append(ObjectPlan(typeKey: type.key, objectId: ref.id, name: ref.name,
                                                       change: .keep(reason: "Built-in object")))
                    } else {
                        plan.entries.append(ObjectPlan(typeKey: type.key, objectId: ref.id, name: ref.name,
                                                       change: .delete))
                    }
                }
            } catch {
                plan.entries.append(ObjectPlan(typeKey: type.key, objectId: "-", name: "(whole step)",
                                               change: .blocked(reason: error.localizedDescription)))
            }
        }
        return plan
    }

    // MARK: Helpers

    private func transform(_ type: ObjectType, payload: ObjectPayload, context: TransformContext) -> TransformOutcome {
        switch payload {
        case .xml(let xml):
            ClassicTransformer.transform(type: type, xml: xml, context: context)
        case .json(let json):
            ProTransformer.transform(type: type, json: json, context: context)
        }
    }

    private func dictionary(from object: TransformedObject, isClassic: Bool) -> [String: Any] {
        if isClassic {
            return XMLDictionary.parse(String(decoding: object.body, as: UTF8.self))
        }
        return (try? JSONSerialization.jsonObject(with: object.body) as? [String: Any]) ?? [:]
    }

    /// Destination lookups extended with the names this run will create, so a
    /// reference to an object planned earlier in the run isn't Blocked.
    private func lookupsIncludingPlanned() -> [String: [String: String]] {
        var merged = destIdsByName
        for (typeKey, names) in plannedNames {
            for name in names where merged[typeKey]?[name] == nil {
                merged[typeKey, default: [:]][name] = Self.plannedId
            }
        }
        return merged
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

    /// The nested block ids a PreStage PUT must echo.
    static func nestedIds(in json: [String: Any]) -> [String: String] {
        var ids = [String: String]()
        for block in ["locationInformation", "purchasingInformation", "accountSettings"] {
            if let nested = json[block] as? [String: Any], let id = nested["id"] {
                ids[block] = "\(id)"
            }
        }
        return ids
    }

    /// The versionLock values a PreStage PUT must echo.
    static func versionLocks(in json: [String: Any]) -> [String: Int] {
        var locks = [String: Int]()
        if let root = json["versionLock"] as? Int { locks["root"] = root }
        for block in ["locationInformation", "purchasingInformation", "accountSettings"] {
            if let nested = json[block] as? [String: Any], let lock = nested["versionLock"] as? Int {
                locks[block] = lock
            }
        }
        return locks
    }

    private func loadLookups(for typeKey: String) async throws {
        guard let type = ObjectRegistry.type(typeKey) else { return }
        if destIdsByName[typeKey] == nil {
            let refs = try await ObjectLister.list(type, on: dest)
            var byName = [String: String]()
            var duplicates = Set<String>()
            for ref in refs {
                if byName[ref.name] != nil {
                    duplicates.insert(ref.name)
                } else {
                    byName[ref.name] = ref.id
                }
            }
            destIdsByName[typeKey] = byName
            destNamesById[typeKey] = Dictionary(refs.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            destDuplicateNames[typeKey] = duplicates
        }
        // source id → name, so references in detail payloads (which carry
        // ids only) resolve even when the dependency isn't being planned
        if sourceNamesById[typeKey] == nil {
            let refs = try await ObjectLister.list(type, on: source)
            sourceNamesById[typeKey] = Dictionary(refs.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        }
    }
}
