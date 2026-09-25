import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var store: BenchStore!
    private var statusItemController: StatusItemController!
    private var popover: PopoverController!
    private var settingsWindow: SettingsWindowController!
    private var logWindows: LogWindowController!
    private let launchAtLogin = LaunchAtLogin()
    private var notifier: Notifier!
    private let library = RunnerLibrary()
    private var updater: Updater?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // the tests run inside this app (TEST_HOST): no menu bar item, no CLI calls
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        settings = AppSettings()
        store = BenchStore(settings: settings)
        statusItemController = StatusItemController(store: store, settings: settings, library: library)
        store.onChange = { [weak self] in self?.statusItemController.update() }

        notifier = Notifier(settings: settings)
        store.onAlert = { [weak self] bench, alert in self?.notifier.post(alert, bench: bench) }
        notifier.onOpen = { [weak self] path in self?.showPopover(for: path) }
        notifier.start()

        let commands = AppCommands(
            openSettings: { [weak self] in self?.openSettings() },
            quit: { NSApp.terminate(nil) },
            chooseCLI: { [weak self] in self?.chooseCLI() },
            openLogs: { [weak self] bench in self?.openLogs(bench) })
        popover = PopoverController(rootView: PopoverView(store: store, commands: commands))
        popover.onOpenChange = { [weak self] open in self?.store.setPopoverOpen(open) }

        settingsWindow = SettingsWindowController { [unowned self] in
            SettingsView(settings: settings, store: store, library: library, launchAtLogin: launchAtLogin, notifier: notifier,
                         chooseCLI: { [weak self] in self?.chooseCLI() })
        }

        logWindows = LogWindowController { [weak self] path in self?.openLogsInTerminal(path) }

        if Updater.isAvailable { updater = Updater() }
        NSApp.mainMenu = makeMainMenu()
        setUpClicks()

        Task {
            await store.start()
            askForCLIOnce()
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

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
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

    private func openSettings() {
        popover.close()
        settingsWindow.show()
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
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About BenchBar", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        if let item = updater?.menuItem() { appMenu.addItem(item) }
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
        return main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
