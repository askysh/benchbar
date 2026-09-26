import Foundation
import Observation

/// A version like "0.5.0", "v0.6.0" or "0.6.0-beta.1", compared the way
/// people read them: numbers part by part (so 0.10 is newer than 0.9), a
/// missing part counts as 0, and a prerelease comes before its release.
nonisolated struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    let numbers: [Int]
    /// "beta.1" for "0.6.0-beta.1", nil for a release.
    let prerelease: String?

    init?(_ text: String) {
        var core = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if core.first == "v" || core.first == "V" { core.removeFirst() }
        // build metadata ("+abc") never changes the order
        if let plus = core.firstIndex(of: "+") { core = String(core[..<plus]) }
        var pre: String?
        if let dash = core.firstIndex(of: "-") {
            pre = String(core[core.index(after: dash)...])
            core = String(core[..<dash])
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let n = Int(part), n >= 0 else { return nil }
            numbers.append(n)
        }
        self.numbers = numbers
        self.prerelease = (pre?.isEmpty ?? true) ? nil : pre
    }

    var description: String {
        numbers.map(String.init).joined(separator: ".") + (prerelease.map { "-\($0)" } ?? "")
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool {
        !(a < b) && !(b < a)
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        let count = max(a.numbers.count, b.numbers.count)
        for i in 0..<count {
            let x = i < a.numbers.count ? a.numbers[i] : 0
            let y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case (let p?, let q?): return p.compare(q, options: .numeric) == .orderedAscending
        }
    }
}

/// What the check found.
nonisolated enum UpdateStatus: Equatable, Sendable {
    /// The latest release is this version or older.
    case upToDate(latest: String)
    /// A newer release, and its page on GitHub.
    case available(version: String, page: URL)
}

nonisolated enum UpdateCheckError: Error, Equatable, Sendable, LocalizedError {
    case network(String)
    case http(Int)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .network(let message): "Could not reach GitHub: \(message)"
        case .http(403), .http(429): "GitHub is rate limiting this Mac; try again in a while."
        case .http(404): "GitHub has no published release yet."
        case .http(let code): "GitHub answered HTTP \(code)."
        case .unreadable: "GitHub's answer could not be read."
        }
    }
}

/// Asks GitHub for the latest release, only when the person clicks. No
/// download, no background checks: BenchBar is unsigned until 0.6, so an
/// update is the person's own download from the release page.
nonisolated enum UpdateCheck {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/askysh/benchbar/releases/latest")!
    static let timeout: TimeInterval = 10

    /// The fields of GitHub's release JSON this needs.
    struct Release: Decodable, Sendable {
        let tagName: String
        let htmlURL: URL?
        let draft: Bool?
        let prerelease: Bool?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft, prerelease
        }
    }

    /// Reads GitHub's answer and compares it with the running version.
    static func parse(_ data: Data, current: String) throws(UpdateCheckError) -> UpdateStatus {
        let release: Release
        do { release = try JSONDecoder().decode(Release.self, from: data) } catch { throw .unreadable }
        guard let latest = AppVersion(release.tagName) else { throw .unreadable }
        let page = release.htmlURL ?? BenchBarLinks.releases
        if let mine = AppVersion(current), mine < latest {
            return .available(version: latest.description, page: page)
        }
        // a version that does not parse (a local build) is never told to update
        return .upToDate(latest: latest.description)
    }

    /// GET with a User-Agent (GitHub's API refuses requests without one)
    /// and a 10 second limit, from an ephemeral session: no cookies, no cache.
    static func request(appVersion: String) -> URLRequest {
        var request = URLRequest(url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("BenchBar/\(appVersion) (+https://github.com/askysh/benchbar)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    typealias Fetch = @Sendable (URLRequest) async throws(UpdateCheckError) -> Data

    static let liveFetch: Fetch = { request throws(UpdateCheckError) in
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw .http(http.statusCode) }
        return data
    }
}

/// The About pane's "Check for Updates" button and what it shows.
@Observable
final class UpdateChecker {
    enum State: Equatable {
        case idle
        case checking
        case done(UpdateStatus)
        case failed(String)
    }

    private(set) var state: State = .idle
    let currentVersion: String
    @ObservationIgnored private let fetch: UpdateCheck.Fetch

    init(currentVersion: String = BenchBarLinks.appVersion, fetch: @escaping UpdateCheck.Fetch = UpdateCheck.liveFetch) {
        self.currentVersion = currentVersion
        self.fetch = fetch
    }

    func check() async {
        guard state != .checking else { return }
        state = .checking
        do throws(UpdateCheckError) {
            let data = try await fetch(UpdateCheck.request(appVersion: currentVersion))
            state = .done(try UpdateCheck.parse(data, current: currentVersion))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
