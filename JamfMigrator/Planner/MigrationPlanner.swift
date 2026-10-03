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
    static let plannedId = "(planned)"

    init(source: PlatformClient,
         dest: PlatformClient,
         secrets: [String: String] = [:],
         progress: (@Sendable (String) -> Void)? = nil) {
        self.source = source
        self.dest = dest
        self.secrets = secrets
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
                plan.entries.append(ObjectPlan(typeKey: type.key, objectId: "-", name: "(whole step)",
                                               change: .blocked(reason: error.localizedDescription)))
            }
        }
        return plan
    }

    private func planType(_ type: ObjectType, included: Set<String>, into plan: inout MigrationPlan) async throws {
        for dependency in type.dependencies + ["sites"] {
            try await loadLookups(for: dependency)
        }
        try await loadLookups(for: type.key)

        let sourceRefs = try await ObjectLister.list(type, on: source)
        sourceNamesById[type.key] = Dictionary(sourceRefs.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        for ref in sourceRefs {
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
            context.destIdsByName = lookupsIncludingPlanned()
            context.sourceNamesById = sourceNamesById
            context.secrets = secrets
            context.includedTypes = included

            var destPayload: ObjectPayload? = nil
            if let existingDestId {
                context.action = .update(destId: existingDestId)
                destPayload = try await ObjectLister.detail(type, id: existingDestId, on: dest)
                if ["osxconfigurationprofiles", "mobiledeviceconfigurationprofiles"].contains(type.key),
                   case .xml(let destXml)? = destPayload {
                    context.destProfileUUID = ClassicXML.value(of: "uuid", in: ClassicXML.value(of: "general", in: destXml))
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
                // normalize the destination object the same way and compare
                var destContext = TransformContext()
                destContext.destIdsByName = destIdsByName
                destContext.sourceNamesById = destNamesById
                destContext.secrets = secrets
                destContext.includedTypes = included
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

    private func loadLookups(for typeKey: String) async throws {
        guard let type = ObjectRegistry.type(typeKey), destIdsByName[typeKey] == nil else { return }
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
}
