import AppKit
import Foundation
import Observation
import Testing
@testable import BenchBar

@Suite("Log tailer", .serialized)
struct LogTailerTests {
    let dir: TempDir
    let file: URL
    final class Seen { var text = ""; var resets = 0; var reads = 0 }
    let seen = Seen()

    init() throws {
        dir = try TempDir()
        file = dir.url.appendingPathComponent("bench.log")
    }

    /// `window`: the test closes the read window itself; the main queue's
    /// clock otherwise, as in the app.
    func tailer(initialBytes: Int = 1024, window: ManualWindow? = nil) -> LogTailer {
        LogTailer(url: file, initialBytes: initialBytes, schedule: window?.schedule ?? LogTailer.onMainQueue,
                  onLines: { [seen] in seen.text += $0; seen.reads += 1 },
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

    // MARK: 0.6.1: a busy log costs one read per window

    /// A busy bench writes many times a second: the events of one window
    /// are read once, at its end.
    @Test func eventsCloseTogetherAreReadOnce() throws {
        try write("a\n")
        let window = ManualWindow()
        let t = tailer(window: window)
        t.start()
        #expect(seen.reads == 1)
        for line in ["b", "c", "d"] {
            try append(line + "\n")
            t.changed(replaced: false)
        }
        #expect(window.scheduled == 1, "one read for three events")
        #expect(seen.text == "a\n", "nothing until the window closes")
        window.close()
        #expect(seen.text == "a\nb\nc\nd\n")
        #expect(seen.reads == 2)

        try append("e\n")
        t.changed(replaced: false)
        #expect(window.scheduled == 2, "the next event opens a new window")
        window.close()
        #expect(seen.text == "a\nb\nc\nd\ne\n")
        t.stop()
    }

    /// An append and a truncation are read through the open descriptor
    /// (fstat); only an event that may have replaced the file looks at the path.
    @Test func appendsAndTruncationNeedOnlyTheOpenDescriptor() throws {
        try write("first line\n")
        let window = ManualWindow()
        let t = tailer(window: window)
        t.start()
        try append("b\n")
        t.changed(replaced: false)
        window.close()
        let h = try FileHandle(forWritingTo: file)
        try h.truncate(atOffset: 0)
        try h.write(contentsOf: Data("new\n".utf8))
        try h.close()
        t.changed(replaced: false)
        window.close()
        #expect(seen.text == "first line\nb\nnew\n")
        #expect(seen.resets == 1, "the truncation is seen in the descriptor's size")
        #expect(t.pathLookups == 0)

        // renamed away, a new file under the name: the path tells
        try FileManager.default.moveItem(at: file, to: dir.url.appendingPathComponent("bench.old.log"))
        try write("fresh\n")
        t.changed(replaced: true)
        window.close()
        #expect(t.pathLookups == 1)
        #expect(seen.resets == 2)
        #expect(seen.text.hasSuffix("new\nfresh\n"))
        t.stop()
    }

    /// A restart after a short log: truncated, then longer than before, all
    /// in one window. The size at the window's end says nothing, so the event
    /// of the truncation has to remember it; else the new log loses its start
    /// and the rest is glued to the old run.
    @Test func aTruncationIsSeenEvenWhenTheLogRegrowsInTheSameWindow() throws {
        try write("old 1\nold 2\n")
        let window = ManualWindow()
        let t = tailer(window: window)
        t.start()
        #expect(seen.text == "old 1\nold 2\n")
        let h = try FileHandle(forWritingTo: file)
        try h.truncate(atOffset: 0)   // the runner's ": > bench.log"
        t.changed(replaced: false)
        try h.write(contentsOf: Data("new run 1\nnew run 2\nnew run 3\n".utf8))
        try h.close()
        t.changed(replaced: false)
        #expect(window.scheduled == 1, "one window for both events")
        window.close()
        #expect(seen.resets == 1, "the truncation is not lost to the regrowth")
        #expect(seen.text == "old 1\nold 2\nnew run 1\nnew run 2\nnew run 3\n")
        #expect(t.pathLookups == 0)

        // the next window, a plain append: no second reset
        try append("new run 4\n")
        t.changed(replaced: false)
        window.close()
        #expect(seen.resets == 1)
        #expect(seen.text.hasSuffix("new run 3\nnew run 4\n"))
        t.stop()
    }

    /// The file watcher and the main queue's clock, as the log window runs them.
    @Test func anAppendArrivesThroughTheWatcher() async throws {
        try write("a\n")
        let t = tailer()
        t.start()
        try append("b\n")
        for _ in 0..<300 {
            if seen.text == "a\nb\n" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(seen.text == "a\nb\n")
        t.stop()
    }
}

/// The tailer's read window, closed by the test instead of the clock.
final class ManualWindow {
    private(set) var scheduled = 0
    private var due: [@MainActor () -> Void] = []

    var schedule: LogTailer.Schedule {
        { [self] _, work in
            scheduled += 1
            due.append(work)
        }
    }

    func close() {
        let work = due
        due = []
        work.forEach { $0() }
    }
}

@Suite("Log view", .serialized)
struct LogViewTests {
    func line(_ n: Int) -> String { "10:00:\(n < 10 ? "0" : "")\(n) web.1       | line \(n)" }
    func text(_ range: ClosedRange<Int>) -> String { range.map { line($0) + "\n" }.joined() }

    /// What a read brings reaches the text in one edit: the lines the buffer
    /// dropped leave the top, the new ones come at the end. And drawing
    /// reads the model, never writes it: SwiftUI would update the view again.
    @Test func newLinesReachTheTextInOneEditAndDrawingWritesNothing() async throws {
        let dir = try TempDir()
        let log = try dir.write("logs/bench.log", text(1...4))
        let model = LogViewModel(benchName: "frappe-bench", benchPath: dir.url.path, capacity: 5)
        model.start()
        defer { model.stop() }
        let scroll = NSTextView.scrollableTextView()
        let textView = try #require(scroll.documentView as? NSTextView)
        let view = LogTextView.Coordinator(model: model)
        view.attach(scroll: scroll, text: textView)
        view.sync()
        #expect(textView.string == text(1...4))

        // three more lines: the buffer keeps five, so two leave the top
        let h = try FileHandle(forWritingTo: log)
        try h.seekToEnd()
        try h.write(contentsOf: Data(text(5...7).utf8))
        try h.close()
        for _ in 0..<300 {
            if model.buffer.lines.last?.text == line(7) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.buffer.lines.map(\.text) == (3...7).map(line))

        let edits = EditCounter()
        textView.textStorage?.delegate = edits
        let written = Flag()
        withObservationTracking {
            _ = model.buffer
            _ = model.changes
            _ = model.follow
            _ = model.query
            _ = model.currentMatch
        } onChange: { written.set() }
        view.sync()
        #expect(textView.string == text(3...7))
        #expect(edits.count == 1, "the lines that left and the lines that came, in one edit")
        #expect(!written.isSet, "drawing wrote to the model")

        // a filter is a redraw; what comes after it is appended as before
        model.query.process = "worker"
        view.sync()
        #expect(textView.string.isEmpty)
        #expect(model.visible(after: -1).isEmpty)
    }

    /// Scrolled up, the text above the reader stays: a cut at the top would
    /// slide what they read upward on every read of a busy log. The dropped
    /// lines leave once the view follows again.
    @Test func aScrolledUpViewKeepsItsTopUntilItFollowsAgain() async throws {
        let dir = try TempDir()
        let log = try dir.write("logs/bench.log", text(1...4))
        let model = LogViewModel(benchName: "frappe-bench", benchPath: dir.url.path, capacity: 5)
        model.start()
        defer { model.stop() }
        let scroll = NSTextView.scrollableTextView()
        let textView = try #require(scroll.documentView as? NSTextView)
        let view = LogTextView.Coordinator(model: model)
        view.attach(scroll: scroll, text: textView)
        view.sync()
        model.follow = false

        func write(_ range: ClosedRange<Int>) async throws {
            let h = try FileHandle(forWritingTo: log)
            try h.seekToEnd()
            try h.write(contentsOf: Data(text(range).utf8))
            try h.close()
            for _ in 0..<300 {
                if model.buffer.lines.last?.text == line(range.upperBound) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(model.buffer.lines.last?.text == line(range.upperBound))
        }

        try await write(5...7)
        view.sync()
        #expect(textView.string == text(1...7), "the first line read stays the first line")
        try await write(8...9)
        view.sync()
        #expect(textView.string == text(1...9))

        model.follow = true
        view.sync()
        #expect(textView.string == text(5...9), "following again: the text is the buffer")
    }
}

/// Counts the text storage's edits (one per processEditing).
final class EditCounter: NSObject, NSTextStorageDelegate {
    private(set) var count = 0

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        count += 1
    }
}
