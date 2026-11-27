//
//  ExportWriter.swift
//  JamfMigrator
//
//  Saves source payloads (raw) and what was written to the destination
//  (trimmed) under the export folder, one file per object. Secrets never
//  reach the files: password and other secret fields (password hashes
//  included), Settings › Secrets values and license serial numbers are
//  replaced by JTKit's placeholder; everything else is kept as it is.
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

    /// The payload with its secret fields and each of `values` (also
    /// XML-escaped) replaced by the placeholder. Secret fields are found by
    /// structure, never in free text: the JSON keys and XML elements whose
    /// name says they hold a password, passcode, secret, token or private
    /// key (`isSecretField`). Everything else stays exactly as the tenant has
    /// it, so a script's contents or an extension attribute's script (which
    /// can say `API_PASSWORD=$4`) are kept whole.
    static func redacted(_ payload: Data, hiding values: [String]) -> Data {
        var text = String(decoding: payload, as: UTF8.self)
        if let json = try? JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed]),
           json is [String: Any] || json is [Any],
           let data = try? JSONSerialization.data(withJSONObject: blankingSecretFields(json),
                                                  options: [.prettyPrinted, .sortedKeys]) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = blankingSecretElements(text)
        }
        let candidates = values.flatMap { [$0, ClassicXML.escape($0)] }.filter { !$0.isEmpty }
        for value in Set(candidates).sorted(by: { $0.count > $1.count }) {
            text = text.replacingOccurrences(of: value, with: Redaction.placeholder)
        }
        return Data(text.utf8)
    }

    /// Words in a field's name (lowercased, without `_`, `-` and `.`) that
    /// make its value a secret.
    private static let secretParts = ["password", "passcode", "passwd", "secret", "token", "privatekey", "sharedkey"]

    /// Endings of a name that describe a secret rather than hold one
    /// (`recoveryLockPasswordType`, `tokenExpiration`).
    private static let describingEndings = ["type", "types", "enabled", "required", "set", "present", "length",
                                            "expiration", "expirationdate", "expirationepoch", "rotationtime", "name",
                                            "policy", "mode", "status", "count"]

    /// Whether a JSON key or XML element named `name` holds a secret.
    static func isSecretField(_ name: String) -> Bool {
        let normalized = String(name.lowercased().filter { !"_-. ".contains($0) })
        guard secretParts.contains(where: normalized.contains) else { return false }
        return !describingEndings.contains(where: normalized.hasSuffix)
    }

    /// Parsed JSON with each secret field's text or number replaced (true,
    /// false, null and empty text say nothing and stay).
    private static func blankingSecretFields(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var result = [String: Any]()
            for (key, inner) in dictionary {
                if isSecretField(key), !(inner is [String: Any]), !(inner is [Any]), !(inner is NSNull),
                   !isBoolean(inner), (inner as? String)?.isEmpty != true {
                    result[key] = Redaction.placeholder
                } else {
                    result[key] = blankingSecretFields(inner)
                }
            }
            return result
        }
        if let array = value as? [Any] { return array.map(blankingSecretFields) }
        return value
    }

    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// `<name …>value</name>` elements, also with attributes.
    private static let element = try! NSRegularExpression(pattern: #"<([A-Za-z0-9_.\-]+)(\s[^>]*)?>([^<]*)</\1\s*>"#)

    /// Classic XML with each secret element's text replaced. Text inside
    /// other elements is escaped (`&lt;password&gt;`), so it never matches.
    private static func blankingSecretElements(_ xml: String) -> String {
        let source = xml as NSString
        var result = ""
        var last = 0
        for match in element.matches(in: xml, range: NSRange(location: 0, length: source.length)) {
            let name = source.substring(with: match.range(at: 1))
            let value = match.range(at: 3)
            guard isSecretField(name), value.length > 0 else { continue }
            let found = source.substring(with: value).lowercased()
            if found == "true" || found == "false" { continue }
            result += source.substring(with: NSRange(location: last, length: value.location - last)) + Redaction.placeholder
            last = value.location + value.length
        }
        return result + source.substring(from: last)
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
