import AppKit

/// `LinkEffects` for the running app: the window, the store and the system.
final class AppLinkEffects: LinkEffects {
    private let store: BenchStore
    private let settings: AppSettings
    private let mainWindow: MainWindowController
    private let popover: PopoverController
    private let logWindows: LogWindowController
    private let guestSlot: GuestSlot

    init(store: BenchStore, settings: AppSettings, mainWindow: MainWindowController,
         popover: PopoverController, logWindows: LogWindowController, guestSlot: GuestSlot) {
        self.store = store
        self.settings = settings
        self.mainWindow = mainWindow
        self.popover = popover
        self.logWindows = logWindows
        self.guestSlot = guestSlot
    }

    var routerBenches: [URLRouter.Bench] {
        store.benches.map { URLRouter.Bench(path: $0.path, name: $0.name, sites: $0.siteRows.map(\.name)) }
    }
    var selectedPath: String? { store.selectedPath }
    var lanRoomsOn: Bool { Labs.shared.isOn(.lanRooms) }
    var confirmLinkActions: Bool { settings.confirmLinkActions }

    private func model(at path: String) -> BenchModel? { store.benches.first { $0.path == path } }
    func benchName(at path: String) -> String? { model(at: path)?.name }

    func confirm(_ question: LinkConfirm.Question) -> Bool {
        ShareConfirm.ask(question.title, detail: question.detail, button: question.button, cancelIsDefault: true)
    }

    func showWindow() {
        popover.close()
        mainWindow.show()
    }
    func showNetwork() { mainWindow.show(.network) }
    func showProfiles(_ link: URLRouter.ProfileLink) {
        mainWindow.router.profileRequest = link
        mainWindow.show(.profiles)
    }
    func showNotice(_ message: String) {
        mainWindow.router.notice = message
        showWindow()
    }
    func openShare(_ target: ShareDeepLink.Target) async -> Bool {
        await guestSlot.store?.open(link: target) ?? false
    }
    func prefillInvite(_ invite: Result<ShareInvite, ShareInvite.Problem>) {
        guestSlot.store?.open(invite: invite)
    }

    func start(_ path: String) {
        guard let bench = model(at: path) else { return }
        Task { [store] in await store.perform(.up, on: bench) }
    }
    func stop(_ path: String, fromLink: Bool) {
        guard let bench = model(at: path) else { return }
        Task { [store] in await store.perform(.down, on: bench, fromLink: fromLink) }
    }
    func restart(_ path: String, fromLink: Bool) {
        guard let bench = model(at: path) else { return }
        Task { [store] in await store.perform(.restart, on: bench, fromLink: fromLink) }
    }
    func openSite(_ path: String, site: String?) {
        guard let bench = model(at: path) else { return }
        if let site, let row = bench.siteRows.first(where: { $0.name == site }) {
            Workspace.open(row.url)
        } else {
            Workspace.openSite(bench)
        }
    }
    func openLogs(_ path: String) {
        guard let bench = model(at: path) else { return }
        popover.close()
        logWindows.show(benchName: bench.name, benchPath: bench.path)
    }
    func openBenchWindow(_ path: String) { open(path, tab: .overview) }
    func runDoctor(_ path: String) {
        guard let bench = model(at: path) else { return }
        open(path, tab: .health)
        Task { [store] in await store.runDoctor(on: bench) }
    }
    func openShell(_ kind: TerminalScript.Kind, bench path: String, site: String?) {
        guard let bench = model(at: path) else { return }
        Workspace.openShell(kind, site: site ?? bench.summary.site, bench: bench, store: store)
    }
    func openEditor(_ path: String) {
        guard let bench = model(at: path) else { return }
        if let editor = settings.editor {
            Workspace.openInEditor(bench, editor: editor)
        } else {
            showNotice("Neither VS Code nor Cursor is installed, so there is no editor to open \(bench.name) in.")
        }
    }

    private func open(_ path: String, tab: BenchTab) {
        popover.close()
        mainWindow.show(.bench(path), tab: tab, repair: false)
    }
}
