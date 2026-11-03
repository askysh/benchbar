import Foundation

/// The guest-local name a room is browsed under: `<slug>-<8hex>.localhost:<port>` (A9).
/// Cookies are port-agnostic (spike S5), so the per-install suffix keeps one host's session
/// away from another install's and from plain `localhost`. `*.localhost` resolves to
/// loopback with no hosts line and no sudo.
nonisolated enum LocalShareName {
    static let suffixKey = "shareGuestInstallSuffix"
    static let portRange = 41000...41999

    /// Lower case `[a-z0-9-]`, 1 to 40 characters, no leading or trailing hyphen.
    static func slug(label: String) -> String {
        let folded = label.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var out = ""
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(Character(scalar)) || ("0"..."9").contains(Character(scalar)) {
                out.unicodeScalars.append(scalar)
            } else if scalar != "'" && scalar != "\u{2019}" && !out.isEmpty && !out.hasSuffix("-") {
                out.append("-")
            }
        }
        out = String(out.prefix(40))
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "room" : out
    }

    /// Eight random hex digits, drawn once per install and kept.
    static func installSuffix(defaults: UserDefaults = .standard) -> String {
        if let stored = defaults.string(forKey: suffixKey), stored.count == 8, Data(hex: stored) != nil { return stored }
        let fresh = (0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        defaults.set(fresh, forKey: suffixKey)
        return fresh
    }

    static func host(label: String, suffix: String) -> String {
        "\(slug(label: label))-\(suffix).localhost"
    }

    /// Deterministic per host pin within 41000-41999, moving on while a port is taken.
    static func port(for hostPin: Data, isFree: (UInt16) -> Bool) -> UInt16? {
        let seed = hostPin.prefix(2).reduce(0) { $0 << 8 | Int($1) }
        let count = portRange.count
        for step in 0..<count {
            let port = UInt16(portRange.lowerBound + (seed + step) % count)
            if isFree(port) { return port }
        }
        return nil
    }
}
