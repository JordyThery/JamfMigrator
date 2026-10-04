//
//  Transformer.swift
//  JamfMigrator
//
//  Turns a source object's payload into what gets written to the destination.
//  The per-type rules are ported from the legacy Cleanup.swift.
//

import Foundation

enum TransformAction: Sendable, Equatable {
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
    /// Service-account secrets from Settings: "bind", "ldap", "fsrw", "fsro".
    var secrets: [String: String] = [:]
    /// Which registry keys are part of this run (networksegments blanks the
    /// SUS reference when software update servers aren't migrated).
    var includedTypes: Set<String> = []
    /// For profile updates: the destination profile's payload UUID to keep.
    var destProfileUUID: String? = nil
    /// ADE and distribution-point mappings from the Clone wizard (Phase 6
    /// PreStage transforms consume these).
    var mappings = TenantMappings()

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
    /// The icon id on the source server, extracted from the icon URI.
    let sourceId: String
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
/// holds no replacement. Matches the legacy default.
let placeholderSecret = "changeM3!"
