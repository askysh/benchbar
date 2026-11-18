import CryptoKit
import Foundation

/// `benchbar://` links, for Raycast, Shortcuts and the like. Pure: a URL
/// and the bench list in, one action out, so the rules are tested without
/// the app.
///
/// Any web page can open a link like this, so only launches and start,
/// stop and restart are routes, plus two profile links that only open a
/// prefilled sheet.Nothing here repairs, drops, restores,
/// pulls, installs or deletes; a route that is not in `Route` is ignored.
nonisolated enum URLRouter {
    static let scheme = "benchbar"

    enum Route: String, CaseIterable, Sendable {
        case up, down, restart, open, logs, window, doctor
        /// Launches only: Terminal with bench's console or database, the editor.
        case console, db, editor

        /// The routes `site=` applies to.
        var takesSite: Bool { self == .open || self == .console || self == .db }
    }

    /// A parsed link, before the bench is known.
    struct Request: Equatable, Sendable {
        var route: Route
        /// `bench=`: a name or an absolute path.
        var bench: String?
        /// `site=`: which site `open`, `console` and `db` use.
        var site: String?
    }

    /// What the app should do.
    enum Outcome: Equatable, Sendable {
        /// Run the route on this bench (its path); `site` only for `open`, `console`, `db`.
        case run(Route, bench: String, site: String?)
        /// The window, with no bench in particular.
        case window
        /// The window, with a message for the person: the bench or site was not found or
        /// not clear. The message may name what they asked for; the log never does, it
        /// holds only the `Why` (see `logLine`).
        case explain(String, Why)
        /// Not a link for us, or a route we do not have: log it, do nothing. The text is a
        /// fixed sentence: it is logged, so it never repeats a part of the link.
        case ignore(String)
        /// Team Profiles with the import or subscribe sheet prefilled. The
        /// sheet waits for the user's click; the link itself fetches nothing.
        case profile(ProfileLink)
        /// A page of a room this Mac already joined; never joins anything (U3).
        case share(ShareDeepLink.Target)
        /// `benchbar://share/join?…`: the join sheet with the invite's code filled in, waiting
        /// for the Join click. It carries the code, so the link itself is never logged.
        case shareInvite(Result<ShareInvite, ShareInvite.Problem>)
    }

    /// Why a link was explained, as a kind. Its `logText` is fixed: no bench name, site, path
    /// or address the link carried (MAC-10).
    enum Why: String, CaseIterable, Equatable, Sendable {
        case profileNeedsHTTPS, subscribeNeedsGit, noBench, needsBench, benchNotFound, benchAmbiguous, siteNotFound

        var logText: String {
            switch self {
            case .profileNeedsHTTPS: "profile link refused: no https address"
            case .subscribeNeedsGit: "subscribe link refused: no git address"
            case .noBench: "link refused: no bench is known"
            case .needsBench: "link refused: it does not say which bench"
            case .benchNotFound: "link refused: no such bench"
            case .benchAmbiguous: "link refused: the bench name is not unique"
            case .siteNotFound: "link refused: no such site"
            }
        }
    }

    /// `benchbar://profile/import?url=` and `benchbar://profile/subscribe?url=`.
    enum ProfileLink: Equatable, Sendable {
        case importProfile(String)
        case subscribe(String)
    }

    /// The bench fields the router needs from `benchbar list --json`.
    struct Bench: Equatable, Sendable {
        var path: String
        var name: String
        var sites: [String]
    }

    /// `benchbar://up?bench=frappe-bench`. The route is the host
    /// (`benchbar://up`) or, for `benchbar:up`, the path; case does not matter.
    static func parse(_ url: URL) -> Result<Request, IgnoreReason> {
        guard url.scheme?.lowercased() == scheme else { return .failure(.notOurScheme) }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = url.host(percentEncoded: false) ?? ""
        let word = (host.isEmpty ? components?.path ?? "" : host)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard let route = Route(rawValue: word) else { return .failure(word.isEmpty ? .noRoute : .unknownRoute) }
        let items = components?.queryItems ?? []
        func value(_ key: String) -> String? {
            guard let text = items.last(where: { $0.name.lowercased() == key })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        return .success(Request(route: route, bench: value("bench"), site: value("site")))
    }

    enum IgnoreReason: Error, Equatable, Sendable {
        case notOurScheme
        case unknownRoute
        case noRoute

        /// Fixed sentences: they are logged, so they never repeat the host, path or query.
        var message: String {
            switch self {
            case .notOurScheme: return "not a benchbar:// link"
            case .unknownRoute: return "unknown route"
            case .noRoute: return "no route in the link"
            }
        }
    }

    /// The one log line for a link the app ignored or explained: `link` is `logLabel(url)`.
    /// Fixed texts only, so no host, path, query or bench name the link carried can reach the
    /// log. nil for an outcome that is not logged here.
    static func rejectionLogLine(link: String, outcome: Outcome) -> String? {
        switch outcome {
        case .ignore(let reason): return "Ignored \(link): \(reason)"
        case .explain(_, let why): return "\(link): \(why.logText)"
        default: return nil
        }
    }

    /// What a link is called in the log: the scheme and the action word, never the host, path,
    /// query or userinfo (a profile link can carry a token, a share link a room code). A link
    /// that is not one of ours, or has a route we do not have, is only a short hash, enough to
    /// tell two apart and nothing to read back.
    static func logLabel(_ url: URL) -> String {
        if url.scheme?.lowercased() == scheme {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let words = ((url.host(percentEncoded: false) ?? "") + "/" + (components?.path ?? ""))
                .split(separator: "/").map { $0.lowercased() }
            if let first = words.first {
                if Route(rawValue: first) != nil { return "\(scheme)://\(first)" }
                if first == "share" { return "\(scheme)://share" }
                if first == "profile", words.count > 1, words[1] == "import" || words[1] == "subscribe" {
                    return "\(scheme)://profile/\(words[1])"
                }
            }
        }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return "other link, hash " + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The whole decision: parse, then pick the bench. `selected` is the
    /// bench the app has selected, if any.
    static func route(_ url: URL, benches: [Bench], selected: String?, lanRooms: Bool = false) -> Outcome {
        if let outcome = profileRoute(url) { return outcome }
        if let outcome = shareRoute(url) {
            // the reason is generic on purpose: ignored links are logged, and an invite holds a code
            return lanRooms ? outcome : .ignore("share links need the lan-rooms lab (benchbar labs on lan-rooms)")
        }
        switch parse(url) {
        case .failure(let reason):
            return .ignore(reason.message)
        case .success(let request):
            return resolve(request, benches: benches, selected: selected)
        }
    }

    /// nil when the link is not a profile link. The address must be an
    /// https URL (import) or a git remote (subscribe), or nothing opens.
    static func profileRoute(_ url: URL) -> Outcome? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let words = ((url.host(percentEncoded: false) ?? "") + "/" + (components?.path ?? ""))
            .split(separator: "/").map { $0.lowercased() }
        guard words.first == "profile" else { return nil }
        let action = words.count > 1 ? words[1] : ""
        guard action == "import" || action == "subscribe", words.count == 2 else {
            return .ignore(IgnoreReason.unknownRoute.message)
        }
        let address = components?.queryItems?.last(where: { $0.name.lowercased() == "url" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if action == "import" {
            guard ProfileSourceRule.isImportURL(address) else {
                return .explain("The profile link has no https address in url=, so BenchBar did not open it.", .profileNeedsHTTPS)
            }
            return .profile(.importProfile(address))
        }
        guard ProfileSourceRule.isGitURL(address) else {
            return .explain("The subscribe link has no git repository address in url=, so BenchBar did not open it.", .subscribeNeedsGit)
        }
        return .profile(.subscribe(address))
    }

    /// nil when the link is not a share link. `benchbar://share/<fp16>/app…` only: any other
    /// path, a query or a fragment is ignored (ShareDeepLink).
    static func shareRoute(_ url: URL) -> Outcome? {
        guard url.scheme?.lowercased() == scheme, url.host(percentEncoded: false)?.lowercased() == "share" else { return nil }
        // Any share link with a query may hold a code: it goes to the invite parser, never to
        // `.ignore`, which logs the link.
        if ShareInvite.isInviteLink(url) || url.query != nil || url.fragment != nil { return .shareInvite(ShareInvite.parse(url)) }
        guard let target = ShareDeepLink.parse(url) else { return .ignore("a share link opens only benchbar://share/<room>/app pages") }
        return .share(target)
    }

    static func resolve(_ request: Request, benches: [Bench], selected: String?) -> Outcome {
        let bench: Bench
        switch pickBench(request.bench, benches: benches, selected: selected) {
        case .found(let found):
            bench = found
        case .none where request.route == .window:
            return .window
        case .none:
            return benches.isEmpty
                ? .explain("BenchBar knows no bench yet, so the link has nothing to act on.", .noBench)
                : .explain("More than one bench: add ?bench=NAME to the link to say which one.", .needsBench)
        case .notFound(let query):
            return .explain("No bench named \"\(query)\". The link uses the names and paths from benchbar list.", .benchNotFound)
        case .ambiguous(let query):
            return .explain("More than one bench is named \"\(query)\": use its full path in ?bench= instead.", .benchAmbiguous)
        }

        var site: String?
        if request.route.takesSite, let wanted = request.site {
            guard let match = bench.sites.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                return .explain("\(bench.name) has no site named \"\(wanted)\".", .siteNotFound)
            }
            site = match
        }
        return .run(request.route, bench: bench.path, site: site)
    }

    private enum Pick: Equatable {
        case found(Bench), none, notFound(String), ambiguous(String)
    }

    /// An absolute path (or ~/...) matches the path, anything else the name.
    /// Without `bench=`: the selected bench, else the only one.
    private static func pickBench(_ query: String?, benches: [Bench], selected: String?) -> Pick {
        guard let query else {
            if let selected, let bench = benches.first(where: { $0.path == selected }) { return .found(bench) }
            return benches.count == 1 ? .found(benches[0]) : .none
        }
        if query.hasPrefix("/") || query.hasPrefix("~") {
            let wanted = normalize(query)
            guard let bench = benches.first(where: { normalize($0.path) == wanted }) else { return .notFound(query) }
            return .found(bench)
        }
        let named = benches.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
        switch named.count {
        case 0: return .notFound(query)
        case 1: return .found(named[0])
        default: return .ambiguous(query)
        }
    }

    private static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}
