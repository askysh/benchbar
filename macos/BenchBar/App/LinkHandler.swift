import Foundation
import os

/// What a `benchbar://` link can make the app do, as the smallest set of effects. The routing
/// (`URLRouter`) and the order of the rules (log, confirm, act) live in `LinkHandler`; this is
/// only the part that touches the window, the store and the system, so a test can stand in
/// for it. Benches are named by path: the effects find the bench themselves.
protocol LinkEffects: AnyObject {
    // what the router needs
    var routerBenches: [URLRouter.Bench] { get }
    var selectedPath: String? { get }
    var lanRoomsOn: Bool { get }
    /// Settings, "Ask before a link acts".
    var confirmLinkActions: Bool { get }
    /// nil when no bench has this path any more.
    func benchName(at path: String) -> String?

    // asking and showing
    /// The question's alert; true when the person confirmed.
    func confirm(_ question: LinkConfirm.Question) -> Bool
    func showWindow()
    func showNetwork()
    func showProfiles(_ link: URLRouter.ProfileLink)
    /// A message in the window, which opens.
    func showNotice(_ message: String)
    /// A joined room's page; false when the room is not known (nothing is joined by a link).
    func openShare(_ target: ShareDeepLink.Target) async -> Bool
    func prefillInvite(_ invite: Result<ShareInvite, ShareInvite.Problem>)

    // acting on one bench
    func start(_ path: String)
    /// `fromLink`: the room confirm is skipped when the link's own alert already asked.
    func stop(_ path: String, fromLink: Bool)
    func restart(_ path: String, fromLink: Bool)
    /// The named site if the bench has it, else the bench's own site.
    func openSite(_ path: String, site: String?)
    func openLogs(_ path: String)
    func openBenchWindow(_ path: String)
    /// The Health tab, and a doctor run.
    func runDoctor(_ path: String)
    func openShell(_ kind: TerminalScript.Kind, bench path: String, site: String?)
    /// The editor, or a notice when there is none.
    func openEditor(_ path: String)
}

/// One link: `URLRouter` decides, this carries it out through `LinkEffects`. Every route is a
/// launch or start, stop, restart; nothing that deletes.
@MainActor
enum LinkHandler {
    private static let log = Logger(subsystem: "com.akashmishra.benchbar", category: "url")

    static func handle(_ url: URL, effects: some LinkEffects) async {
        // a link can carry a room code or a profile token: only its scheme and action are logged (MAC-10)
        let link = URLRouter.logLabel(url)
        let outcome = URLRouter.route(url, benches: effects.routerBenches, selected: effects.selectedPath,
                                      lanRooms: effects.lanRoomsOn)
        // the log line is built from fixed texts and the short label only: never a host, path, query or bench name
        if let line = URLRouter.rejectionLogLine(link: link, outcome: outcome) {
            log.notice("\(line, privacy: .public)")
        }
        switch outcome {
        case .ignore:
            break
        case .window:
            effects.showWindow()
        case .share(let target):
            log.info("share link: a joined room's page")
            // an unknown room only shows the pane; a link never joins (U3)
            if !(await effects.openShare(target)) { effects.showNetwork() }
        case .shareInvite(let invite):
            log.info("share invite link: the join sheet, waiting for a click")
            effects.prefillInvite(invite)
            effects.showNetwork()
        case .profile(let profile):
            log.info("profile link: Team Profiles, sheet prefilled")
            effects.showProfiles(profile)
        case .explain(let message, _):
            effects.showNotice(message)
        case .run(let route, let path, let site):
            run(route, on: path, site: site, effects: effects)
        }
    }

    private static func run(_ route: URLRouter.Route, on path: String, site: String?, effects: some LinkEffects) {
        guard let name = effects.benchName(at: path) else { return }
        if LinkConfirm.needsAsking(route, setting: effects.confirmLinkActions) {
            let question = LinkConfirm.question(route, bench: name)
            guard effects.confirm(question) else {
                log.info("\(route.rawValue, privacy: .public) on \(name, privacy: .public): not confirmed")
                return
            }
        }
        log.info("\(route.rawValue, privacy: .public) on \(name, privacy: .public)")
        // with the confirm setting on, the alert above came first and the room confirm still follows
        let fromLink = !effects.confirmLinkActions
        switch route {
        case .up: effects.start(path)
        case .down: effects.stop(path, fromLink: fromLink)
        case .restart: effects.restart(path, fromLink: fromLink)
        case .open: effects.openSite(path, site: site)
        case .logs: effects.openLogs(path)
        case .window: effects.openBenchWindow(path)
        case .doctor: effects.runDoctor(path)
        case .console: effects.openShell(.console, bench: path, site: site)
        case .db: effects.openShell(.db, bench: path, site: site)
        case .editor: effects.openEditor(path)
        }
    }
}
