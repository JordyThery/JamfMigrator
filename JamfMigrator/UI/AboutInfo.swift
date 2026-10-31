//
//  AboutInfo.swift
//  JamfMigrator
//
//  What the About window shows (JTKit's `AboutWindow`), including the credit
//  for Replicator, which Jamf Migrator started as a fork of.
//

import Foundation
import JTKit

extension AboutConfiguration {
    static let jamfMigrator = AboutConfiguration(
        appName: "Jamf Migrator",
        copyright: AboutCopyright(year: "2026", holder: "Jordy Thery"),
        author: "Created by Jordy Thery",
        summary: "Copies a source Jamf tenant to a destination tenant, or any selection down to a single object, with a dry-run preview, a resumable engine and a gated wipe.",
        links: [
            AboutLink("github.com/JordyThery/JamfMigrator", address: "https://github.com/JordyThery/JamfMigrator"),
        ].compactMap { $0 },
        acknowledgements: [.replicator]
    )
}

/// Credit for Replicator, with its MIT licence as it appears in
/// THIRD-PARTY-NOTICES.md and in Replicator's own LICENSE.
extension Acknowledgement {
    static let replicatorRepositoryURL = URL(string: "https://github.com/jamf/Replicator")

    static let replicator = Acknowledgement(
        name: "Replicator",
        author: "Jamf Professional Services",
        summary: "Jamf Migrator started as a fork of Replicator and has been rewritten as a SwiftUI app on top of the Jamf Platform API and the Jamf Pro APIs.",
        links: [
            replicatorRepositoryURL.map { AboutLink("jamf/Replicator", url: $0) },
        ].compactMap { $0 },
        license: """
            MIT License

            Copyright (c) 2017 Jamf Professional Services

            Permission is hereby granted, free of charge, to any person obtaining a copy
            of this software and associated documentation files (the "Software"), to deal
            in the Software without restriction, including without limitation the rights
            to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
            copies of the Software, and to permit persons to whom the Software is
            furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all
            copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
            FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
            AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
            LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
            OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
            SOFTWARE.
            """
    )
}
