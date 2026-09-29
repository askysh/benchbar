import Foundation

/// `benchbar://` links, for Raycast, Shortcuts and the like. Pure: a URL
/// and the bench list in, one action out, so the rules are tested without
/// the app.
///
/// Any web page can open a link like this, so only launches and start,
/// stop and restart are routes. Nothing here repairs, drops, restores,
/// pulls, installs or deletes; a route that is not in `Route` is ignored.
nonisolated enum URLRouter {
    static let scheme = "benchbar"

    enum Route: String, CaseIterable, Sendable {
        case up, down, restart, open, logs, window, doctor
    }

    /// A parsed link, before the bench is known.
    struct Request: Equatable, Sendable {
        var route: Route
        /// `bench=`: a name or an absolute path.
        var bench: String?
        /// `site=`: which site `open` opens.
        var site: String?
    }

    /// What the app should do.
    enum Outcome: Equatable, Sendable {
        /// Run the route on this bench (its path); `site` only for `open`.
        case run(Route, bench: String, site: String?)
        /// The window, with no bench in particular.
        case window
        /// The window, with a message: the bench or site was not found or
        /// not clear.
        case explain(String)
        /// Not a link for us, or a route we do not have: log it, do nothing.
        case ignore(String)
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
        guard let route = Route(rawValue: word) else { return .failure(.unknownRoute(word)) }
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
        case unknownRoute(String)

        var message: String {
            switch self {
            case .notOurScheme: return "not a benchbar:// link"
            case .unknownRoute(let word): return word.isEmpty ? "no route in the link" : "unknown route \"\(word)\""
            }
        }
    }

    /// The whole decision: parse, then pick the bench. `selected` is the
    /// bench the app has selected, if any.
    static func route(_ url: URL, benches: [Bench], selected: String?) -> Outcome {
        switch parse(url) {
        case .failure(let reason):
            return .ignore(reason.message)
        case .success(let request):
            return resolve(request, benches: benches, selected: selected)
        }
    }

    static func resolve(_ request: Request, benches: [Bench], selected: String?) -> Outcome {
        let bench: Bench
        switch pickBench(request.bench, benches: benches, selected: selected) {
        case .found(let found):
            bench = found
        case .none where request.route == .window:
            return .window
        case .none:
            return .explain(benches.isEmpty
                ? "BenchBar knows no bench yet, so the link has nothing to act on."
                : "More than one bench: add ?bench=NAME to the link to say which one.")
        case .notFound(let query):
            return .explain("No bench named \"\(query)\". The link uses the names and paths from benchbar list.")
        case .ambiguous(let query):
            return .explain("More than one bench is named \"\(query)\": use its full path in ?bench= instead.")
        }

        var site: String?
        if request.route == .open, let wanted = request.site {
            guard let match = bench.sites.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                return .explain("\(bench.name) has no site named \"\(wanted)\".")
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
