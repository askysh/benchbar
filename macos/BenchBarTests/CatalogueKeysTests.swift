import Foundation
import Testing
@testable import BenchBar

/// Reads the `String(localized: "...")` keys out of the Swift sources, so a key that is missing
/// from the String Catalog cannot ship silently. A missing key still shows its English (the key
/// is the default value), which is why nothing else would notice.
///
/// A key is compared in a normal form: every interpolation is one slot (its argument type does
/// not matter here, the catalogue's `%lld` and `%@` are one slot too) and a literal percent sign
/// is `%%`, as in the catalogue.
nonisolated enum LocalizedKeys {
    nonisolated struct Found {
        var file: String
        var line: Int
        /// nil when the literal could not be read (an escape this scanner does not know).
        var key: String?
    }

    private static let slot: Unicode.Scalar = "\u{1}"
    private static let marker = Array("String(localized: \"".unicodeScalars)

    // MARK: sources

    /// Every key in every Swift file below `folder`.
    static func scan(_ folder: URL) throws -> [Found] {
        var found: [Found] = []
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return found }
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for item in keys(in: text) {
                found.append(Found(file: url.lastPathComponent, line: item.line, key: item.key))
            }
        }
        return found
    }

    /// The keys of one file's text, with their line numbers. Comment lines are skipped.
    static func keys(in text: String) -> [(line: Int, key: String?)] {
        var result: [(line: Int, key: String?)] = []
        var number = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            number += 1
            let line = Array(rawLine.unicodeScalars)
            if isComment(line) { continue }
            var i = 0
            while i < line.count {
                if begins(line, at: i, with: marker) {
                    let start = i + marker.count
                    if let parsed = literal(line, from: start) {
                        result.append((line: number, key: parsed.key))
                        i = parsed.end
                    } else {
                        result.append((line: number, key: nil))
                        i = start
                    }
                } else {
                    i += 1
                }
            }
        }
        return result
    }

    private static func isComment(_ line: [Unicode.Scalar]) -> Bool {
        var i = 0
        while i < line.count && (line[i] == " " || line[i] == "\t") { i += 1 }
        return i + 1 < line.count && line[i] == "/" && line[i + 1] == "/"
    }

    private static func begins(_ line: [Unicode.Scalar], at index: Int, with pattern: [Unicode.Scalar]) -> Bool {
        if index + pattern.count > line.count { return false }
        for offset in 0..<pattern.count where line[index + offset] != pattern[offset] { return false }
        return true
    }

    /// The text of a string literal that starts after its opening quote, and the index after its
    /// closing quote. nil when it ends early or holds an escape this does not know.
    private static func literal(_ line: [Unicode.Scalar], from start: Int) -> (key: String, end: Int)? {
        var out = String.UnicodeScalarView()
        var i = start
        while i < line.count {
            let c = line[i]
            if c == "\"" { return (String(out), i + 1) }
            if c == "%" {
                out.append("%")
                out.append("%")
                i += 1
            } else if c == "\\" {
                guard i + 1 < line.count else { return nil }
                let next = line[i + 1]
                if next == "(" {
                    guard let after = endOfInterpolation(line, from: i + 2) else { return nil }
                    out.append(slot)
                    i = after
                    continue
                }
                switch next {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default: return nil
                }
                i += 2
            } else {
                out.append(c)
                i += 1
            }
        }
        return nil
    }

    /// The index after the `)` that closes an interpolation whose text starts at `start`.
    private static func endOfInterpolation(_ line: [Unicode.Scalar], from start: Int) -> Int? {
        var depth = 1
        var i = start
        while i < line.count {
            let c = line[i]
            if c == "(" {
                depth += 1
            } else if c == ")" {
                depth -= 1
                if depth == 0 { return i + 1 }
            } else if c == "\"" {
                i += 1
                while i < line.count && line[i] != "\"" {
                    if line[i] == "\\" { i += 1 }
                    i += 1
                }
            }
            i += 1
        }
        return nil
    }

    // MARK: catalogue

    /// The catalogue's keys in the same normal form: each format specifier is one slot.
    static func catalogueKeys(_ file: URL) throws -> Set<String> {
        let data = try Data(contentsOf: file)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = root["strings"] as? [String: Any] else { return [] }
        let specifier = try NSRegularExpression(
            pattern: #"%(?:[0-9]+\$)?[-+ #0]*[0-9]*(?:\.[0-9]+)?(?:hh|h|ll|l|q|z|t|j|L)?[diouxXeEfFgGaAcCsSpDU@]"#)
        var keys = Set<String>()
        for key in strings.keys {
            var text = key.replacingOccurrences(of: "%%", with: "\u{2}")
            text = specifier.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\u{1}")
            keys.insert(text.replacingOccurrences(of: "\u{2}", with: "%%"))
        }
        return keys
    }
}

@Suite("Catalogue keys")
struct CatalogueKeysTests {
    private let slot = "\u{1}"

    /// The scanner itself, on text it must read the way the compiler does.
    @Test func theScannerReadsLiteralsLikeTheCompiler() {
        let text = """
        let a = String(localized: "Plain text")
        let b = String(localized: "\\(count) of \\(names.joined(separator: ", ")) done")
        let c = String(localized: "100% sure, \\"quoted\\"") + String(localized: "second")
        // String(localized: "in a comment")
        let d = String(localized: "tab\\there")
        """
        let found = LocalizedKeys.keys(in: text)
        let readKeys: [String?] = found.map { $0.key }
        let readLines: [Int] = found.map { $0.line }
        #expect(readKeys == [
            "Plain text",
            "\(slot) of \(slot) done",
            "100%% sure, \"quoted\"",
            "second",
            "tab\there",
        ])
        #expect(readLines == [1, 2, 3, 3, 5])
    }

    @Test func catalogueKeysAreNormalisedLikeTheScanner() throws {
        let keys = try LocalizedKeys.catalogueKeys(Self.catalogue)
        #expect(keys.contains("\(slot) apps"), "%lld apps is one slot and ' apps'")
        #expect(keys.contains("Exported \(slot) apps"))
    }

    @Test func everyLocalizedKeyInTheSourcesIsInTheCatalogue() throws {
        let keys = try LocalizedKeys.catalogueKeys(Self.catalogue)
        let found = try LocalizedKeys.scan(ShareRepo.macos.appendingPathComponent("BenchBar"))
        #expect(found.count > 80, "the scanner found \(found.count) keys; it is not reading the sources")

        let unreadable = found.filter { $0.key == nil }.map { "\($0.file):\($0.line)" }
        #expect(unreadable.isEmpty, "literals the scanner cannot read: \(unreadable.joined(separator: ", "))")

        let missing = found.compactMap { item -> String? in
            guard let key = item.key, !keys.contains(key) else { return nil }
            return "\(item.file):\(item.line): \(key.replacingOccurrences(of: slot, with: "%@"))"
        }
        #expect(missing.isEmpty, "not in Localizable.xcstrings:\n\(missing.joined(separator: "\n"))")
    }

    private static var catalogue: URL {
        ShareRepo.macos.appendingPathComponent("BenchBar/Resources/Localizable.xcstrings")
    }
}
