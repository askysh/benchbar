import AppKit
import Testing
@testable import BenchBar

/// MAC-13: the menus, built without an AppDelegate.
@Suite("App menus")
struct AppMenusTests {
    final class Probe: NSObject {
        @objc func update() {}
        @objc func openWindow() {}
        @objc func scanFolder() {}
        @objc func openSettings() {}
        @objc func openAbout() {}
        @objc func openDocs() {}
        @objc func checkForUpdates() {}
        @objc func openMenuBarSettings() {}
        @objc func showShortcuts() {}
        @objc func showWalkthrough() {}
        @objc func openWhatsNew() {}
        @objc func reportBug() {}
    }

    private let probe = Probe()

    private var actions: AppMenus.Actions {
        AppMenus.Actions(update: #selector(Probe.update), openWindow: #selector(Probe.openWindow),
                         scanFolder: #selector(Probe.scanFolder), openSettings: #selector(Probe.openSettings),
                         openAbout: #selector(Probe.openAbout), openDocs: #selector(Probe.openDocs),
                         checkForUpdates: #selector(Probe.checkForUpdates),
                         openMenuBarSettings: #selector(Probe.openMenuBarSettings),
                         showShortcuts: #selector(Probe.showShortcuts), showWalkthrough: #selector(Probe.showWalkthrough),
                         openWhatsNew: #selector(Probe.openWhatsNew), reportBug: #selector(Probe.reportBug))
    }

    @Test func theStatusMenuWithoutAnUpdateHasNoUpdateItem() {
        let menu = AppMenus.statusMenu(target: probe, actions: actions, updateVersion: nil, updaterItem: nil)
        #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title)
                == ["Open BenchBar", "Scan Folder…", "Settings…", "About BenchBar", "Documentation", "Check for Updates…", "Quit BenchBar"])
        #expect(menu.items.first?.isSeparatorItem == false)
    }

    @Test func anUpdateOnOfferComesFirstAndSendsItsAction() throws {
        let menu = AppMenus.statusMenu(target: probe, actions: actions, updateVersion: "0.9.1", updaterItem: nil)
        let first = try #require(menu.items.first)
        #expect(first.title == "Update to 0.9.1…")
        #expect(first.action == #selector(Probe.update) && first.target === probe)
        #expect(menu.items[1].isSeparatorItem)
    }

    @Test func sparklesItemReplacesTheAboutPaneCheck() {
        let sparkle = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
        let menu = AppMenus.statusMenu(target: probe, actions: actions, updateVersion: nil, updaterItem: sparkle)
        #expect(menu.items.contains { $0 === sparkle })
        #expect(menu.items.filter { $0.title == "Check for Updates…" }.count == 1)
    }

    @Test func theStatusMenuItemsSendToTheTarget() throws {
        let menu = AppMenus.statusMenu(target: probe, actions: actions, updateVersion: nil, updaterItem: nil)
        let settings = try #require(menu.items.first { $0.title == "Settings…" })
        #expect(settings.keyEquivalent == "," && settings.action == #selector(Probe.openSettings) && settings.target === probe)
        let scan = try #require(menu.items.first { $0.title == "Scan Folder…" })
        #expect(scan.action == #selector(Probe.scanFolder) && scan.target === probe)
        let quit = try #require(menu.items.last)
        #expect(quit.action == #selector(NSApplication.terminate(_:)) && quit.keyEquivalent == "q" && quit.target == nil)
    }

    @Test func theMainMenuHasTheFourMenusAndWiresHelpAndWindow() throws {
        let menu = AppMenus.mainMenu(target: probe, actions: actions, updaterItem: nil)
        #expect(menu.items.map(\.title) == ["BenchBar", "Edit", "Window", "Help"])
        let help = try #require(menu.items.last?.submenu)
        #expect(NSApp.helpMenu === help)
        #expect(NSApp.windowsMenu === menu.items[2].submenu)
        let report = try #require(help.items.first { $0.title == "Report a Bug…" })
        #expect(report.action == #selector(Probe.reportBug) && report.target === probe)
        let docs = try #require(help.items.first)
        #expect(docs.keyEquivalent == "?" && docs.action == #selector(Probe.openDocs))
    }

    @Test func theEditMenuUsesTheResponderChain() throws {
        let menu = AppMenus.mainMenu(target: probe, actions: actions, updaterItem: nil)
        let edit = try #require(menu.items[1].submenu)
        #expect(edit.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All"])
        #expect(edit.items.allSatisfy { $0.target == nil })
    }
}
