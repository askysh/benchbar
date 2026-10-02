import SwiftUI

/// Focus apps (0.6): the apps the user works on. Doctor warns when an app
/// they need falls behind (`dependency_behind`), never about a focus app
/// itself; that warning reaches Health and the popover like any other
/// check. This file is the Apps page's part: the pin and the words.
nonisolated enum FocusPin: String, CaseIterable, Sendable, Identifiable {
    case auto, focus, ignore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .focus: "Focus"
        case .ignore: "Ignore"
        }
    }

    var help: String {
        switch self {
        case .auto: "Inferred: local changes, another branch than the profile's, or a commit of yours in the last 14 days"
        case .focus: "Always a focus app: doctor watches the apps it needs, never the app itself"
        case .ignore: "Never a focus app, even with local changes or recent commits of yours"
        }
    }

    /// The CLI words that set this pin for APP.
    func arguments(app: String) -> [String] {
        switch self {
        case .auto: ["app", "focus", app, "--auto"]
        case .focus: ["app", "focus", app]
        case .ignore: ["app", "unfocus", app]
        }
    }
}

extension AppInfo {
    /// The pin, `.auto` for an older CLI or an unknown word.
    nonisolated var pin: FocusPin { focusPin.flatMap(FocusPin.init(rawValue:)) ?? .auto }

    nonisolated var isFocus: Bool { focus ?? false }

    /// "your commit today, local changes"; nil when not a focus app.
    nonisolated var focusSummary: String? {
        guard isFocus else { return nil }
        let reasons = (focusReasons ?? []).joined(separator: ", ")
        return reasons.isEmpty ? "focus app" : "focus app: \(reasons)"
    }

    /// "needed by exponent_ecr, 30 commits / 12 days behind upstream/develop",
    /// only for a dependency of a focus app that is behind.
    nonisolated var dependencySummary: String? {
        guard !isFocus, let neededBy, !neededBy.isEmpty else { return nil }
        let who = "needed by \(neededBy.joined(separator: ", "))"
        guard let behind, behind > 0 else { return who }
        var words = "\(behind) commit\(behind == 1 ? "" : "s")"
        if let days = behindDays, days > 0 { words += " / \(days) day\(days == 1 ? "" : "s")" }
        return "\(who), \(words) behind \(upstream ?? "its remote")"
    }

    /// A dependency of a focus app that is behind its remote: doctor warns.
    nonisolated var isStaleDependency: Bool {
        !isFocus && !(neededBy ?? []).isEmpty && (behind ?? 0) > 0
    }
}

extension DoctorCheck {
    /// Identity in a list: `dependency_behind` appears once per stale
    /// dependency, so the id alone is not unique.
    nonisolated var rowKey: String { "\(id)\u{1F}\(message)" }
}

/// The "…" menu of one app row: install it on a site that lacks it, and
/// its focus pin (Auto, Focus, Ignore). Update stays a button beside it.
struct AppMenu: View {
    let app: AppInfo
    /// Sites without the app; empty hides the Install items.
    let missingSites: [String]
    let busy: Bool
    let install: (String) -> Void
    let setFocus: (FocusPin) -> Void

    var body: some View {
        MoreMenu(help: "Install \(app.name) on a site or change its focus") {
            if !missingSites.isEmpty {
                Section("Install") {
                    ForEach(missingSites, id: \.self) { site in
                        Button("Install on \(site)") { install(site) }
                    }
                }
            }
            Section(app.focus == nil ? "Focus (needs benchbar 0.6 or later)" : "Focus") {
                // an inline picker, so the menu checks the current pin: a
                // Label's checkmark image is not drawn in a menu
                Picker("Focus", selection: Binding(get: { app.pin }, set: setFocus)) {
                    ForEach(FocusPin.allCases) { pin in
                        Text(pin.title).tag(pin).help(pin.help)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(app.focus == nil)
            }
        }
        .disabled(busy)
    }
}
