//
//  ClassicXML.swift
//  JamfMigrator
//
//  Small string-based XML helpers for Classic API payloads, ported from the
//  legacy RemoveData.Xml / tagValue helpers. Classic payloads are rewritten
//  as strings on purpose: round-tripping through XMLDocument reorders and
//  re-escapes content the server is sensitive about.
//

import Foundation

enum ClassicXML {

    /// Removes every occurrence of `<tag>…</tag>` (and self-closing `<tag/>`).
    static func strippingTag(_ tag: String, from xml: String) -> String {
        var result = replacing(pattern: "<\(tag)>(.|\\n|\\r)*?</\(tag)>", in: xml, with: "")
        result = replacing(pattern: "<\(tag)/>", in: result, with: "")
        result = replacing(pattern: "<\(tag) [^>]*/>", in: result, with: "")
        return result
    }

    /// The text between the first `<tag>` and `</tag>`, or "".
    static func value(of tag: String, in xml: String) -> String {
        guard let start = xml.range(of: "<\(tag)>"),
              let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) else {
            return ""
        }
        return String(xml[start.upperBound..<end.lowerBound])
    }

    /// Regex replace (case-insensitive, dot matches newlines via explicit groups).
    static func replacing(pattern: String, in xml: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return xml
        }
        return regex.stringByReplacingMatches(in: xml, options: [],
                                              range: NSRange(xml.startIndex..., in: xml),
                                              withTemplate: template)
    }

    static func escape(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        return escaped
    }
}
