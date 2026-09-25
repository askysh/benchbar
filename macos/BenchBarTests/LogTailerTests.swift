import Foundation
import Testing
@testable import BenchBar

@Suite("Log tailer", .serialized)
struct LogTailerTests {
    let dir: TempDir
    let file: URL
    final class Seen { var text = ""; var resets = 0 }
    let seen = Seen()

    init() throws {
        dir = try TempDir()
        file = dir.url.appendingPathComponent("bench.log")
    }

    func tailer(initialBytes: Int = 1024) -> LogTailer {
        LogTailer(url: file, initialBytes: initialBytes,
                  onLines: { [seen] in seen.text += $0 },
                  onReset: { [seen] in seen.resets += 1 })
    }

    func write(_ text: String) throws { try Data(text.utf8).write(to: file) }
    func append(_ text: String) throws {
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd(); try h.write(contentsOf: Data(text.utf8)); try h.close()
    }

    @Test func readsTheFileThenWhatIsAppended() throws {
        try write("a\nb\n")
        let t = tailer()
        t.start()
        #expect(seen.text == "a\nb\n")
        try append("c\npartial")
        t.readNew()
        #expect(seen.text == "a\nb\nc\n", "the partial line waits")
        try append(" line\n")
        t.readNew()
        #expect(seen.text == "a\nb\nc\npartial line\n")
        t.stop()
    }

    @Test func aLargeFileStartsNearItsEndOnALineBoundary() throws {
        let lines = (0..<500).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try write(lines)
        let t = tailer(initialBytes: 100)
        t.start()
        #expect(seen.text.hasSuffix("line 499\n"))
        #expect(seen.text.hasPrefix("line "), "no half line at the start")
        #expect(seen.text.count <= 100)
        t.stop()
    }

    @Test func survivesTruncation() throws {
        try write("old 1\nold 2\n")
        let t = tailer()
        t.start()
        try write("")             // the runner's ": > bench.log"
        try append("new\n")
        t.readNew()
        #expect(seen.resets == 1)
        #expect(seen.text.hasSuffix("new\n"))
        t.stop()
    }

    @Test func survivesReplacementWithMv() throws {
        try write("first\n")
        let t = tailer()
        t.start()
        let other = dir.url.appendingPathComponent("bench.log.new")
        try Data("second\n".utf8).write(to: other)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: other)
        t.readNew()
        #expect(seen.resets == 1)
        #expect(seen.text == "first\nsecond\n")
        t.stop()
    }

    @Test func aMissingFileIsWaitedFor() throws {
        let t = tailer()
        t.start()
        #expect(seen.text.isEmpty)
        try write("appeared\n")
        t.readNew()
        #expect(seen.text == "appeared\n")
        t.stop()
    }

    @Test func utf8IsNeverCutInHalf() throws {
        try write("")
        let t = tailer()
        t.start()
        let bytes = Array("héllo\n".utf8)
        let h = try FileHandle(forWritingTo: file)
        try h.write(contentsOf: Data(bytes[0..<2]))   // "h" and half of "é"
        t.readNew()
        try h.write(contentsOf: Data(bytes[2...]))
        try h.close()
        t.readNew()
        #expect(seen.text == "héllo\n")
        t.stop()
    }
}
