import Foundation
import Observation

/// One bench's log in the viewer: the tailer feeding a capped buffer, the
/// filter and search, and whether the view follows the end.
@Observable
final class LogViewModel {
    let benchName: String
    let benchPath: String
    private(set) var buffer = LogBuffer()
    var query = LogQuery() { didSet { if oldValue != query { currentMatch = nil; changes += 1 } } }
    /// Stick to the bottom as lines arrive; turned off when the user scrolls up.
    var follow = true
    var showPrevious = false { didSet { if oldValue != showPrevious { restart() } } }
    private(set) var currentMatch: Int?
    /// Bumped on every change the text view must redraw for (not per line).
    /// New lines are not a change: the view appends what follows the last
    /// line it drew (`visible(after:)`), so drawing never writes to the model.
    private(set) var changes = 0

    @ObservationIgnored private var tailer: LogTailer?
    @ObservationIgnored private let capacity: Int

    init(benchName: String, benchPath: String, capacity: Int = 5000) {
        self.benchName = benchName
        self.benchPath = benchPath
        self.capacity = capacity
        buffer = LogBuffer(capacity: capacity)
    }

    var fileURL: URL {
        URL(fileURLWithPath: benchPath).appendingPathComponent(showPrevious ? "logs/bench.previous.log" : "logs/bench.log")
    }

    var visible: [LogLine] { query.visible(buffer.lines) }
    /// The visible lines that came after line `id`, oldest first. The
    /// buffer's ids grow by one per line, so this is an index, not a search.
    func visible(after id: Int) -> [LogLine] {
        let lines = buffer.lines
        guard let first = lines.first?.id else { return [] }
        let start = max(0, id - first + 1)
        guard start < lines.count else { return [] }
        return query.visible(Array(lines[start...]))
    }
    var matches: [Int] { query.matches(in: visible) }
    var searchSummary: String {
        SearchText.describe(current: currentMatch, total: matches.count, searching: !query.search.trimmingCharacters(in: .whitespaces).isEmpty)
    }
    /// The line id of the current match, for the view to scroll to.
    var currentMatchID: Int? {
        guard let currentMatch, currentMatch < matches.count else { return nil }
        return matches[currentMatch]
    }

    func start() {
        restart()
    }

    func stop() {
        tailer?.stop()
        tailer = nil
    }

    func step(forward: Bool) {
        currentMatch = SearchText.step(currentMatch, total: matches.count, forward: forward)
        follow = false
        changes += 1
    }

    func clear() {
        buffer.clear()
        changes += 1
    }

    private func restart() {
        tailer?.stop()
        buffer = LogBuffer(capacity: capacity)
        currentMatch = nil
        let tailer = LogTailer(url: fileURL, onLines: { [weak self] chunk in
            self?.buffer.append(chunk)
        }, onReset: { [weak self] in
            // the runner started a new log: keep what was shown, mark the cut
            self?.buffer.append("--- log restarted ---\n")
        })
        self.tailer = tailer
        tailer.start()
        changes += 1
    }
}
