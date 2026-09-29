import Foundation
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

    @Test func consoleAndDatabaseScriptsRunTheCLI() {
        let console = TerminalScript.contents(.console, cli: "/Users/me/benchbar/benchbar", bench: "/Users/me/my bench", site: "macdev")
        #expect(console.contains("exec /Users/me/benchbar/benchbar console --site macdev --bench-dir '/Users/me/my bench'"))
        let db = TerminalScript.contents(.db, cli: "/b", bench: "/x", site: "a.localhost")
        #expect(db.contains("exec /b db --site a.localhost --bench-dir /x"))
        #expect(!db.lowercased().contains("password"))
    }
}
