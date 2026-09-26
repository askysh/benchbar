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
    private(set) var changes = 0
    /// Lines added since the last full redraw, appended by the view as is.
    private(set) var appended: [LogLine] = []

    @ObservationIgnored private var tailer: LogTailer?

    init(benchName: String, benchPath: String) {
        self.benchName = benchName
        self.benchPath = benchPath
    }

    var fileURL: URL {
        URL(fileURLWithPath: benchPath).appendingPathComponent(showPrevious ? "logs/bench.previous.log" : "logs/bench.log")
    }

    var visible: [LogLine] { query.visible(buffer.lines) }
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
        appended = []
        changes += 1
    }

    /// The view drew `appended`; forget it.
    func consumeAppended() { appended = [] }

    private func restart() {
        tailer?.stop()
        buffer = LogBuffer()
        appended = []
        currentMatch = nil
        let tailer = LogTailer(url: fileURL, onLines: { [weak self] chunk in
            guard let self else { return }
            let added = self.buffer.append(chunk)
            self.appended.append(contentsOf: added.filter(self.query.shows))
        }, onReset: { [weak self] in
            guard let self else { return }
            // the runner started a new log: keep what was shown, mark the cut
            let added = self.buffer.append("--- log restarted ---\n")
            self.appended.append(contentsOf: added)
        })
        self.tailer = tailer
        tailer.start()
        changes += 1
    }
}
