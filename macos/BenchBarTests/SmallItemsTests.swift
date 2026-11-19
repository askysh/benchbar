import Foundation
import Testing
@testable import BenchBar

/// MAC-14: the small items.
@Suite("Small items")
struct SmallItemsTests {
    // the CLI's own answer to a command it does not have
    @Test func anUnknownCommandIsOneCheck() {
        #expect(CLIError.failed(command: "labs", exitCode: 1, message: "[FAIL] Unknown command: labs").isUnknownCommand)
        #expect(CLIError.failed(command: "share", exitCode: 1, message: "unknown command: share").isUnknownCommand)
        #expect(!CLIError.failed(command: "labs", exitCode: 1, message: "timed out").isUnknownCommand)
        #expect(!CLIError.timedOut(command: "labs", seconds: 20).isUnknownCommand)
    }

    // a script of its own for every run
    @Test func twoBenchesWithOneNameGetTwoOwnerOnlyScripts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("benchbar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let one = try Workspace.writeScript(name: "frappe-bench", contents: "echo one", in: folder)
        let two = try Workspace.writeScript(name: "frappe-bench", contents: "echo two", in: folder)
        #expect(one != two)
        #expect(one.lastPathComponent.hasPrefix("frappe-bench-") && one.pathExtension == "command")
        #expect(try String(contentsOf: one, encoding: .utf8) == "echo one")
        let mode = try FileManager.default.attributesOfItem(atPath: one.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        // a name with a slash stays inside the folder
        let odd = try Workspace.writeScript(name: "../x y", contents: "", in: folder)
        #expect(odd.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
    }

    @Test func aScriptOlderThanADayIsRemovedByTheNextOne() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("benchbar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = try Workspace.writeScript(name: "old", contents: "", in: folder)
        let fresh = try Workspace.writeScript(name: "fresh", contents: "", in: folder, now: Date().addingTimeInterval(3600))
        #expect(FileManager.default.fileExists(atPath: old.path), "an hour is not a day")
        _ = try Workspace.writeScript(name: "later", contents: "", in: folder, now: Date().addingTimeInterval(2 * 86_400))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: fresh.path))
    }

    // editors: only an editor coming or going matters
    @Test func onlyAnEditorStartsTheLookup() {
        #expect(Editors.isEditor("com.microsoft.VSCode"))
        #expect(!Editors.isEditor("com.apple.Safari"))
        #expect(Editors.isEditor(nil), "an app that does not say who it is: look")
    }

    // a leftover Caskroom folder is not proof
    @Test func aCaskroomLeftoverDoesNotMakeThisCopyTheCasks() {
        func env(links: [String]) -> UpdatePlan.Environment {
            UpdatePlan.Environment(home: "/Users/you", appBundlePath: "/Applications/BenchBar.app",
                                   exists: { $0 == "/opt/homebrew/Caskroom/benchbar-app" }, caskLinks: { _ in links })
        }
        #expect(UpdatePlan.make(env(links: [])).cask == nil, "folder left behind, nothing leads here")
        #expect(UpdatePlan.make(env(links: ["/Users/you/Downloads/BenchBar.app"])).cask == nil)
        #expect(UpdatePlan.make(env(links: ["/Applications/BenchBar.app"])).cask == "/opt/homebrew")
    }

    /// Older brew keeps the real bundle in the Caskroom and /Applications/BenchBar.app leads to it.
    @Test func aRealBundleInTheCaskroomIsProofWhenTheAppLeadsThere() {
        let bundle = "/opt/homebrew/Caskroom/benchbar-app/0.8.3/BenchBar.app"
        func env(real: String?) -> UpdatePlan.Environment {
            UpdatePlan.Environment(home: "/Users/you", appBundlePath: "/Applications/BenchBar.app",
                                   exists: { $0 == "/opt/homebrew/Caskroom/benchbar-app" }, caskLinks: { _ in [bundle] },
                                   appRealPath: real)
        }
        #expect(UpdatePlan.make(env(real: bundle)).cask == "/opt/homebrew")
        #expect(UpdatePlan.make(env(real: "/Applications/BenchBar.app")).cask == nil, "a copy in /Applications is not that bundle")
        #expect(UpdatePlan.make(env(real: nil)).cask == nil)
    }

    // the CLI's environment
    @Test func strayBenchbarVariablesAreRemovedFromTheChildButTheCallsOwnStay() {
        let inherited = ["PATH": "/usr/bin", "BENCHBAR_STATE_DIR": "/x", "FL_BENCH_DIR": "/y", "BENCHBAR_PROFILE_PATH": "/p", "BENCHBAR_SUDO": "gui"]
        let result = SubprocessRunner.childEnvironment(["BENCHBAR_SUDO": "gui", "NO_COLOR": "1"], inherited: inherited)
        #expect(result["NO_COLOR"] == .some("1"))
        #expect(result["BENCHBAR_SUDO"] == .some("gui"))
        #expect(result["BENCHBAR_STATE_DIR"] == .some(nil))
        #expect(result["FL_BENCH_DIR"] == .some(nil))
        #expect(result["BENCHBAR_PROFILE_PATH"] == nil, "left as it is")
        #expect(result["PATH"] == nil)
    }

    /// The variables the docs tell a person to set are the person's, set in launchd or not.
    @Test func documentedUserVariablesSurviveAndSeamsGo() {
        let inherited = ["BENCHBAR_OFFLINE": "1", "BENCHBAR_LABS": "lan-rooms", "BENCHBAR_REPORT_DIR": "/r", "BENCHBAR_LOCK": "/l",
                         "BENCHBAR_NO_HANDOFF": "1", "BENCHBAR_SUDO": "env", "BENCHBAR_SUDO_PASSWORD": "x", "FL_STATE_DIR": "/s",
                         "BENCHBAR_FAKE_BREW": "/bin/true", "BENCHBAR_TEST_NOW": "1"]
        let result = SubprocessRunner.childEnvironment([:], inherited: inherited)
        for kept in ["BENCHBAR_OFFLINE", "BENCHBAR_LABS", "BENCHBAR_REPORT_DIR", "BENCHBAR_LOCK", "BENCHBAR_NO_HANDOFF"] {
            #expect(result[kept] == nil, "\(kept) is left as it is")
        }
        for dropped in ["BENCHBAR_SUDO", "BENCHBAR_SUDO_PASSWORD", "FL_STATE_DIR", "BENCHBAR_FAKE_BREW", "BENCHBAR_TEST_NOW"] {
            #expect(result[dropped] == .some(nil), "\(dropped) is removed")
        }
    }
}
