//
//  ExportWriter.swift
//  JamfMigrator
//
//  Saves source payloads (raw) and what was written to the destination
//  (trimmed) under the export folder, one file per object.
//

import Foundation

struct ExportWriter: Sendable {
    /// The run's export root, e.g. …/exports/20261004-0930.
    let root: URL

    init(root: URL) {
        self.root = root
    }

    func writeRaw(type: ObjectType, ref: ObjectRef, payload: Data, isXML: Bool) {
        write(payload, to: folder(type: type, kind: "raw"), ref: ref, isXML: isXML)
    }

    func writeTrimmed(type: ObjectType, ref: ObjectRef, payload: Data, isXML: Bool) {
        write(payload, to: folder(type: type, kind: "trimmed"), ref: ref, isXML: isXML)
    }

    private func folder(type: ObjectType, kind: String) -> URL {
        root.appendingPathComponent(type.key, isDirectory: true)
            .appendingPathComponent(kind, isDirectory: true)
    }

    private func write(_ payload: Data, to folder: URL, ref: ObjectRef, isXML: Bool) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let safeName = ref.name.replacingOccurrences(of: "/", with: ":")
            let url = folder.appendingPathComponent("\(safeName)-\(ref.id).\(isXML ? "xml" : "json")")
            try payload.write(to: url, options: .atomic)
        } catch {
            WriteToLog.shared.message("[ExportWriter] could not write \(ref.name): \(error.localizedDescription)")
        }
    }
}
