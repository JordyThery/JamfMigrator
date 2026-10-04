//
//  Transformer.swift
//  JamfMigrator
//
//  Turns a source object's payload into what gets written to the destination.
//

import Foundation

enum TransformAction: Sendable {
    case create
    /// Updating an existing destination object with this id.
    case update(destId: String)
}

/// Everything a transform may need to look up. Built by the engine per type.
struct TransformContext: Sendable {
    var action: TransformAction = .create
    /// Destination ids by object name, per registry key ("categories", "sites", …).
    var destIdsByName: [String: [String: String]] = [:]
    /// Source object names by id, per registry key (to resolve id-only references).
    var sourceNamesById: [String: [String: String]] = [:]
    /// Service-account secrets from Settings, by key ("bind", "ldap", "fsrw",
    /// "fsro", "recoverylock").
    var secrets: [String: String] = [:]
    /// Which registry keys are part of this run (networksegments blanks the
    /// SUS reference when software update servers aren't migrated).
    var includedTypes: Set<String> = []
    /// For profile updates: the destination profile's payload UUID to keep.
    var destProfileUUID: String? = nil
    /// ADE and distribution-point mappings from the Clone wizard; the
    /// PreStage transforms consume these.
    var mappings = TenantMappings()
    /// For PreStage updates: the destination's versionLock values, which every
    /// PUT must echo. Keys: "root", "locationInformation",
    /// "purchasingInformation", "accountSettings".
    var destVersionLocks: [String: Int] = [:]
    /// For PreStage updates: the destination's nested block ids, which a PUT
    /// must echo (a POST sends "-1").
    var destPreStageIds: [String: String] = [:]
    /// Set by the planner when transforming both sides of a diff: fields that
    /// are regenerated on every write (Blueprint payload identifiers) use a
    /// stable placeholder instead, so identical objects compare as unchanged.
    var isForComparison = false

    func destId(_ typeKey: String, named name: String) -> String? {
        destIdsByName[typeKey]?[name]
    }

    func sourceName(_ typeKey: String, id: String) -> String? {
        sourceNamesById[typeKey]?[id]
    }
}

/// A self-service icon found on a policy or app; the engine copies it after
/// the object is written.
struct SelfServiceIcon: Sendable, Equatable {
    let name: String
    /// The icon id extracted from the icon URI — numeric on older instances,
    /// a CDN hash (hash_…) on Jamf Cloud.
    let sourceId: String
    /// The full icon URI; CDN-hash icons download straight from it.
    var uri: String = ""
    /// A policy's Self Service display name — an icon-only PUT resets it to
    /// the policy name (verified live 2026-10-04), so assign echoes it back.
    var displayName: String = ""
}

struct TransformedObject: Sendable {
    var body: Data
    var contentType: String
    /// Create somewhere other than the type's default create path
    /// (patch policies create under their title).
    var createPathOverride: String? = nil
    var warnings: [String] = []
    var icon: SelfServiceIcon? = nil
}

enum TransformOutcome: Sendable {
    case write(TransformedObject)
    /// The object can't be migrated (ASM class, FileVault profile, patch EA, …).
    case blocked(reason: String)
}

/// The placeholder written where the API won't return a secret and Settings
/// holds no replacement.
let placeholderSecret = "changeM3!"
