import AppKit
import Foundation
import Observation

/// A runner folder that failed validation, shown in Settings.
nonisolated struct RunnerProblem: Equatable, Identifiable, Sendable {
    var id: String
    var message: String
}

/// The built in runners plus the ones in
/// ~/Library/Application Support/BenchBar/Runners/<id>/.
@Observable
final class RunnerLibrary {
    let folder: URL
    private(set) var custom: [Runner] = []
    private(set) var problems: [RunnerProblem] = []

    init(folder: URL = RunnerLibrary.defaultFolder) {
        self.folder = folder
        reload()
    }

    nonisolated static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BenchBar/Runners", isDirectory: true)
    }

    var all: [Runner] { Runner.builtIns + custom }

    /// The runner with this id, or the default one if it is gone.
    func runner(_ id: String) -> Runner {
        all.first { $0.id == id } ?? Runner.builtIn(Runner.defaultID)
    }

    func isCustom(_ id: String) -> Bool { custom.contains { $0.id == id } }

    /// What `reload` last read: every entry of the folder with its size and
    /// modification time.
    @ObservationIgnored private var seen: [String]?

    /// One line per file and folder under `folder`: path, size, modification time.
    /// A stat of each, so cheap next to decoding the PNGs.
    nonisolated static func fingerprint(of folder: URL) -> [String] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        let base = folder.standardizedFileURL.path
        return walker.compactMap { ($0 as? URL) }.map { url -> String in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let time = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            return "\(url.standardizedFileURL.path.dropFirst(base.count))|\(values?.fileSize ?? 0)|\(time)"
        }.sorted()
    }

    /// Loads every folder again; a bad one becomes a problem, not a crash.
    /// Does nothing when the folder is as it was at the last load: a reload
    /// builds new images, which restarts the menu bar animation of a custom runner.
    func reload() {
        let now = Self.fingerprint(of: folder)
        guard now != seen else { return }
        seen = now
        var runners: [Runner] = []
        var issues: [RunnerProblem] = []
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let id = entry.lastPathComponent
            do throws(RunnerError) {
                guard Self.isValidID(id) else { throw .badFileName(id) }
                guard !Runner.builtIns.contains(where: { $0.id == id }) else { throw .reservedID(id) }
                runners.append(try RunnerLoader.load(folder: entry, id: id))
            } catch {
                issues.append(RunnerProblem(id: id, message: error.localizedDescription))
            }
        }
        custom = runners
        problems = issues
    }

    // MARK: import

    /// A source that passed validation: the folder to copy from, the id it gets, the files to copy.
    /// `scratch` is the unpacked zip, removed after the copy.
    nonisolated struct PreparedImport: Sendable {
        var root: URL
        var id: String
        var files: Set<String>
        var scratch: URL?
    }

    /// Unpacks (a zip) and validates; reads nothing but the source, so it can run off the main
    /// actor: a zip from the internet must not freeze the window while it unpacks.
    nonisolated static func prepareImport(from source: URL) throws(RunnerError) -> PreparedImport {
        var scratch: URL?
        do throws(RunnerError) {
            let root: URL
            let suggested: String
            if source.pathExtension.lowercased() == "zip" {
                let unpacked = try unzip(source)
                scratch = unpacked
                root = try runnerRoot(in: unpacked)
                suggested = root == unpacked ? source.deletingPathExtension().lastPathComponent : root.lastPathComponent
            } else {
                root = source
                suggested = source.lastPathComponent
            }
            let id = makeID(suggested)
            guard !Runner.builtIns.contains(where: { $0.id == id }) else { throw .reservedID(id) }
            _ = try RunnerLoader.load(folder: root, id: id)
            let files = try RunnerLoader.frameFiles(RunnerLoader.readManifest(in: root))
            return PreparedImport(root: root, id: id, files: files, scratch: scratch)
        } catch {
            if let scratch { try? FileManager.default.removeItem(at: scratch) }
            throw error
        }
    }

    /// Imports a runner folder or a .zip of one, and returns its id.
    /// Only manifest.json and the frames it lists are copied, after they
    /// pass validation; anything else in the folder or zip is left behind.
    @discardableResult
    func importRunner(from source: URL) throws(RunnerError) -> String {
        try install(try Self.prepareImport(from: source))
    }

    /// The same, with the unpacking and the checks off the main actor.
    func importRunnerInBackground(from source: URL) async -> Result<String, RunnerError> {
        let prepared = await Task.detached { () -> Result<PreparedImport, RunnerError> in
            do throws(RunnerError) { return .success(try Self.prepareImport(from: source)) } catch { return .failure(error) }
        }.value
        switch prepared {
        case .failure(let error): return .failure(error)
        case .success(let ready):
            do throws(RunnerError) { return .success(try install(ready)) } catch { return .failure(error) }
        }
    }

    private func install(_ prepared: PreparedImport) throws(RunnerError) -> String {
        let fm = FileManager.default
        defer { if let scratch = prepared.scratch { try? fm.removeItem(at: scratch) } }
        let root = prepared.root, id = prepared.id, files = prepared.files

        // copy into a fresh folder next to the destination, then swap it in
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let staging = folder.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for name in files.union([RunnerLoader.manifestName]) {
                try fm.copyItem(at: root.appendingPathComponent(name), to: staging.appendingPathComponent(name))
            }
            let destination = folder.appendingPathComponent(id, isDirectory: true)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
        } catch {
            throw .badArchive("could not copy it into \(folder.path): \(error.localizedDescription)")
        }
        reload()
        return id
    }

    func remove(_ id: String) {
        guard isCustom(id), Self.isValidID(id) else { return }
        let url = folder.appendingPathComponent(id, isDirectory: true)
        // to the Trash, not deleted: the user can take it back
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reload()
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // MARK: helpers

    /// Folder names become ids: lowercase letters, digits, dot, dash, underscore.
    nonisolated static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && !id.hasPrefix(".")
            && id.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-").contains($0) }
    }

    nonisolated static func makeID(_ name: String) -> String {
        var id = ""
        for scalar in name.lowercased().unicodeScalars {
            id.unicodeScalars.append(isValidID(String(scalar)) ? scalar : "-")
        }
        while id.hasPrefix(".") || id.hasPrefix("-") { id.removeFirst() }
        id = String(id.prefix(64))
        return id.isEmpty ? "runner" : id
    }

    /// Checks a zip's listing (entry count and unpacked size, against zip
    /// bombs), then unpacks it with ditto into a temporary folder.
    nonisolated static func unzip(_ zip: URL) throws(RunnerError) -> URL {
        let listing = run("/usr/bin/zipinfo", ["-t", zip.path])
        guard listing.status == 0, let totals = parseZipTotals(listing.output) else {
            throw .badArchive("it is not a zip file")
        }
        guard totals.files <= 200 else { throw .badArchive("it has \(totals.files) files") }
        guard totals.bytes <= RunnerLoader.maxBytes * 2 else { throw .tooLarge(bytes: totals.bytes) }

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("benchbar-runner-\(UUID().uuidString)")
        let result = run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
        guard result.status == 0 else { throw .badArchive("ditto could not unpack it") }
        // a zip keeps symlinks and ditto restores them: a link to a device, a FIFO or a file
        // elsewhere on the Mac has no place in a runner, so anything that is not a plain file
        // or a folder stops the import before a single file is read
        guard onlyPlainFiles(in: out) else {
            try? FileManager.default.removeItem(at: out)
            throw .badArchive("it holds a link or another file that is not a plain file")
        }
        return out
    }

    /// Every entry under `folder` is a regular file or a folder, links not followed. Fails
    /// closed: a folder that is not there, that is not a folder, or that the walk cannot read
    /// to the end is not plain.
    nonisolated static func onlyPlainFiles(in folder: URL) -> Bool {
        var root = stat()
        guard lstat(folder.path, &root) == 0, root.st_mode & S_IFMT == S_IFDIR else { return false }
        // the error handler runs for an entry the walk cannot read; the walk then stops, and
        // an unfinished walk must not pass
        final class Failure: @unchecked Sendable { var happened = false }
        let failure = Failure()
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [],
                                                          errorHandler: { _, _ in failure.happened = true; return false })
        else { return false }
        for case let url as URL in walker {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return false }
            let kind = info.st_mode & S_IFMT
            if kind != S_IFREG && kind != S_IFDIR { return false }
        }
        return !failure.happened
    }

    /// "12 files, 34567 bytes uncompressed, ..." from zipinfo -t.
    nonisolated static func parseZipTotals(_ text: String) -> (files: Int, bytes: Int)? {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "," })
        guard let filesIndex = words.firstIndex(where: { $0.hasPrefix("file") }), filesIndex > 0,
              let files = Int(words[filesIndex - 1]),
              let bytesIndex = words.firstIndex(of: "bytes"), bytesIndex > 0,
              let bytes = Int(words[bytesIndex - 1]) else { return nil }
        return (files, bytes)
    }

    /// The folder in an unpacked zip that holds manifest.json: the top, or
    /// the one folder inside (zipping a folder in Finder does that).
    nonisolated static func runnerRoot(in unpacked: URL) throws(RunnerError) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: unpacked.appendingPathComponent(RunnerLoader.manifestName).path) { return unpacked }
        let folders = ((try? fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.lastPathComponent != "__MACOSX" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        if folders.count == 1, fm.fileExists(atPath: folders[0].appendingPathComponent(RunnerLoader.manifestName).path) {
            return folders[0]
        }
        throw .missingManifest
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
