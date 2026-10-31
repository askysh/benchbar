import Foundation

/// The login link Open as hands to the browser, and what is done to keep its
/// session id (a credential) out of everything else.
///
/// Frappe answers `/login?redirect-to=PATH&sid=SID` with a 301 to PATH and
/// sets the cookie, so the id never stays in the address bar. A browser
/// caches that 301: `t` must differ on every link, or a reused one skips the
/// server and signs nobody in.
nonisolated enum OpenAsLink {
    /// RFC 3986 unreserved characters; anything else, including `/ ? & #`, is escaped.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// `base` is `http://site:port`.
    static func url(base: String, path: String, sid: String, millis: Int) -> URL? {
        let target = removingSession(from: path).addingPercentEncoding(withAllowedCharacters: unreserved) ?? "%2F"
        return URL(string: "\(base)/login?redirect-to=\(target)&sid=\(sid)&t=\(millis)")
    }

    /// The path with any `sid=` query item dropped; the rest is kept as it was.
    static func removingSession(from path: String) -> String {
        let fragmentStart = path.firstIndex(of: "#")
        let beforeFragment = path[..<(fragmentStart ?? path.endIndex)]
        let fragment = fragmentStart.map { String(path[$0...]) } ?? ""
        guard let queryStart = beforeFragment.firstIndex(of: "?") else { return path }
        let kept = beforeFragment[beforeFragment.index(after: queryStart)...]
            .split(separator: "&", omittingEmptySubsequences: true)
            .filter { $0.split(separator: "=", maxSplits: 1).first.map(String.init) != "sid" }
        let head = String(beforeFragment[..<queryStart])
        return head + (kept.isEmpty ? "" : "?" + kept.joined(separator: "&")) + fragment
    }

    /// The session id of the link the CLI printed.
    static func sessionID(in link: String) -> String? {
        URLComponents(string: link)?.queryItems?.first { $0.name == "sid" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `text` with every `sid=...` value hidden, for a message shown to the user.
    static func scrub(_ text: String) -> String {
        text.replacingOccurrences(of: "sid=[^&\\s\"']+", with: "sid=…", options: .regularExpression)
    }
}
