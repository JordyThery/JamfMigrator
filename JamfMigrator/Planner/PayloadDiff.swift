//
//  PayloadDiff.swift
//  JamfMigrator
//
//  Structural comparison of two normalized payloads. Classic XML is parsed
//  into dictionaries first so both API families diff the same way.
//

import Foundation

enum PayloadDiff {

    /// Field-level differences between two JSON-like values. Empty means the
    /// payloads are identical.
    static func diff(source: Any?, destination: Any?, path: String = "") -> [DiffEntry] {
        var entries = [DiffEntry]()
        compare(source, destination, path: path, into: &entries)
        return entries
    }

    private static func compare(_ source: Any?, _ destination: Any?, path: String, into entries: inout [DiffEntry]) {
        switch (source, destination) {
        case (nil, nil), (is NSNull, is NSNull):
            return
        case (let a as [String: Any], let b as [String: Any]):
            for key in Set(a.keys).union(b.keys).sorted() {
                compare(a[key], b[key], path: path.isEmpty ? key : "\(path)/\(key)", into: &entries)
            }
        case (let a as [Any], let b as [Any]):
            if a.count != b.count {
                entries.append(DiffEntry(path: "\(path)#count", source: "\(a.count)", destination: "\(b.count)"))
            }
            for index in 0..<min(a.count, b.count) {
                compare(a[index], b[index], path: "\(path)[\(index)]", into: &entries)
            }
        default:
            let a = leaf(source)
            let b = leaf(destination)
            if a != b {
                entries.append(DiffEntry(path: path, source: a, destination: b))
            }
        }
    }

    private static func leaf(_ value: Any?) -> String? {
        switch value {
        case nil, is NSNull:
            return nil
        case let number as NSNumber:
            // normalizes true/1 representations across JSON and XML strings
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : "\(number)"
        default:
            return "\(value!)"
        }
    }
}

/// Parses an XML document into nested dictionaries: text-only elements become
/// strings, repeated element names become arrays. Attributes are ignored —
/// Classic payloads carry data in elements.
final class XMLDictionary: NSObject, XMLParserDelegate {

    private var stack: [[String: Any]] = []
    private var textStack: [String] = []
    private var root: [String: Any] = [:]

    static func parse(_ xml: String) -> [String: Any] {
        let converter = XMLDictionary()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = converter
        parser.parse()
        return converter.root
    }

    func parserDidStartDocument(_ parser: XMLParser) {
        stack = [[:]]
        textStack = [""]
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        stack.append([:])
        textStack.append("")
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textStack[textStack.count - 1] += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        let children = stack.removeLast()
        let text = textStack.removeLast().trimmingCharacters(in: .whitespacesAndNewlines)
        let value: Any = children.isEmpty ? text : children

        var parent = stack.removeLast()
        if let existing = parent[elementName] {
            if var array = existing as? [Any] {
                array.append(value)
                parent[elementName] = array
            } else {
                parent[elementName] = [existing, value]
            }
        } else {
            parent[elementName] = value
        }
        stack.append(parent)
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        root = stack.last ?? [:]
    }
}
