//
//  PermissionProbe.swift
//  JamfMigrator
//
//  Checks which endpoints a tenant's API integration can reach. The gateway
//  returns 403 BAD_PERMISSIONS both for a missing permission and for an
//  outdated endpoint version, so the registry must pin the newest endpoint
//  version before a 403 can be read as a missing permission.
//

import Foundation

enum ProbeResult: Equatable, Sendable {
    /// The endpoint answered 2xx.
    case allowed
    /// The gateway answered 403.
    case denied
    /// Any other HTTP status.
    case failed(status: Int)
    /// The request never got an HTTP response.
    case unreachable(String)
}

struct PermissionProbe: Sendable {
    let client: PlatformClient
    var maxConcurrent = 4

    /// GETs every path and classifies the outcome, keyed by path.
    func check(paths: [String]) async -> [String: ProbeResult] {
        await withTaskGroup(of: (String, ProbeResult).self) { group in
            var results = [String: ProbeResult]()
            var pending = paths.makeIterator()

            func addNext() -> Bool {
                guard let path = pending.next() else { return false }
                group.addTask { (path, await probe(path)) }
                return true
            }

            for _ in 0..<maxConcurrent where addNext() {}
            while let (path, result) = await group.next() {
                results[path] = result
                _ = addNext()
            }
            return results
        }
    }

    private func probe(_ path: String) async -> ProbeResult {
        do {
            _ = try await client.send(.get, path)
            return .allowed
        } catch let error as GatewayError {
            switch error.status {
            case 403:
                return .denied
            case .some(let status):
                return .failed(status: status)
            case nil:
                return .unreachable(error.localizedDescription)
            }
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}
