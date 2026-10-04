//
//  ObjectLister.swift
//  JamfMigrator
//
//  Lists a type's objects on one tenant and fetches details. Classic lists
//  are requested as JSON; Classic details and writes speak XML.
//

import Foundation

/// One object in a list: its id and unique name on that tenant.
struct ObjectRef: Sendable, Hashable {
    let id: String
    let name: String
}

enum ObjectLister {

    /// Every object of `type` on the tenant behind `client`.
    static func list(_ type: ObjectType, on client: PlatformClient) async throws -> [ObjectRef] {
        switch type.listShape {
        case .proPaginated:
            return try await listProPaginated(type, on: client)
        case .proArray:
            let response = try await client.send(.get, type.api.listPath, accept: "application/json")
            let array = try JSONSerialization.jsonObject(with: response.data) as? [[String: Any]] ?? []
            return refs(from: array, nameKey: type.nameKey)
        case .classicArray(let container):
            let response = try await client.send(.get, type.api.listPath, accept: "application/json")
            let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] ?? [:]
            let array = root[container] as? [[String: Any]] ?? []
            return refs(from: array, nameKey: type.nameKey)
        case .singleton:
            // a settings singleton always exists, once, on every tenant
            return [ObjectRef(id: "singleton", name: type.displayName)]
        case .classicAccounts(let sub):
            let response = try await client.send(.get, type.api.listPath, accept: "application/json")
            let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] ?? [:]
            let accounts = root["accounts"] as? [String: Any] ?? [:]
            let array = accounts[sub] as? [[String: Any]] ?? []
            return refs(from: array, nameKey: type.nameKey)
        }
    }

    private static func listProPaginated(_ type: ObjectType, on client: PlatformClient) async throws -> [ObjectRef] {
        var results = [ObjectRef]()
        var page = 0
        let pageSize = 200
        while true {
            let query = [URLQueryItem(name: "page", value: "\(page)"),
                         URLQueryItem(name: "page-size", value: "\(pageSize)")]
            let response = try await client.send(.get, type.api.listPath, query: query)
            let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] ?? [:]
            let pageEntries = root["results"] as? [[String: Any]] ?? []
            results.append(contentsOf: refs(from: pageEntries, nameKey: type.nameKey))
            let totalCount = root["totalCount"] as? Int ?? results.count
            if results.count >= totalCount || pageEntries.isEmpty {
                return results
            }
            page += 1
        }
    }

    private static func refs(from entries: [[String: Any]], nameKey: String) -> [ObjectRef] {
        entries.compactMap { entry in
            guard let id = entry["id"] else { return nil }
            let name = entry[nameKey] as? String ?? ""
            return ObjectRef(id: "\(id)", name: name)
        }
    }

    /// The object's full payload: JSON dict for Pro, XML string for Classic.
    static func detail(_ type: ObjectType, id: String, on client: PlatformClient) async throws -> ObjectPayload {
        if case .singleton = type.listShape {
            let response = try await client.send(.get, type.api.listPath)
            let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] ?? [:]
            return .json(json)
        }
        if type.api.isClassic {
            let response = try await client.send(.get, type.api.detailPath(id: id), accept: "application/xml")
            return .xml(String(decoding: response.data, as: UTF8.self))
        } else {
            let response = try await client.send(.get, type.api.detailPath(id: id))
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
