import Foundation

/// `benchbar://share/<fp16>/app/...`: opens a page of a room this Mac has already joined.
/// It never joins or starts anything (U3); an unknown room only shows the pane.
nonisolated enum ShareDeepLink {
    struct Target: Equatable, Sendable {
        var fp16: String
        var path: String
    }

    static func parse(_ url: URL) -> Target? {
        guard url.scheme?.lowercased() == "benchbar", url.host?.lowercased() == "share",
              url.query == nil, url.fragment == nil else { return nil }
        let raw = url.absoluteString
        guard let range = raw.range(of: "://share/", options: .caseInsensitive) else { return nil }
        let rest = raw[range.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let fp16 = String(rest[..<slash])
        let path = String(rest[slash...])
        guard fp16.count == 16, fp16.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }), isSafeAppPath(path) else { return nil }
        return Target(fp16: fp16, path: path)
    }

    /// The gateway's normalisation rules, kept stricter: only `/app` and below, no query,
    /// one level of valid UTF-8 percent-encoding, no encoded slash or backslash, no empty,
    /// `.` or `..` segment, no `;`, no control or non-ASCII characters.
    static func isSafeAppPath(_ raw: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~%!$&'()*+,=:@/")
        guard raw.hasPrefix("/"), raw.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              let decoded = raw.removingPercentEncoding else { return false }
        // removingPercentEncoding accepts a lone "%"; the raw form must be well formed.
        guard raw.replacingOccurrences(of: "%[0-9A-Fa-f]{2}", with: "", options: .regularExpression).contains("%") == false else { return false }
        if decoded.contains("%") || decoded.contains("\\") || decoded.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) { return false }
        // An encoded slash would change the segments after decoding.
        if decoded.split(separator: "/", omittingEmptySubsequences: false).count != raw.split(separator: "/", omittingEmptySubsequences: false).count { return false }
        let segments = decoded.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        for (index, segment) in segments.enumerated() {
            if segment == "." || segment == ".." || segment.contains(";") { return false }
            if segment.isEmpty && index != segments.count - 1 { return false }
        }
        return decoded == "/app" || decoded.hasPrefix("/app/")
    }

    /// The first 16 hex digits of the host's SPKI hash.
    static func fp16(of hostPin: Data) -> String {
        String(hostPin.hex.prefix(16))
    }
}
