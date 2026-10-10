import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var store: BenchStore!
    private var statusItemController: StatusItemController!
    private var popover: PopoverController!
    private var mainWindow: MainWindowController!
    private var settingsWindow: SettingsWindowController!
    private var aboutWindow: AboutWindowController!
    private var wizard: WizardRun!
    private var logWindows: LogWindowController!
    private let launchAtLogin = LaunchAtLogin()
    private var notifier: Notifier!
    private let library = RunnerLibrary()
    private var updater: Updater?
    private var about: AboutModel!
    private var updateOffer: UpdateOffer!
    /// benchbar:// links that arrived before the bench list was loaded
    /// (a link can launch the app).
    private var pendingURLs: [URL] = []
    private var benchesLoaded = false
    private static let urlLog = Logger(subsystem: "com.akashmishra.benchbar", category: "url")

    /// Before launch finishes, so a link that launches the app is not lost.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // the tests run inside this app (TEST_HOST): no menu bar item, no CLI calls
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        // before the first CLI call: Homebrew's and the installer's
        // benchbar hand off to the CLI this link leads to
        AppCLILink.register()
        settings = AppSettings()
        store = BenchStore(settings: settings)
        statusItemController = StatusItemController(store: store, settings: settings, library: library)
        store.onChange = { [weak self] in self?.statusItemController.update() }

        notifier = Notifier(settings: settings)
        store.onAlert = { [weak self] bench, alert in self?.notifier.post(alert, bench: bench) }
        notifier.onOpen = { [weak self] path in self?.showPopover(for: path) }
        notifier.start()

        updateOffer = UpdateOffer(settings: settings)

        let commands = AppCommands(
            openSettings: { [weak self] in self?.openSettings() },
            quit: { NSApp.terminate(nil) },
            chooseCLI: { [weak self] in self?.chooseCLI() },
            scanFolder: { [weak self] in self?.scanFolderAction() },
            openLogs: { [weak self] bench in self?.openLogs(bench) },
            setup: { [weak self] bench, start in
                guard let self else { return }
                mainWindow.router.startAfterSetup = start
                mainWindow.router.setupRequest = bench.path
                openBench(bench, tab: .overview, repair: false)
            },
            addHosts: { [weak self] bench in
                guard let self else { return }
                mainWindow.router.hostsRequest = bench.path
                openBench(bench, tab: .sites, repair: false)
            },
            newBench: { [weak self] in self?.openWizard() },
            manage: { [weak self] bench, tab, repair in self?.openBench(bench, tab: tab, repair: repair) },
            updateOffer: updateOffer,
            update: { [weak self] in self?.updateNowAction() })
        popover = PopoverController(rootView: PopoverView(store: store, commands: commands))
        popover.onOpenChange = { [weak self] open in self?.store.setPopoverOpen(open) }

        let workbench = Workbench(store: store)
        about = AboutModel(store: store, offer: updateOffer)
        let discovery = BenchDiscovery(store: store)
        wizard = WizardRun(store: store)
        wizard.openFindBenches = { [weak self] in
            self?.mainWindow.router.scanRequested = true
            self?.mainWindow.show(.discovery)
        }
        wizard.tour = { [weak self] in self?.mainWindow.router.walkthroughRequested = true }
        wizard.leave = { [weak self] in
            // the first page's Esc: back to the first bench, when there is one
            guard let self, let first = store.benches.first else { return }
            mainWindow.show(.bench(first.path), tab: .overview)
        }
        wizard.finished = { [weak self] path in
            guard let self else { return }
            if let path, store.benches.contains(where: { $0.path == path }) {
                store.selectedPath = path
                mainWindow.show(.bench(path), tab: .overview)
            } else if let first = store.benches.first {
                mainWindow.show(.bench(first.path), tab: .overview)
            }
        }
        mainWindow = MainWindowController { [unowned self] router in
            MainWindowView(store: store, router: router, workbench: workbench, about: about, discovery: discovery,
                           wizard: WizardView(run: wizard, settings: settings, library: library,
                                              launchAtLogin: launchAtLogin, notifier: notifier),
                           settings: settings)
        }
        // open, close, occlusion and the page: the window's views stay alive
        // when it closes, so the store hears of them from the controller
        mainWindow.onSight = { [weak self] sight in self?.store.setWindow(sight) }

        settingsWindow = SettingsWindowController { [unowned self] tabs, router in
            let chooseCLI: () -> Void = { [weak self] in self?.chooseCLI() }
            return SettingsTabsView(
                tabs: tabs,
                general: SettingsView(settings: settings, store: store, library: library, launchAtLogin: launchAtLogin, notifier: notifier,
                                      part: .general, router: router, showsHeader: false, chooseCLI: chooseCLI),
                menuBar: SettingsView(settings: settings, store: store, library: library, launchAtLogin: launchAtLogin, notifier: notifier,
                                      part: .menuBar, router: router, showsHeader: false, chooseCLI: chooseCLI))
        }
        aboutWindow = AboutWindowController { [unowned self] router in
            AboutPane(store: store, model: about, router: router)
        }

        logWindows = LogWindowController { [weak self] path in self?.openLogsInTerminal(path) }

        if Updater.isAvailable { updater = Updater() }
        updateOffer.checkWithSparkle = { [weak self] in self?.updater?.checkForUpdates() }
        NSApp.mainMenu = makeMainMenu()
        setUpClicks()

        Task {
            await store.start()
            benchesLoaded = true
            let waiting = pendingURLs
            pendingURLs = []
            waiting.forEach(handle)
            askForCLIOnce()
            updateOffer.startAutomaticChecks()
        }
    }

    // MARK: status item clicks

    /// Left click toggles the popover; right click (or control click) shows a small menu.
    private func setUpClicks() {
        guard let button = statusItemController.statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover.close()
            // assigning a menu for one click shows it the standard way
            statusItemController.statusItem.menu = makeStatusMenu()
            sender.performClick(nil)
            statusItemController.statusItem.menu = nil
        } else {
            popover.toggle(from: sender)
        }
    }

    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        if let version = updateOffer?.version {
            menu.addItem(withTitle: "Update to \(version)…", action: #selector(updateNowAction), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Open BenchBar", action: #selector(openWindowAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Scan Folder…", action: #selector(scanFolderAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "About BenchBar", action: #selector(openAboutAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Documentation", action: #selector(openDocsAction), keyEquivalent: "").target = self
        if let item = updater?.menuItem() { menu.addItem(item) }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit BenchBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    // MARK: commands

    /// A notification was clicked: show that bench in the popover.
    private func showPopover(for path: String) {
        if store.benches.contains(where: { $0.path == path }) {
            store.selectedPath = path
        }
        guard let button = statusItemController.statusItem.button else { return }
        if !popover.isShown { popover.show(from: button) }
    }

    @objc private func openSettingsAction() { openSettings() }

    @objc private func openWindowAction() { openMainWindow() }

    @objc private func scanFolderAction() {
        popover.close()
        mainWindow.router.scanRequested = true
        mainWindow.show(.discovery)
    }

    // MARK: benchbar:// links

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text) else { return }
        if benchesLoaded { handle(url) } else { pendingURLs.append(url) }
    }

    /// One link: URLRouter decides, this only carries it out. Every route is
    /// a launch or start, stop, restart; nothing that deletes.
    private func handle(_ url: URL) {
        let benches = store.benches.map {
            URLRouter.Bench(path: $0.path, name: $0.name, sites: $0.siteRows.map(\.name))
        }
        let link = String(url.absoluteString.prefix(300))
        switch URLRouter.route(url, benches: benches, selected: store.selectedPath) {
        case .ignore(let reason):
            Self.urlLog.notice("Ignored \(link, privacy: .public): \(reason, privacy: .public)")
        case .window:
            openMainWindow()
        case .profile(let link):
            Self.urlLog.info("profile link: Team Profiles, sheet prefilled")
            mainWindow.router.profileRequest = link
            mainWindow.show(.profiles)
        case .explain(let message):
            Self.urlLog.notice("\(link, privacy: .public): \(message, privacy: .public)")
            mainWindow.router.notice = message
            openMainWindow()
        case .run(let route, let path, let site):
            guard let bench = store.benches.first(where: { $0.path == path }) else { return }
            Self.urlLog.info("\(route.rawValue, privacy: .public) on \(bench.name, privacy: .public)")
            switch route {
            case .up: Task { await store.perform(.up, on: bench) }
            case .down: Task { await store.perform(.down, on: bench) }
            case .restart: Task { await store.perform(.restart, on: bench) }
            case .open:
                if let site, let row = bench.siteRows.first(where: { $0.name == site }) {
                    Workspace.open(row.url)
                } else {
                    Workspace.openSite(bench)
                }
            case .logs: openLogs(bench)
            case .window: openBench(bench, tab: .overview, repair: false)
            case .doctor:
                openBench(bench, tab: .health, repair: false)
                Task { await store.runDoctor(on: bench) }
            case .console, .db:
                Workspace.openShell(route == .console ? .console : .db, site: site ?? bench.summary.site, bench: bench, store: store)
            case .editor:
                if let editor = settings.editor {
                    Workspace.openInEditor(bench, editor: editor)
                } else {
                    mainWindow.router.notice = "Neither VS Code nor Cursor is installed, so there is no editor to open \(bench.name) in."
                    openMainWindow()
                }
            }
        }
    }

    // MARK: About and Help

    @objc private func openAboutAction() {
        popover.close()
        aboutWindow.show()
    }

    /// The app menu's Check for Updates in a build without Sparkle: the
    /// About pane shows the answer.
    @objc private func checkForUpdatesAction() {
        aboutWindow.router.updateCheckRequested = true
        openAboutAction()
    }

    /// "Update to X…": what happens, then Update Now, Copy Command or Release Notes.
    @objc private func updateNowAction() {
        popover.close()
        updateOffer.confirmFromMenu()
    }

    @objc private func openDocsAction() { NSWorkspace.shared.open(BenchBarLinks.docs) }
    @objc private func openReleaseNotesAction() { NSWorkspace.shared.open(BenchBarLinks.changelog) }

    @objc private func showShortcutsAction() {
        popover.close()
        settingsWindow.router.scrollTarget = SettingsView.shortcutsID
        settingsWindow.show(.general)
    }

    @objc private func showWalkthroughAction() {
        mainWindow.router.walkthroughRequested = true
        openMainWindow()
    }

    @objc private func reportBugAction() {
        aboutWindow.router.bugReportRequested = true
        openAboutAction()
    }

    /// Opening BenchBar again (Finder, Spotlight, the Dock while a window is
    /// open) shows the window: a menu bar app has nothing else to show.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainWindow() }
        return true
    }

    /// Settings (⌘,): the compact window with General and Menu Bar.
    private func openSettings() {
        popover.close()
        settingsWindow.show()
    }

    /// The BenchBar window where it was: the wizard on a Mac without a
    /// bench, else a bench.
    private func openMainWindow() {
        popover.close()
        mainWindow.show()
    }

    /// The first run wizard (the popover's empty state).
    private func openWizard() {
        popover.close()
        wizard.reopen()
        mainWindow.show(.wizard)
    }

    /// The BenchBar window at one bench's tab (from the popover).
    private func openBench(_ bench: BenchModel, tab: BenchTab, repair: Bool) {
        popover.close()
        mainWindow.show(.bench(bench.path), tab: tab, repair: repair)
    }


    private func chooseCLI() {
        popover.close()
        guard let path = Workspace.chooseCLI() else { return }
        Task { await store.useCLI(path: path) }
    }

    /// ⌘L: the log window. "Open in Terminal" in its toolbar is the old path.
    private func openLogs(_ bench: BenchModel) {
        popover.close()
        logWindows.show(benchName: bench.name, benchPath: bench.path)
    }

    private func openLogsInTerminal(_ path: String) {
        guard case .ready(let cli) = store.cli, let bench = store.benches.first(where: { $0.path == path }) else { return }
        do {
            try Workspace.openLogs(bench, cli: cli)
        } catch {
            bench.lastError = "Could not open the logs: \(error.localizedDescription)"
        }
    }

    /// The brief: when the CLI is not in any known place, ask once with a
    /// file picker. After that, Settings has the Choose button.
    private func askForCLIOnce() {
        guard case .missing(.notFound) = store.cli, !settings.askedForCLI else { return }
        settings.askedForCLI = true
        chooseCLI()
    }

    // MARK: main menu

    /// Only visible while Settings is open (the app is .regular then), but
    /// it is what makes ⌘W, ⌘Q and copy and paste work in that window.
    func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About BenchBar", action: #selector(openAboutAction), keyEquivalent: "").target = self
        if let item = updater?.menuItem() {
            appMenu.addItem(item)
        } else {
            appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdatesAction), keyEquivalent: "").target = self
        }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit BenchBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "BenchBar"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "Edit"))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window

        // Help last: macOS adds its search field to the menu set as helpMenu
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "BenchBar Documentation", action: #selector(openDocsAction), keyEquivalent: "?").target = self
        help.addItem(withTitle: "Keyboard Shortcuts", action: #selector(showShortcutsAction), keyEquivalent: "").target = self
        help.addItem(withTitle: "Show Walkthrough", action: #selector(showWalkthroughAction), keyEquivalent: "").target = self
        help.addItem(.separator())
        help.addItem(withTitle: "Release Notes", action: #selector(openReleaseNotesAction), keyEquivalent: "").target = self
        help.addItem(withTitle: "Report a Bug…", action: #selector(reportBugAction), keyEquivalent: "").target = self
        main.addItem(submenu(help, title: "Help"))
        NSApp.helpMenu = help
        return main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
