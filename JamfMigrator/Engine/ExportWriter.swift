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

    /// The payload with its secret fields and each of `values` replaced by
    /// the placeholder. Secret fields are found by structure, never in free
    /// text: the JSON keys, XML elements and configuration profile keys
    /// whose name says they hold a password, passcode, secret, token or
    /// private key (`isSecretField`). Everything else stays as the tenant
    /// has it, so a script's contents or an extension attribute's script
    /// (which can say `API_PASSWORD=$4`) are kept whole. JSON is read and
    /// written with JTKit's `LosslessJSON`, so numbers and key order stay as
    /// they were.
    static func redacted(_ payload: Data, hiding values: [String]) -> Data {
        let hidden = Array(Set(values.filter { !$0.isEmpty })).sorted { $0.count > $1.count }
        if let json = try? LosslessJSON(data: payload) {
            switch json {
            case .object, .array:
                return blankingSecretFields(json, hiding: hidden).serialized(pretty: true)
            default:
                break
            }
        }
        var text = blankingSecretElements(String(decoding: payload, as: UTF8.self))
        // a value also appears XML-escaped in Classic XML
        let candidates = hidden.flatMap { [$0, ClassicXML.escape($0)] }
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

    /// JSON with each secret field's text or number replaced (true, false,
    /// null and empty text say nothing and stay), and each hidden value
    /// replaced inside any text.
    private static func blankingSecretFields(_ value: LosslessJSON, hiding hidden: [String]) -> LosslessJSON {
        switch value {
        case .object(var object):
            for index in object.members.indices {
                let member = object.members[index]
                switch member.value {
                case .number where isSecretField(member.key):
                    object.members[index].value = .string(Redaction.placeholder)
                case .string(let text) where isSecretField(member.key) && !text.isEmpty:
                    object.members[index].value = .string(Redaction.placeholder)
                default:
                    object.members[index].value = blankingSecretFields(member.value, hiding: hidden)
                }
            }
            return .object(object)
        case .array(let array):
            return .array(array.map { blankingSecretFields($0, hiding: hidden) })
        case .string(var text):
            for value in hidden { text = text.replacingOccurrences(of: value, with: Redaction.placeholder) }
            return .string(text)
        default:
            return value
        }
    }

    /// `<name …>value</name>` elements, also with attributes.
    private static let element = try! NSRegularExpression(pattern: #"<([A-Za-z0-9_.\-]+)(\s[^>]*)?>([^<]*)</\1\s*>"#)

    /// A configuration profile's `<key>…</key>` and the `<string>` or
    /// `<data>` value after it, in the escaped form Classic XML carries a
    /// profile's `<payloads>` in, and as plain XML.
    private static let plistPairs: [NSRegularExpression] = [
        #"&lt;key&gt;((?:(?!&lt;).)*?)&lt;/key&gt;(\s*)&lt;(string|data)&gt;((?:(?!&lt;).)*?)&lt;/\3&gt;"#,
        #"<key>([^<]*)</key>(\s*)<(string|data)>([^<]*)</\3>"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.dotMatchesLineSeparators]) }

    /// A profile's `<payloads>` with each secret key's value replaced (a
    /// Wi-Fi password, a VPN shared secret, an 802.1X password); every other
    /// byte stays as it was.
    private static func blankingProfileSecrets(_ payloads: String) -> String {
        var text = payloads
        for regex in plistPairs {
            let source = text as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                let key = ClassicXML.unescape(source.substring(with: match.range(at: 1)))
                let value = match.range(at: 4)
                guard isSecretField(key), value.length > 0 else { continue }
                result += source.substring(with: NSRange(location: last, length: value.location - last))
                    + ClassicXML.escape(Redaction.placeholder)
                last = value.location + value.length
            }
            text = result + source.substring(from: last)
        }
        return text
    }

    /// `<payloads>…</payloads>`, a Classic profile's escaped plist.
    private static let payloadsElement = try! NSRegularExpression(pattern: #"(<payloads>)(.*?)(</payloads>)"#,
                                                                  options: [.dotMatchesLineSeparators])

    private static func blankingPayloads(_ xml: String) -> String {
        let source = xml as NSString
        var result = ""
        var last = 0
        for match in payloadsElement.matches(in: xml, range: NSRange(location: 0, length: source.length)) {
            let inner = match.range(at: 2)
            result += source.substring(with: NSRange(location: last, length: inner.location - last))
                + blankingProfileSecrets(source.substring(with: inner))
            last = inner.location + inner.length
        }
        return result + source.substring(from: last)
    }

    /// Classic XML with each secret element's text replaced, and each
    /// secret key's value in a profile's payloads. Text inside other
    /// elements is escaped (`&lt;password&gt;`), so it never matches.
    private static func blankingSecretElements(_ xml: String) -> String {
        let xml = blankingPayloads(xml)
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
