//
//  ExportWriter.swift
//  JamfMigrator
//
//  Saves source payloads (raw) and what was written to the destination
//  (trimmed) under the export folder, one file per object. Secrets never
//  reach the files: passwords, password hashes, Settings › Secrets values and
//  license serial numbers are replaced by JTKit's placeholder.
//

import Foundation
import JTKit

struct ExportWriter: Sendable {
    /// The run's export root, e.g. …/exports/20261004-0930.
    let root: URL

    /// - Parameter hiding: values that must not reach the file, wherever
    ///   they appear (Settings › Secrets values, license serial numbers).
    @discardableResult
    func writeRaw(type: ObjectType, ref: ObjectRef, payload: Data, isXML: Bool, hiding: [String] = []) -> Bool {
        write(Self.redacted(payload, hiding: hiding), to: folder(type: type, kind: "raw"), ref: ref, isXML: isXML)
    }

    @discardableResult
    func writeTrimmed(type: ObjectType, ref: ObjectRef, payload: Data, isXML: Bool, hiding: [String] = []) -> Bool {
        write(Self.redacted(payload, hiding: hiding), to: folder(type: type, kind: "trimmed"), ref: ref, isXML: isXML)
    }

    /// The payload with JTKit's redaction (every password-like JSON key and
    /// XML element) and each of `values`, also XML-escaped, replaced by the
    /// placeholder.
    static func redacted(_ payload: Data, hiding values: [String]) -> Data {
        var text = Redaction.text(String(decoding: payload, as: UTF8.self))
        let candidates = values.flatMap { [$0, ClassicXML.escape($0)] }.filter { !$0.isEmpty }
        for value in Set(candidates).sorted(by: { $0.count > $1.count }) {
            text = text.replacingOccurrences(of: value, with: Redaction.placeholder)
        }
        return Data(text.utf8)
    }

    private func folder(type: ObjectType, kind: String) -> URL {
        root.appendingPathComponent(type.key, isDirectory: true)
            .appendingPathComponent(kind, isDirectory: true)
    }

    private func write(_ payload: Data, to folder: URL, ref: ObjectRef, isXML: Bool) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let safeName = ref.name.replacingOccurrences(of: "/", with: ":")
            let url = folder.appendingPathComponent("\(safeName)-\(ref.id).\(isXML ? "xml" : "json")")
            try payload.write(to: url, options: .atomic)
            return true
        } catch {
            AppActivity.record("Export: couldn’t write \(ref.name): \(error.localizedDescription)",
                               category: "Export", level: .warning)
            return false
        }
    }
}
