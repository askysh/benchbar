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

    /// Loads every folder again; a bad one becomes a problem, not a crash.
    func reload() {
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

    /// Imports a runner folder or a .zip of one, and returns its id.
    /// Only manifest.json and the frames it lists are copied, after they
    /// pass validation; anything else in the folder or zip is left behind.
    @discardableResult
    func importRunner(from source: URL) throws(RunnerError) -> String {
        let fm = FileManager.default
        var scratch: URL?
        defer { if let scratch { try? fm.removeItem(at: scratch) } }

        let root: URL
        let suggested: String
        if source.pathExtension.lowercased() == "zip" {
            let unpacked = try Self.unzip(source)
            scratch = unpacked
            root = try Self.runnerRoot(in: unpacked)
            suggested = root == unpacked ? source.deletingPathExtension().lastPathComponent : root.lastPathComponent
        } else {
            root = source
            suggested = source.lastPathComponent
        }

        let id = Self.makeID(suggested)
        guard !Runner.builtIns.contains(where: { $0.id == id }) else { throw .reservedID(id) }
        _ = try RunnerLoader.load(folder: root, id: id)
        let files = try RunnerLoader.frameFiles(RunnerLoader.readManifest(in: root))

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
        return out
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
