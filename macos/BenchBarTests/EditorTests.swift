import Foundation
import Observation
import Testing
@testable import BenchBar

@Suite("Editors and Terminal scripts")
struct EditorTests {
    let code = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
    let cursor = URL(fileURLWithPath: "/Applications/Cursor.app")

    @Test func onlyInstalledEditorsAreOffered() {
        let both = Editors.installed { [Editors.known[0].bundleID: code, Editors.known[1].bundleID: cursor][$0] }
        #expect(both.map(\.name) == ["VS Code", "Cursor"])
        #expect(Editors.installed { _ in nil }.isEmpty)
    }

    @Test func theSavedChoiceWinsWhileInstalled() {
        let both = [Editors.known[0], Editors.known[1]]
        #expect(Editors.choice(preferred: Editors.known[1].bundleID, installed: both)?.name == "Cursor")
        #expect(Editors.choice(preferred: "", installed: both)?.name == "VS Code")
        // Cursor was chosen, then removed: fall back instead of doing nothing
        #expect(Editors.choice(preferred: Editors.known[1].bundleID, installed: [Editors.known[0]])?.name == "VS Code")
        #expect(Editors.choice(preferred: "x", installed: []) == nil)
    }

    /// Launch Services is asked at launch and when an app launches or quits,
    /// never from a view body; an unchanged answer redraws nothing.
    @Test func theInstalledEditorsAreLookedUpOnceAndOnAppChanges() {
        var lookups = 0
        var installed = [Editors.known[0]]
        let defaults = UserDefaults(suiteName: "benchbar-tests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults) { lookups += 1; return installed }
        #expect(lookups == 1)
        for _ in 0..<5 { _ = settings.editor }
        #expect(lookups == 1, "reading the editor asks no one")
        #expect(settings.editor?.name == "VS Code")

        let redrawn = Flag()
        withObservationTracking { _ = settings.installedEditors } onChange: { redrawn.set() }
        settings.refreshEditors()
        #expect(!redrawn.isSet, "the same list again")
        installed.append(Editors.known[1])
        settings.editorBundleID = Editors.known[1].bundleID
        settings.refreshEditors()
        #expect(redrawn.isSet)
        #expect(settings.editor?.name == "Cursor")
        #expect(lookups == 3)
    }

    @Test func consoleAndDatabaseScriptsRunTheCLI() {
        let console = TerminalScript.contents(.console, cli: "/Users/me/benchbar/benchbar", bench: "/Users/me/my bench", site: "macdev")
        #expect(console.contains("exec /Users/me/benchbar/benchbar console --site macdev --bench-dir '/Users/me/my bench'"))
        let db = TerminalScript.contents(.db, cli: "/b", bench: "/x", site: "a.localhost")
        #expect(db.contains("exec /b db --site a.localhost --bench-dir /x"))
        #expect(!db.lowercased().contains("password"))
    }
}
