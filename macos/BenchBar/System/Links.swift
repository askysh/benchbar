import Foundation

/// Every web address the app opens: the docs site, the repository, and the
/// prefilled bug report. The docs paths match the site's pages and the
/// topics of `benchbar docs`.
nonisolated enum BenchBarLinks {
    static let docs = URL(string: "https://benchbar.akashmishra.com/")!
    static let install = docs.appending(path: "install/")
    static let appGuide = docs.appending(path: "app/")
    static let troubleshooting = docs.appending(path: "troubleshooting/")

    static let repository = URL(string: "https://github.com/askysh/benchbar")!
    static let releases = URL(string: "https://github.com/askysh/benchbar/releases")!
    static let changelog = URL(string: "https://github.com/askysh/benchbar/blob/main/CHANGELOG.md")!
    static let license = URL(string: "https://github.com/askysh/benchbar/blob/main/LICENSE")!

    /// The doctor guide's section for one check id (underscores kept).
    static func doctorCheck(_ id: String) -> URL {
        var parts = URLComponents(url: docs.appending(path: "guides/doctor-and-repair/"), resolvingAgainstBaseURL: false)!
        parts.fragment = id
        return parts.url!
    }

    /// A new issue from the bug report form, with the versions filled in.
    /// GitHub issue forms take a query parameter per field id; the ids are
    /// `macos` and `version` in `.github/ISSUE_TEMPLATE/bug_report.yml`.
    static func newBugReport(macOS: String, app: String, cli: String?) -> URL {
        var parts = URLComponents(url: repository.appending(path: "issues/new"), resolvingAgainstBaseURL: false)!
        var benchbar = "BenchBar \(app)"
        if let cli, !cli.isEmpty { benchbar += ", \(cli)" }
        parts.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "macos", value: macOS),
            URLQueryItem(name: "version", value: benchbar),
        ]
        return parts.url!
    }

    // MARK: this copy of the app

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// "macOS 27.0 (26A123)", as in About This Mac.
    static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let number = v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        let full = ProcessInfo.processInfo.operatingSystemVersionString
        if let open = full.range(of: "(Build "), let close = full.range(of: ")", range: open.upperBound..<full.endIndex) {
            return "macOS \(number) (\(full[open.upperBound..<close.lowerBound]))"
        }
        return "macOS \(number)"
    }
}
