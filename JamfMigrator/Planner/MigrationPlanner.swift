//
//  MigrationPlanner.swift
//  JamfMigrator
//
//  The dry run: reads both tenants, changes nothing, and decides one outcome
//  per object. "Update vs Unchanged" compares the source object and the
//  destination object after both went through the same transform, so the
//  diff only shows differences that a real run would actually write.
//

import CryptoKit
import Foundation
import JTKit

actor MigrationPlanner {

    private let source: JamfPlatform.Client
    private let dest: JamfPlatform.Client
    private let secrets: [String: String]
    private let mappings: TenantMappings
    private let progress: (@Sendable (String) -> Void)?
    /// The destination's Jamf Pro version, from the permission check.
    private let destinationVersion: String?

    /// Real destination lookups per registry key.
    private var destIdsByName = [String: [String: String]]()
    private var destNamesById = [String: [String: String]]()
    private var destDuplicateNames = [String: Set<String>]()
    private var sourceNamesById = [String: [String: String]]()
    /// Names that will exist on the destination after the run (existing plus
    /// planned creates), so later steps aren't Blocked on dependencies this
    /// same run creates.
    private var plannedNames = [String: Set<String>]()
    /// Dependency lists a type may do without that couldn't be read, with why.
    private var unreadableLists = [String: String]()

    /// The sentinel id used for references to objects this run will create.
    static let plannedId = "(planned)"

    init(source: JamfPlatform.Client,
         dest: JamfPlatform.Client,
         secrets: [String: String] = [:],
         mappings: TenantMappings = TenantMappings(),
         destinationVersion: String? = nil,
         progress: (@Sendable (String) -> Void)? = nil) {
        self.source = source
        self.dest = dest
        self.secrets = secrets
        self.mappings = mappings
        self.destinationVersion = destinationVersion
        self.progress = progress
    }

    // MARK: Copy plan

    /// - Parameter only: a test-only limit to named source objects (see
    ///   `OnlyObjects`); the app itself never passes one.
    func plan(typeKeys: Set<String>, only: OnlyObjects? = nil) async -> MigrationPlan {
        var plan = MigrationPlan(mode: .copy, typeKeys: typeKeys)
        for type in ObjectRegistry.types where typeKeys.contains(type.key) {
            progress?(type.displayName)
            do {
                try await planType(type, included: typeKeys, only: only, into: &plan)
            } catch {
                var entry = ObjectPlan(typeKey: type.key, objectId: "-", name: "(all objects)",
                                       change: .blocked(reason: error.localizedDescription))
                entry.isReadFailure = true
                plan.entries.append(entry)
            }
        }
        return plan
    }

    private func planType(_ type: ObjectType, included: Set<String>, only: OnlyObjects?,
                          into plan: inout MigrationPlan) async throws {
        if type.requiresGateway && !(source.supportsPlatformEndpoints && dest.supportsPlatformEndpoints) {
            plan.entries.append(ObjectPlan(typeKey: type.key, objectId: "-", name: "(all objects)",
                                           change: .blocked(reason: PreflightReport.gatewayOnlyReason)))
            return
        }
        for dependency in type.dependencies + ["sites"] {
            do {
                try await loadLookups(for: dependency)
                unreadableLists[dependency] = nil
            } catch where Self.mayDoWithout(dependency, for: type) && !(error is CancellationError) {
                // only what refers to this list is Blocked, by the transform
                unreadableLists[dependency] = error.localizedDescription
            }
        }
        try await loadLookups(for: type.key)
        if ["blueprints", "compliancebenchmarks"].contains(type.key) {
            try await loadPlatformGroupLookups()
        }

        let sourceRefs = try await ObjectLister.list(type, on: source)
        sourceNamesById[type.key] = Dictionary(sourceRefs.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        // name matching can't tell same-named source objects apart, so every
        // one of them is Blocked, whichever are ticked
        let refs = sourceRefs.limited(to: only, typeKey: type.key)
        let nameCounts = Dictionary(refs.map { ($0.name, 1) }, uniquingKeysWith: +)
        for ref in refs {
            if (nameCounts[ref.name] ?? 0) > 1 {
                plan.entries.append(ObjectPlan(typeKey: type.key, objectId: ref.id, name: ref.name,
                                               change: .blocked(reason: "\(nameCounts[ref.name] ?? 0) source objects are named “\(ref.name)”; rename them so each can be migrated.")))
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
                              change: .blocked(reason: "More than one destination object is named “\(ref.name)”."))
        }
        do {
            let payload = try await ObjectLister.detail(type, id: ref.id, on: source)
            let existingDestId = destIdsByName[type.key]?[ref.name]
            var destPayload: ObjectPayload? = nil
            if let existingDestId {
                destPayload = try await ObjectLister.detail(type, id: existingDestId, on: dest)
            }
            return Self.compare(type, ref: ref, sourcePayload: payload, destId: existingDestId, destPayload: destPayload,
                                inputs: ComparisonInputs(destIdsByName: destIdsByName, destNamesById: destNamesById,
                                                         sourceNamesById: sourceNamesById,
                                                         plannedCreates: Self.creates(in: plannedNames, existing: destIdsByName),
                                                         secrets: secrets, included: included, mappings: mappings,
                                                         unreadable: unreadableLists, destinationVersion: destinationVersion))
        } catch {
            var entry = ObjectPlan(typeKey: type.key, objectId: ref.id, name: ref.name,
                                   change: .blocked(reason: error.localizedDescription))
            entry.isReadFailure = true
            return entry
        }
    }

    /// The planned names that aren't on the destination: what this run creates.
    private static func creates(in planned: [String: Set<String>], existing: [String: [String: String]]) -> [String: Set<String>] {
        var creates = [String: Set<String>]()
        for (typeKey, names) in planned {
            let new = names.filter { existing[typeKey]?[$0] == nil }
            if !new.isEmpty { creates[typeKey] = new }
        }
        return creates
    }

    // MARK: The comparison (shared with Run)

    /// What a comparison needs besides the two payloads. Run passes the same
    /// lookups Preview had, so an unchanged object compares the same.
    struct ComparisonInputs {
        /// Destination ids by name, per registry key, as they exist (no planned ones).
        var destIdsByName: [String: [String: String]]
        var destNamesById: [String: [String: String]]
        var sourceNamesById: [String: [String: String]]
        /// The names this run creates before this object, per registry key:
        /// references to them count as "will exist".
        var plannedCreates: [String: Set<String>]
        var secrets: [String: String]
        var included: Set<String>
        var mappings: TenantMappings
        /// Dependency lists the type may do without that couldn't be read.
        var unreadable: [String: String] = [:]
        /// The destination's Jamf Pro version, when known.
        var destinationVersion: String? = nil
    }

    /// Whether `type` can be planned without the `dependency` list: only
    /// Onboarding, whose items each name one object (an item that needs an
    /// unreadable list is what's Blocked, not the whole setting).
    static func mayDoWithout(_ dependency: String, for type: ObjectType) -> Bool {
        type.key == "onboarding" && type.dependencies.contains(dependency)
    }

    /// Decides one object's outcome from its payloads: Create, Update,
    /// Replace, Unchanged or Blocked, with the diff, the digests of what was
    /// compared and the objects it needs this run to create. No network.
    static func compare(_ type: ObjectType, ref: ObjectRef, sourcePayload payload: ObjectPayload,
                        destId existingDestId: String?, destPayload: ObjectPayload?,
                        inputs: ComparisonInputs) -> ObjectPlan {
        var lookups = inputs.destIdsByName
        for (typeKey, names) in inputs.plannedCreates {
            for name in names where lookups[typeKey]?[name] == nil {
                lookups[typeKey, default: [:]][name] = plannedId
            }
        }
        // a device group this run creates is a platform group once it exists,
        // so a Blueprint or Benchmark scoped to it isn't Blocked
        for name in plannedDeviceGroups(inputs.plannedCreates) where lookups[platformGroupsKey]?[name] == nil {
            lookups[platformGroupsKey, default: [:]][name] = plannedId
        }
        let references = PlannedReferenceRecorder()
        var context = TransformContext()
        context.isForComparison = true
        context.destIdsByName = lookups
        context.sourceNamesById = inputs.sourceNamesById
        context.secrets = inputs.secrets
        context.includedTypes = inputs.included
        context.mappings = inputs.mappings
        context.plannedReferences = references
        context.unreadableLists = inputs.unreadable
        context.destinationVersion = inputs.destinationVersion

        if let existingDestId {
            context.action = .update(destId: existingDestId)
            if ["osxconfigurationprofiles", "mobiledeviceconfigurationprofiles"].contains(type.key),
               case .xml(let destXml)? = destPayload {
                context.destProfileUUID = ClassicXML.value(of: "uuid", in: ClassicXML.value(of: "general", in: destXml))
            }
            if ["computerprestages", "mobiledeviceprestages"].contains(type.key),
               case .json(let destJson)? = destPayload {
                context.destVersionLocks = versionLocks(in: destJson)
                context.destPreStageIds = nestedIds(in: destJson)
            }
            if type.key == "sso", case .json(let destJson)? = destPayload {
                context.destEnabledFlags = ProTransformer.enabledFlags(in: destJson)
            }
        }

        let outcome = transform(type, payload: payload, context: context)
        switch outcome {
        case .blocked(let reason):
            return ObjectPlan(typeKey: type.key, objectId: ref.id, name: ref.name, change: .blocked(reason: reason))
        case .write(let transformed):
            let sourceDictionary = dictionary(from: transformed, isClassic: type.api.isClassic)
            var plan = ObjectPlan(typeKey: type.key, objectId: ref.id, name: ref.name, change: .create,
                                  warnings: transformed.warnings)
            plan.sourceDigest = digest(sourceDictionary)
            plan.plannedDependencies = dependencies(of: type, in: sourceDictionary, recorded: references.all,
                                                    plannedCreates: inputs.plannedCreates)
            guard let existingDestId, let destPayload else { return plan }
            // normalize the destination object the same way and compare —
            // same action, locks and nested ids so the echoed fields cancel
            // out, and identity mappings because the destination payload
            // already holds destination ids
            var destContext = TransformContext()
            destContext.isForComparison = true
            destContext.action = context.action
            destContext.destIdsByName = inputs.destIdsByName
            destContext.sourceNamesById = inputs.destNamesById
            destContext.secrets = inputs.secrets
            destContext.includedTypes = inputs.included
            destContext.mappings = inputs.mappings.identity
            destContext.unreadableLists = inputs.unreadable
            destContext.destVersionLocks = context.destVersionLocks
            destContext.destPreStageIds = context.destPreStageIds
            destContext.destEnabledFlags = context.destEnabledFlags
            guard case .write(let normalizedDest) = transform(type, payload: destPayload, context: destContext) else {
                return ObjectPlan(typeKey: type.key, objectId: ref.id, name: ref.name,
                                  change: .update(destId: existingDestId), warnings: transformed.warnings,
                                  sourceDigest: plan.sourceDigest, plannedDependencies: plan.plannedDependencies)
            }
            let destDictionary = dictionary(from: normalizedDest, isClassic: type.api.isClassic)
            plan.destDigest = digest(destDictionary)
            // Settings › Secrets values never go into the plan: only that the field differs
            let diff = PayloadDiff.hidingSecrets(PayloadDiff.diff(source: sourceDictionary, destination: destDictionary),
                                                 values: Array(inputs.secrets.values))
            if diff.isEmpty {
                return ObjectPlan(typeKey: type.key, objectId: ref.id, name: ref.name,
                                  change: .unchanged(destId: existingDestId),
                                  sourceDigest: plan.sourceDigest, destDigest: plan.destDigest)
            }
            // benchmarks have no update endpoint: delete and recreate
            let change: PlannedChange = type.key == "compliancebenchmarks"
                ? .replace(destId: existingDestId) : .update(destId: existingDestId)
            return ObjectPlan(typeKey: type.key, objectId: ref.id, name: ref.name, change: change,
                              warnings: transformed.warnings, diff: diff,
                              sourceDigest: plan.sourceDigest, destDigest: plan.destDigest,
                              plannedDependencies: plan.plannedDependencies)
        }
    }

    /// The device group types whose groups Blueprints and Benchmarks scope
    /// by platform id.
    static let deviceGroupKeys = ["smartcomputergroups", "staticcomputergroups",
                                  "smartmobiledevicegroups", "staticmobiledevicegroups"]

    /// The device group names the run creates, of every group type.
    static func plannedDeviceGroups(_ plannedCreates: [String: Set<String>]) -> Set<String> {
        deviceGroupKeys.reduce(into: Set<String>()) { $0.formUnion(plannedCreates[$1] ?? []) }
    }

    /// A SHA-256 of a compared payload, so Run can tell whether an object is
    /// still what Preview saw without keeping its contents. It is taken of
    /// the form `PayloadDiff` compares (empty and missing alike, true and 1
    /// alike), so a field Preview treats as equal never stops a run.
    static func digest(_ dictionary: [String: Any]) -> String {
        let form = PayloadDiff.comparedForm(dictionary)
        let data = (try? JSONSerialization.data(withJSONObject: form, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The run-created objects an object refers to: Jamf Pro references
    /// that resolved to a planned object, and Classic references by name
    /// (a `…/name` below the object's own name) to a planned object of a
    /// type it depends on.
    private static func dependencies(of type: ObjectType, in dictionary: [String: Any],
                                     recorded: Set<PlannedDependency>,
                                     plannedCreates: [String: Set<String>]) -> [PlannedDependency] {
        // a planned platform group is the device group the run creates
        var found = Set(recorded.map { dependency -> PlannedDependency in
            guard dependency.typeKey == platformGroupsKey,
                  let key = deviceGroupKeys.first(where: { plannedCreates[$0]?.contains(dependency.name) == true })
            else { return dependency }
            return PlannedDependency(typeKey: key, name: dependency.name)
        })
        if type.api.isClassic {
            var names: [String] = []
            collectReferenceNames(dictionary, path: [], into: &names)
            for dependency in type.dependencies {
                for name in names where plannedCreates[dependency]?.contains(name) == true {
                    found.insert(PlannedDependency(typeKey: dependency, name: name))
                }
            }
        }
        return found.sorted { ($0.typeKey, $0.name) < ($1.typeKey, $1.name) }
    }

    private static func collectReferenceNames(_ value: Any, path: [String], into names: inout [String]) {
        switch value {
        case let object as [String: Any]:
            for (key, child) in object { collectReferenceNames(child, path: path + [key], into: &names) }
        case let array as [Any]:
            for child in array { collectReferenceNames(child, path: path, into: &names) }
        case let text as String:
            // the object's own name is `<root>/name` or `<root>/general/name`
            guard path.last == "name", path.count > 2, !(path.count == 3 && path[1] == "general") else { return }
            names.append(text)
        default:
            return
        }
    }

    // MARK: Delete plan

    /// What delete mode would remove, in deletion order, with the built-ins
    /// kept, and the Jamf Pro accounts that keep the tenant reachable: the
    /// signed-in account (`signedInUsername`, a direct username-and-password
    /// connection's) and every full-access administrator account or group.
    func planDeletion(typeKeys: Set<String>, signedInUsername: String? = nil) async -> MigrationPlan {
        var plan = MigrationPlan(mode: .delete, typeKeys: typeKeys)
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
                                                       change: .keep(reason: "Built-in object.")))
                    } else if let reason = await accountKeepReason(type, ref: ref, signedInUsername: signedInUsername) {
                        plan.entries.append(ObjectPlan(typeKey: type.key, objectId: ref.id, name: ref.name,
                                                       change: .keep(reason: reason)))
                    } else {
                        plan.entries.append(ObjectPlan(typeKey: type.key, objectId: ref.id, name: ref.name,
                                                       change: .delete))
                    }
                }
            } catch {
                var entry = ObjectPlan(typeKey: type.key, objectId: "-", name: "(whole step)",
                                       change: .blocked(reason: error.localizedDescription))
                entry.isReadFailure = true
                plan.entries.append(entry)
            }
        }
        return plan
    }

    /// Why a Jamf Pro account or account group is never deleted, or nil
    /// for any other object: it is the signed-in account, it has full access
    /// with the Administrator privilege set, or its access couldn't be read
    /// (so it could be the last administrator).
    private func accountKeepReason(_ type: ObjectType, ref: ObjectRef, signedInUsername: String?) async -> String? {
        switch type.key {
        case "jamfusers":
            if let signedInUsername, !signedInUsername.isEmpty,
               ref.name.caseInsensitiveCompare(signedInUsername) == .orderedSame {
                return "The account this connection signs in with."
            }
            guard case .json(let json)? = try? await ObjectLister.detail(type, id: ref.id, on: dest) else {
                return "Its access couldn’t be read, so it could be the last administrator."
            }
            return Self.isFullAdministrator(accessLevel: json["accessLevel"] as? String,
                                            privilegeSet: json["privilegeLevel"] as? String)
        case "jamfgroups":
            guard case .xml(let xml)? = try? await ObjectLister.detail(type, id: ref.id, on: dest) else {
                return "Its access couldn’t be read, so it could hold the last administrator."
            }
            return Self.isFullAdministrator(accessLevel: ClassicXML.text(of: "access_level", in: xml),
                                            privilegeSet: ClassicXML.text(of: "privilege_set", in: xml))
        default:
            return nil
        }
    }

    /// The keep reason for an account or group with full access and the
    /// Administrator privilege set, or whose access isn't stated; nil otherwise.
    static func isFullAdministrator(accessLevel: String?, privilegeSet: String?) -> String? {
        func normalized(_ text: String?) -> String {
            (text ?? "").lowercased().filter(\.isLetter)
        }
        let access = normalized(accessLevel), privileges = normalized(privilegeSet)
        if access.isEmpty || privileges.isEmpty {
            return "Its access couldn’t be read, so it could be the last administrator."
        }
        if access == "fullaccess" && privileges == "administrator" {
            return "A full-access administrator: Wipe never removes the accounts that keep the tenant reachable."
        }
        return nil
    }

    // MARK: Helpers

    private static func transform(_ type: ObjectType, payload: ObjectPayload, context: TransformContext) -> TransformOutcome {
        switch payload {
        case .xml(let xml):
            ClassicTransformer.transform(type: type, xml: xml, context: context)
        case .json(let json):
            ProTransformer.transform(type: type, json: json, context: context)
        }
    }

    private static func dictionary(from object: TransformedObject, isClassic: Bool) -> [String: Any] {
        if isClassic {
            return XMLDictionary.parse(String(decoding: object.body, as: UTF8.self))
        }
        return (try? JSONSerialization.jsonObject(with: object.body) as? [String: Any]) ?? [:]
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
