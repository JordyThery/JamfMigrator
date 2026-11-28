//
//  ScratchDefaults.swift
//  JamfMigratorTests
//
//  Preference suites for one test, removed when the test ends, so no test
//  leaves a preferences file in the test host's container.
//

import Foundation
import JTKit

final class ScratchDefaults: @unchecked Sendable {
    private let names = Locked<[String]>([])

    /// A fresh suite named `jamfmigrator-<prefix>-<UUID>`.
    func make(_ prefix: String) -> UserDefaults {
        let name = "jamfmigrator-\(prefix)-\(UUID().uuidString)"
        names.withLock { $0.append(name) }
        return UserDefaults(suiteName: name)!
    }

    deinit {
        for name in names.value { UserDefaults.standard.removePersistentDomain(forName: name) }
    }
}
