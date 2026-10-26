//
//  ObjectLister.swift
//  JamfMigrator
//
//  Lists a type's objects on one tenant and fetches details. Classic lists
//  are requested as JSON; Classic details and writes speak XML.
//

import Foundation
import JTKit

/// One object in a list: its id and unique name on that tenant.
struct ObjectRef: Sendable, Hashable {
    let id: String
    let name: String
}

enum ObjectLister {

    /// Every object of `type` on the tenant behind `client`.
    static func list(_ type: ObjectType, on client: JamfPlatform.Client) async throws -> [ObjectRef] {
        let read = type.access.read
        switch type.listShape {
        case .proPaginated:
            // JTKit's Jamf Pro page reader: a page without "results" is an
            // error, never an empty list, and so is a list that never ends
            return try await client.allPages(type.api.listPath, pageSize: 200, privileges: read) { entry in
                ref(from: entry, nameKey: type.nameKey)
            }
        case .proArray:
            let response = try await client.send(.get, type.api.listPath, privileges: read)
            let array = try JSONSerialization.jsonObject(with: response.data) as? [[String: Any]] ?? []
            return refs(from: array, nameKey: type.nameKey)
        case .classicArray(let container):
            let response = try await client.send(.get, type.api.listPath, accept: "application/json", privileges: read)
            let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] ?? [:]
            let array = root[container] as? [[String: Any]] ?? []
            return refs(from: array, nameKey: type.nameKey)
        case .singleton:
            // a settings singleton always exists, once, on every tenant
            return [ObjectRef(id: "singleton", name: type.displayName)]
        case .classicAccounts(let sub):
            let response = try await client.send(.get, type.api.listPath, accept: "application/json", privileges: read)
            let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] ?? [:]
            let accounts = root["accounts"] as? [String: Any] ?? [:]
            let array = accounts[sub] as? [[String: Any]] ?? []
            return refs(from: array, nameKey: type.nameKey)
        }
    }

    /// One entry of a Jamf Pro page; nil without an id.
    static func ref(from entry: LosslessJSON, nameKey: String) -> ObjectRef? {
        guard let id = text(entry["id"]) else { return nil }
        return ObjectRef(id: id, name: canonicalName(entry[nameKey]?.stringValue ?? ""))
    }

    /// A string, or a number as written.
    static func text(_ value: LosslessJSON?) -> String? {
        switch value {
        case .string(let text)?: text
        case .number(let number)?: number.literal
        default: nil
        }
    }

    private static func refs(from entries: [[String: Any]], nameKey: String) -> [ObjectRef] {
        entries.compactMap { entry in
            guard let id = entry["id"] else { return nil }
            let name = entry[nameKey] as? String ?? ""
            return ObjectRef(id: "\(id)", name: canonicalName(name))
        }
    }

    /// Classic creates store a leading space as a non-breaking space (the API
    /// strips a plain leading space), so names must match across that rewrite.
    static func canonicalName(_ name: String) -> String {
        name.hasPrefix("\u{00A0}") ? " " + name.dropFirst() : name
    }

    /// The object's full payload: JSON dict for Pro, XML string for Classic.
    static func detail(_ type: ObjectType, id: String, on client: JamfPlatform.Client) async throws -> ObjectPayload {
        if case .singleton = type.listShape {
            let response = try await client.send(.get, type.api.listPath, privileges: type.access.read)
            let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] ?? [:]
            return .json(json)
        }
        if type.api.isClassic {
            let response = try await client.send(.get, type.api.detailPath(id: id), accept: "application/xml",
                                                 privileges: type.access.read)
            return .xml(String(decoding: response.data, as: UTF8.self))
        } else {
            let response = try await client.send(.get, type.api.detailPath(id: id), privileges: type.access.read)
            let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] ?? [:]
            return .json(json)
        }
    }
}

enum ObjectPayload {
    case xml(String)
    // [String: Any] is not Sendable; payloads are produced and consumed inside
    // the engine actor, never shared.
    case json([String: Any])
}
