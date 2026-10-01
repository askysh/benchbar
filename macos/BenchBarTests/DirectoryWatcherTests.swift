import Foundation
import Testing
@testable import BenchBar

@Suite("Directory watcher", .serialized)
struct DirectoryWatcherTests {
    /// Waits up to two seconds for a condition, letting the main queue run.
    func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<40 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func seesAnAtomicReplace() async throws {
        let dir = try TempDir()
        let folder = dir.url.appendingPathComponent("logs/.benchbar")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try dir.write("logs/.benchbar/state.json", #"{"state":"stopped"}"#)
        var hits = 0
        let watcher = DirectoryWatcher(target: folder) { hits += 1 }
        watcher.start()
        #expect(watcher.isWatchingTarget)

        // what the runner does: write a temp file, then mv it over state.json
        for state in ["starting", "running"] {
            let before = hits
            let tmp = try dir.write("logs/.benchbar/.state.json.tmp", #"{"state":"\#(state)"}"#)
            _ = try FileManager.default.replaceItemAt(folder.appendingPathComponent("state.json"), withItemAt: tmp)
            #expect(await eventually { hits > before }, "missed the \(state) replace")
        }
        watcher.stop()
    }

    @Test func waitsForTheFolderToAppear() async throws {
        let dir = try TempDir()
        let logs = dir.url.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let folder = logs.appendingPathComponent(".benchbar")
        var hits = 0
        let watcher = DirectoryWatcher(target: folder) { hits += 1 }
        watcher.start()
        #expect(!watcher.isWatchingTarget)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(await eventually { watcher.isWatchingTarget })
        let before = hits
        try dir.write("logs/.benchbar/state.json", "{}")
        #expect(await eventually { hits > before })
        watcher.stop()
    }

    /// A cleanup tool removes logs/ with everything in it: the watcher says
    /// it needs a restart, and a restart finds the folder once it is back.
    @Test func noticesItsFolderIsGone() async throws {
        let dir = try TempDir()
        let logs = dir.url.appendingPathComponent("logs")
        let folder = logs.appendingPathComponent(".benchbar")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var hits = 0
        let watcher = DirectoryWatcher(target: folder) { hits += 1 }
        watcher.start()
        #expect(!watcher.needsRestart)

        try FileManager.default.removeItem(at: logs)
        #expect(watcher.needsRestart)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(watcher.needsRestart, "nothing left to watch")

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        watcher.start()
        #expect(watcher.isWatchingTarget)
        #expect(!watcher.needsRestart)
        let before = hits
        try dir.write("logs/.benchbar/state.json", "{}")
        #expect(await eventually { hits > before })
        watcher.stop()
    }

    /// The folder deleted and made again at once: the same path, a new
    /// folder the old descriptor does not see.
    @Test func noticesItsFolderWasMadeAgain() async throws {
        let dir = try TempDir()
        let folder = dir.url.appendingPathComponent("logs/.benchbar")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let watcher = DirectoryWatcher(target: folder) {}
        watcher.start()
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(watcher.needsRestart)
        // its own events restart it on the new folder
        #expect(await eventually { !watcher.needsRestart && watcher.isWatchingTarget })
        watcher.stop()
    }
}
