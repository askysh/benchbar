import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BenchBar

/// Builds runner folders on disk for the loader and import tests.
nonisolated struct RunnerFolder {
    let url: URL

    init(in dir: TempDir, name: String = "blob") throws {
        url = dir.url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func manifest(_ json: String) throws {
        try json.write(to: url.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    }

    /// A PNG frame: a filled circle, so it is not empty.
    func png(_ name: String, width: Int = 40, height: Int = 36) throws {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillEllipse(in: CGRect(x: 2, y: 2, width: min(width, height) - 4, height: min(width, height) - 4))
        let dest = CGImageDestinationCreateWithURL(url.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    /// A valid runner: running (3 frames) and sleeping (1).
    static func valid(in dir: TempDir, name: String = "blob", order: String? = nil) throws -> RunnerFolder {
        let folder = try RunnerFolder(in: dir, name: name)
        for file in ["run1.png", "run2.png", "run3.png", "zzz.png"] { try folder.png(file) }
        let orderJSON = order.map { #", "frame_order": "\#($0)""# } ?? ""
        try folder.manifest(#"{"name": "Blob", "author": "Test", "template": true, "states": {"running": ["run1.png", "run2.png", "run3.png"], "sleeping": ["zzz.png"]}\#(orderJSON)}"#)
        return folder
    }
}

@Suite("Custom runners")
struct RunnerPackageTests {
    let dir: TempDir
    init() throws { dir = try TempDir() }

    func load(_ folder: RunnerFolder) throws(RunnerError) -> Runner {
        try RunnerLoader.load(folder: folder.url, id: "blob")
    }

    func expectError(_ expected: RunnerError, _ folder: RunnerFolder, sourceLocation: SourceLocation = #_sourceLocation) {
        do throws(RunnerError) {
            _ = try load(folder)
            Issue.record("expected \(expected)", sourceLocation: sourceLocation)
        } catch {
            #expect(error == expected, sourceLocation: sourceLocation)
        }
    }

    @Test func validRunnerLoadsWithFallbacks() throws {
        let runner = try load(RunnerFolder.valid(in: dir))
        #expect(runner.name == "Blob")
        #expect(runner.author == "Test")
        #expect(runner.isTemplate)
        #expect(runner.pointWidth == 20)
        #expect(runner.frames(for: .running).count == 3)
        #expect(runner.frames(for: .sleeping).count == 1)
        // missing states fall back to running
        #expect(runner.frames(for: .crashed).count == 3)
        #expect(runner.frames(for: .unknown).count == 3)
    }

    @Test func pingPongPlaysBackAndForth() throws {
        let runner = try load(RunnerFolder.valid(in: dir, order: "ping_pong"))
        let frames = runner.frames(for: .running)
        #expect(frames.count == 4)
        #expect(frames[3] === frames[1])
    }

    @Test func missingOrBrokenManifest() throws {
        let folder = try RunnerFolder(in: dir)
        expectError(.missingManifest, folder)
        try folder.manifest("{ not json")
        expectError(.badManifest("it is not valid JSON"), folder)
        try folder.manifest(#"{"name": "X", "states": {"running": ["a.png"]}}"#)
        expectError(.badManifest("\"template\" is missing"), folder)
        try folder.manifest(#"{"name": " ", "template": true, "states": {"running": ["a.png"]}}"#)
        expectError(.badManifest("\"name\" must be 1 to 40 characters"), folder)
    }

    @Test func statesAreStrict() throws {
        let folder = try RunnerFolder(in: dir)
        try folder.png("a.png")
        try folder.manifest(#"{"name": "X", "template": true, "states": {"running": ["a.png"], "dancing": ["a.png"]}}"#)
        expectError(.unknownState("dancing"), folder)
        try folder.manifest(#"{"name": "X", "template": true, "states": {"sleeping": ["a.png"]}}"#)
        expectError(.noRunningFrames, folder)
        try folder.manifest(#"{"name": "X", "template": true, "states": {"running": ["a.png"], "alert": []}}"#)
        expectError(.emptyState("alert"), folder)
        let many = (0..<31).map { _ in "\"a.png\"" }.joined(separator: ",")
        try folder.manifest(#"{"name": "X", "template": true, "states": {"running": [\#(many)]}}"#)
        expectError(.tooManyFrames(state: "running", count: 31), folder)
    }

    @Test func frameNamesCannotLeaveTheFolder() throws {
        let folder = try RunnerFolder(in: dir)
        for bad in ["../evil.png", "sub/a.png", ".hidden.png", "a.gif", "a\\\\b.png", "C:a.png"] {
            try folder.manifest(#"{"name": "X", "template": true, "states": {"running": ["\#(bad)"]}}"#)
            do throws(RunnerError) {
                _ = try load(folder)
                Issue.record("\(bad) was accepted")
            } catch {
                guard case .badFileName = error else { Issue.record("\(bad): \(error)"); continue }
            }
        }
    }

    @Test func framesMustBePNGsOfTheRightSize() throws {
        let folder = try RunnerFolder(in: dir)
        try folder.manifest(#"{"name": "X", "template": true, "states": {"running": ["a.png", "b.png"]}}"#)
        expectError(.missingFile("a.png"), folder)
        try "not an image".write(to: folder.url.appendingPathComponent("a.png"), atomically: true, encoding: .utf8)
        try folder.png("b.png")
        expectError(.notPNG("a.png"), folder)
        try folder.png("a.png", width: 40, height: 32)
        expectError(.badSize(file: "a.png", width: 40, height: 32), folder)
        try folder.png("a.png", width: 8)
        expectError(.badSize(file: "a.png", width: 8, height: 36), folder)
        try folder.png("a.png", width: 101)
        expectError(.badSize(file: "a.png", width: 101, height: 36), folder)
        try folder.png("a.png", width: 50)
        expectError(.mixedSizes(file: "b.png"), folder)
    }

    @Test func symlinkedFramesAreRejected() throws {
        let folder = try RunnerFolder(in: dir)
        let outside = try RunnerFolder(in: dir, name: "outside")
        try outside.png("real.png")
        try FileManager.default.createSymbolicLink(at: folder.url.appendingPathComponent("a.png"),
                                                   withDestinationURL: outside.url.appendingPathComponent("real.png"))
        try folder.manifest(#"{"name": "X", "template": true, "states": {"running": ["a.png"]}}"#)
        expectError(.missingFile("a.png"), folder)
    }

    @Test func runnersOver2MBAreRejected() throws {
        let folder = try RunnerFolder.valid(in: dir)
        try Data(count: RunnerLoader.maxBytes).write(to: folder.url.appendingPathComponent("padding.bin"))
        do throws(RunnerError) {
            _ = try load(folder)
            Issue.record("accepted a runner over the limit")
        } catch {
            guard case .tooLarge = error else { Issue.record("\(error)"); return }
        }
    }

    // MARK: library and import

    func library() -> RunnerLibrary {
        RunnerLibrary(folder: dir.url.appendingPathComponent("Library/Runners"))
    }

    @Test func importCopiesOnlyTheListedFiles() throws {
        let source = try RunnerFolder.valid(in: dir, name: "My Blob!")
        try "junk".write(to: source.url.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let lib = library()
        let id = try lib.importRunner(from: source.url)
        #expect(id == "my-blob-")
        let installed = lib.folder.appendingPathComponent(id)
        let files = try FileManager.default.contentsOfDirectory(atPath: installed.path).sorted()
        #expect(files == ["manifest.json", "run1.png", "run2.png", "run3.png", "zzz.png"])
        #expect(lib.custom.map(\.id) == [id])
        #expect(lib.all.count == Runner.builtIns.count + 1)
        #expect(lib.runner(id).name == "Blob")
    }

    @Test func importFromZipOfAFolder() throws {
        let source = try RunnerFolder.valid(in: dir, name: "zipped")
        let zip = dir.url.appendingPathComponent("zipped.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", source.url.path, zip.path]
        try ditto.run(); ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)

        let lib = library()
        let id = try lib.importRunner(from: zip)
        #expect(id == "zipped")
        #expect(lib.runner("zipped").frames(for: .running).count == 3)
    }

    @Test func badImportLeavesNothingBehind() throws {
        let folder = try RunnerFolder(in: dir, name: "broken")
        try folder.manifest(#"{"name": "X", "template": true, "states": {"sleeping": ["a.png"]}}"#)
        let lib = library()
        #expect(throws: RunnerError.noRunningFrames) { try lib.importRunner(from: folder.url) }
        #expect(!FileManager.default.fileExists(atPath: lib.folder.appendingPathComponent("broken").path))
        #expect(throws: RunnerError.badArchive("it is not a zip file")) {
            try lib.importRunner(from: folder.url.appendingPathComponent("manifest.json").deletingPathExtension().appendingPathExtension("zip"))
        }
    }

    @Test func builtInNamesAreReserved() throws {
        let source = try RunnerFolder.valid(in: dir, name: "bench")
        #expect(throws: RunnerError.reservedID("bench")) { try library().importRunner(from: source.url) }
    }

    @Test func brokenInstalledRunnerIsAProblemNotACrash() throws {
        let lib = library()
        let bad = lib.folder.appendingPathComponent("bad")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        lib.reload()
        #expect(lib.custom.isEmpty)
        #expect(lib.problems == [RunnerProblem(id: "bad", message: RunnerError.missingManifest.localizedDescription)])
        #expect(lib.runner("bad").id == Runner.defaultID)
    }

    @Test func removeMovesToTrashAndFallsBack() throws {
        let lib = library()
        let id = try lib.importRunner(from: RunnerFolder.valid(in: dir).url)
        lib.remove(id)
        #expect(lib.custom.isEmpty)
        #expect(lib.runner(id).id == Runner.defaultID)
    }

    @Test func exampleRunnerInTheRepoIsValid() throws {
        // examples/runners/blob, found from this source file's path
        let example = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("examples/runners/blob")
        let runner = try RunnerLoader.load(folder: example, id: "blob")
        #expect(runner.name == "Blob")
        #expect(runner.frames(for: .running).count == 4)
        #expect(runner.frames(for: .starting).count == 4, "starting falls back to running")
    }

    @Test func zipTotalsParse() {
        let text = "5 files, 12345 bytes uncompressed, 6789 bytes compressed:  45.0%\n"
        #expect(RunnerLibrary.parseZipTotals(text)! == (files: 5, bytes: 12345))
        #expect(RunnerLibrary.parseZipTotals("garbage") == nil)
    }

    @Test func idsAreSafeFolderNames() {
        #expect(RunnerLibrary.makeID("My Runner") == "my-runner")
        #expect(RunnerLibrary.makeID("../x") == "x")
        #expect(RunnerLibrary.makeID("...") == "runner")
        #expect(RunnerLibrary.isValidID("cat-2.0_b"))
        #expect(!RunnerLibrary.isValidID("Cat"))
        #expect(!RunnerLibrary.isValidID(".x"))
    }
}
