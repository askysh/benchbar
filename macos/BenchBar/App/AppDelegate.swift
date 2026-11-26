import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var store: BenchStore!
    private var statusItemController: StatusItemController!
    private var popover: PopoverController!
    private var mainWindow: MainWindowController!
    private var lanRoomsObservation: Labs.ObservationToken?
    private var wizard: WizardRun!
    private var logWindows: LogWindowController!
    private let launchAtLogin = LaunchAtLogin()
    private var notifier: Notifier!
    private let library = RunnerLibrary()
    private var updater: Updater?
    private var about: AboutModel!
    private var updateOffer: UpdateOffer!
    private var quickSwitch: QuickSwitchController!
    /// The guest side of rooms; filled only while the lan-rooms lab is on.
    private let guestSlot = GuestSlot.shared
    private var guest: GuestRoomStore? { guestSlot.store }
    /// benchbar:// links that arrived before the bench list was loaded
    /// (a link can launch the app).
    private var pendingURLs: [URL] = []
    /// "Quit when it finishes", chosen in the quit alert while a change ran.
    private let quitCoordinator = QuitCoordinator()
    private var benchesLoaded = false

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
        // one window, no tabs: the Window menu offered Merge All Windows, Show Tab Bar and more
        NSWindow.allowsAutomaticWindowTabbing = false
        settings = AppSettings()
        store = BenchStore(settings: settings)
        statusItemController = StatusItemController(store: store, settings: settings, library: library)
        store.onChange = { [weak self] in self?.statusItemController.update() }
        store.onIdle = { [weak self] in self?.quitIfWaiting() }
        let labsStore = store!
        Labs.shared.loader = .cli { await MainActor.run { labsStore.cliClient } }
        lanRoomsObservation = Labs.shared.observe(.lanRooms) { [weak self] on in self?.lanRoomsChanged(on) }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.store.appBecameActive()
                Labs.shared.refreshIfStale()
            }
        }

        notifier = Notifier(settings: settings)
        ShareNotices.notifier = notifier
        store.onAlert = { [weak self] bench, alert in self?.notifier.post(alert, bench: bench) }
        ShareCenter.shared.attach(store)
        store.confirmWhileSharing = { action, bench in
            guard Labs.shared.isOn(.lanRooms), let line = HostAmbient.benchConfirm(ShareCenter.shared.stores[bench.path]?.status, restart: action == .restart) else { return true }
            return ShareConfirm.ask(action == .restart ? "Restart \(bench.name)?" : "Stop \(bench.name)?", detail: line,
                                    button: action == .restart ? "Restart" : "Stop")
        }
        ShareCenter.shared.onIconChange = { [weak self] icon in
            self?.statusItemController.setShareIcon(Labs.shared.isOn(.lanRooms) ? icon : .off)
        }
        ShareCenter.shared.onEvent = { share, event in
            guard Labs.shared.isOn(.lanRooms), let notice = HostAmbient.notice(event, bench: share.bench) else { return }
            ShareNotices.post(title: notice.title, body: notice.body, bench: share.bench, identifier: notice.identifier)
        }
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
            findUser: { [weak self] bench, site in
                guard let self else { return }
                mainWindow.router.findUserRequest = FindUserRequest(bench: bench.path, site: site)
                openBench(bench, tab: .sites, repair: false)
            },
            newBench: { [weak self] in self?.openWizard() },
            manage: { [weak self] bench, tab, repair in self?.openBench(bench, tab: tab, repair: repair) },
            updateOffer: updateOffer,
            update: { [weak self] in self?.updateNowAction() },
            openNetwork: { [weak self] in
                guard let self else { return }
                popover.close()
                mainWindow.show(.network)
            })
        popover = PopoverController(rootView: PopoverView(store: store, commands: commands, guest: guestSlot))
        popover.onOpenChange = { [weak self] open in
            guard let self else { return }
            store.setPopoverOpen(open)
            if open { Labs.shared.refreshIfStale() }
            // Rooms are browsed only while the popover is open, and never before the pane's
            // explanation, so the Local Network prompt does not appear at an odd time.
            if open && Labs.shared.isOn(.lanRooms) && UserDefaults.standard.bool(forKey: NetworkPanePresentation.explainedKey) {
                guest?.startBrowsing(for: .popover)
            } else if !open {
                guest?.stopBrowsing(for: .popover)
            }
        }

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
            // the first page's Cancel: back to the page that was showing, else the first bench
            guard let self else { return }
            let router = mainWindow.router
            if let back = router.wizardReturn, let pane = back.pane, pane != .wizard {
                var stillThere = true
                if case .bench(let path) = pane { stillThere = store.benches.contains { $0.path == path } }
                if stillThere {
                    mainWindow.show(pane, tab: back.tab)
                    return
                }
            }
            if let first = store.benches.first { mainWindow.show(.bench(first.path), tab: .overview) }
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
                                              launchAtLogin: launchAtLogin, notifier: notifier, bugReport: about.bugReport),
                           settings: settings,
                           makeSettings: { [unowned self] part in
                               SettingsView(settings: settings, store: store, library: library, launchAtLogin: launchAtLogin,
                                            notifier: notifier, part: part, router: router,
                                            chooseCLI: { [weak self] in self?.chooseCLI() })
                           },
                           guest: guestSlot)
        }
        // open, close, occlusion and the page: the window's views stay alive
        // when it closes, so the store hears of them from the controller
        mainWindow.onKey = { Task { await Labs.shared.refresh() } }
        mainWindow.onSight = { [weak self] sight in self?.store.setWindow(sight) }

        logWindows = LogWindowController(client: { [weak self] in self?.store.cliClient }) { [weak self] path in self?.openLogsInTerminal(path) }

        if Updater.isAvailable { updater = Updater() }
        updateOffer.checkWithSparkle = { [weak self] in self?.updater?.checkForUpdates() }
        NSApp.mainMenu = makeMainMenu()
        setUpClicks()

        // the key is registered when the CLI says the lab is on (Labs.refresh below), never before
        quickSwitch = QuickSwitchController(store: store, labs: Labs.shared)
        Labs.shared.observe(.quickSwitch) { [weak self] _ in self?.quickSwitch.sync() }

        Task {
            await store.start()
            // the lab's flip restores a share that was on at the last quit (lanRoomsChanged)
            await Labs.shared.refresh()
            benchesLoaded = true
            let waiting = pendingURLs
            pendingURLs = []
            waiting.forEach(handle)
            // a menu bar icon alone says nothing to someone who just
            // installed BenchBar: no bench, the window opens on the wizard
            // (unless a link launched the app and said where to go)
            if store.hasNoBench && waiting.isEmpty { openWizard() }
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
        AppMenus.statusMenu(target: self, actions: menuActions, updateVersion: updateOffer?.version, updaterItem: updater?.menuItem())
    }

    /// The selectors the menus send to this object (`AppMenus`).
    private var menuActions: AppMenus.Actions {
        AppMenus.Actions(update: #selector(updateNowAction), openWindow: #selector(openWindowAction),
                         scanFolder: #selector(scanFolderAction), openSettings: #selector(openSettingsAction),
                         openAbout: #selector(openAboutAction), openDocs: #selector(openDocsAction),
                         checkForUpdates: #selector(checkForUpdatesAction),
                         openMenuBarSettings: #selector(openMenuBarSettingsAction),
                         showShortcuts: #selector(showShortcutsAction), showWalkthrough: #selector(showWalkthroughAction),
                         openWhatsNew: #selector(openWhatsNewAction), reportBug: #selector(reportBugAction))
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

    @objc private func openMenuBarSettingsAction() {
        popover.close()
        mainWindow.show(.menuBar)
    }

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

    /// One link: `LinkHandler` decides and acts through `AppLinkEffects`.
    private func handle(_ url: URL) {
        let effects = AppLinkEffects(store: store, settings: settings, mainWindow: mainWindow, popover: popover,
                                     logWindows: logWindows, guestSlot: guestSlot)
        Task { await LinkHandler.handle(url, effects: effects) }
    }

    // MARK: About and Help

    @objc private func openAboutAction() {
        popover.close()
        mainWindow.show(.about)
    }

    /// The app menu's Check for Updates in a build without Sparkle: the
    /// About pane shows the answer.
    @objc private func checkForUpdatesAction() {
        mainWindow.router.updateCheckRequested = true
        openAboutAction()
    }

    /// "Update to X…": what happens, then Update Now, Copy Command or Release Notes.
    @objc private func updateNowAction() {
        popover.close()
        updateOffer.confirmFromMenu()
    }

    @objc private func openDocsAction() { NSWorkspace.shared.open(BenchBarLinks.docs) }
    @objc private func openWhatsNewAction() { NSWorkspace.shared.open(BenchBarLinks.whatsNew) }

    @objc private func showShortcutsAction() {
        popover.close()
        mainWindow.router.scrollTarget = SettingsView.shortcutsID
        mainWindow.show(.general)
    }

    @objc private func showWalkthroughAction() {
        mainWindow.router.walkthroughRequested = true
        openMainWindow()
    }

    @objc private func reportBugAction() {
        mainWindow.router.bugReportRequested = true
        openAboutAction()
    }

    /// Quitting while a change runs (an install, a repair, an app update, a
    /// site change, a start or stop) ends the CLI's pipe, and the CLI's next
    /// write ends it halfway: the bench is left half installed or half
    /// migrated. So ask, and offer to quit when it has finished. Keep
    /// running is the default. It also kills a running share setup or
    /// teardown (the copy is left half made), drops the people in a room this
    /// Mac hosts and closes the forwarder to a room it joined: those ask
    /// too, and Quit anyway is theirs (`QuitPolicy`).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch quitCoordinator.reply(in: self) {
        case .terminateNow: return .terminateNow
        case .terminateCancel: return .terminateCancel
        }
    }

    /// The store has nothing running: the quit the person asked to wait for.
    private func quitIfWaiting() {
        guard quitCoordinator.storeIsIdle(changeRunning: store.runningChangeLabel != nil) else { return }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// The lan-rooms lab flipped, live: on makes the guest store and restores a share that was on at
    /// the last quit; off closes everything the lab started (the CLI's `labs off` already stopped a
    /// running share) and leaves a pane that is gone.
    private func lanRoomsChanged(_ on: Bool) {
        if on {
            if guestSlot.store == nil {
                let browser = BrowserRouter.shared
                guestSlot.store = GuestRoomStore(dependencies: .live(identity: KeychainIdentity(), openURL: { browser.open($0) }))
            }
            ShareCenter.shared.restoreActive(among: store.benches.map(\.path))
        } else {
            guestSlot.store?.shutDown()
            guestSlot.store = nil
            ShareCenter.shared.tearDown()
            statusItemController.setShareIcon(.off)
            let router = mainWindow.router
            if router.pane == .network { router.pane = .general }
            if router.benchTab == .sharing { router.benchTab = .overview }
        }
    }

    /// Opening BenchBar again (Finder, Spotlight, the Dock while a window is
    /// open) shows the window: a menu bar app has nothing else to show.
    /// A log window on screen does not count: `hasVisibleWindows` is true
    /// for it, and the BenchBar window stayed closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !mainWindow.isVisible { openMainWindow() }
        return true
    }

    /// Settings (⌘,): the BenchBar window on General.
    private func openSettings() {
        popover.close()
        mainWindow.show(.general)
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

    /// The main menu (AppMenus.mainMenu).
    func makeMainMenu() -> NSMenu {
        AppMenus.mainMenu(target: self, actions: menuActions, updaterItem: updater?.menuItem())
    }
}

extension AppDelegate: QuitEnvironment {
    func quitFacts() -> QuitPolicy.Facts {
        let hosted = ShareCenter.shared.benchesWithGuests.first
        return QuitPolicy.Facts(labOn: Labs.shared.isOn(.lanRooms), setupRunning: ShareCenter.shared.setupOrTeardownRunning,
                                hostedBench: hosted?.bench, people: hosted?.status?.people ?? 0,
                                guestForwarder: guest?.hasRunningForwarder == true,
                                changeRunning: store.runningChangeLabel)
    }

    func confirmQuit(_ question: QuitPolicy.Question) -> Bool {
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.detail
        alert.addButton(withTitle: "Keep running")
        alert.addButton(withTitle: question.canWaitForIt ? "Quit when it finishes" : "Quit anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
