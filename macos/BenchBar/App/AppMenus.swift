import AppKit

/// The status item's menu and the main menu, built from a target and its selectors so the tests can
/// look at them without an `AppDelegate` (MAC-13, taken out of `AppDelegate`).
enum AppMenus {
    /// The actions the items send to the target.
    struct Actions {
        var update: Selector
        var openWindow: Selector
        var scanFolder: Selector
        var openSettings: Selector
        var openAbout: Selector
        var openDocs: Selector
        var checkForUpdates: Selector
        var openMenuBarSettings: Selector
        var showShortcuts: Selector
        var showWalkthrough: Selector
        var openWhatsNew: Selector
        var reportBug: Selector
    }

    /// The small menu of a right click on the menu bar item. `updateVersion`: an update is on offer.
    /// `updaterItem`: Sparkle's item, else the About pane's check.
    static func statusMenu(target: AnyObject, actions: Actions, updateVersion: String?, updaterItem: NSMenuItem?) -> NSMenu {
        let menu = NSMenu()
        if let updateVersion {
            menu.addItem(withTitle: String(localized: "Update to \(updateVersion)…"), action: actions.update, keyEquivalent: "").target = target
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: String(localized: "Open BenchBar"), action: actions.openWindow, keyEquivalent: "").target = target
        menu.addItem(withTitle: String(localized: "Scan Folder…"), action: actions.scanFolder, keyEquivalent: "").target = target
        menu.addItem(withTitle: String(localized: "Settings…"), action: actions.openSettings, keyEquivalent: ",").target = target
        menu.addItem(withTitle: String(localized: "About BenchBar"), action: actions.openAbout, keyEquivalent: "").target = target
        menu.addItem(withTitle: String(localized: "Documentation"), action: actions.openDocs, keyEquivalent: "").target = target
        if let updaterItem {
            menu.addItem(updaterItem)
        } else {
            menu.addItem(withTitle: String(localized: "Check for Updates…"), action: actions.checkForUpdates, keyEquivalent: "").target = target
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit BenchBar"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    /// Only visible while a window is open (the app is .regular then), but it is what makes ⌘W, ⌘Q and
    /// copy and paste work in that window. Sets `NSApp.windowsMenu` and `NSApp.helpMenu`.
    static func mainMenu(target: AnyObject, actions: Actions, updaterItem: NSMenuItem?) -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "About BenchBar"), action: actions.openAbout, keyEquivalent: "").target = target
        if let updaterItem {
            appMenu.addItem(updaterItem)
        } else {
            appMenu.addItem(withTitle: String(localized: "Check for Updates…"), action: actions.checkForUpdates, keyEquivalent: "").target = target
        }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Settings…"), action: actions.openSettings, keyEquivalent: ",").target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit BenchBar"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "BenchBar"))

        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: String(localized: "Edit")))

        let window = NSMenu(title: String(localized: "Window"))
        window.addItem(withTitle: "BenchBar", action: actions.openWindow, keyEquivalent: "").target = target
        window.addItem(withTitle: String(localized: "Menu Bar Settings"), action: actions.openMenuBarSettings, keyEquivalent: "").target = target
        window.addItem(.separator())
        window.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu(window, title: String(localized: "Window")))
        NSApp.windowsMenu = window

        // Help last: macOS adds its search field to the menu set as helpMenu
        let help = NSMenu(title: String(localized: "Help"))
        help.addItem(withTitle: String(localized: "BenchBar Documentation"), action: actions.openDocs, keyEquivalent: "?").target = target
        help.addItem(withTitle: String(localized: "Keyboard Shortcuts"), action: actions.showShortcuts, keyEquivalent: "").target = target
        help.addItem(withTitle: String(localized: "Show Walkthrough"), action: actions.showWalkthrough, keyEquivalent: "").target = target
        help.addItem(.separator())
        help.addItem(withTitle: String(localized: "What's New"), action: actions.openWhatsNew, keyEquivalent: "").target = target
        help.addItem(withTitle: String(localized: "Report a Bug…"), action: actions.reportBug, keyEquivalent: "").target = target
        main.addItem(submenu(help, title: String(localized: "Help")))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
