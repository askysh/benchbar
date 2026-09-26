import Foundation
import Testing
@testable import BenchBar

@Suite("Log model")
struct LogModelTests {
    @Test func honchoPrefixes() {
        #expect(LogParser.process(of: "10:00:01 web.1        | * Running on http://127.0.0.1:8000") == "web")
        #expect(LogParser.process(of: "10:00:01 redis_queue.1 | Ready to accept connections") == "redis_queue")
        #expect(LogParser.process(of: "10:00:01 system | web.1 started (pid=11)") == "system")
        #expect(LogParser.process(of: "  File \"x.py\", line 1") == nil)
        #expect(LogParser.process(of: "2026-09-26 honcho missing; run: benchbar repair") == nil)
        #expect(LogParser.process(of: "") == nil)
    }

    @Test func tracebackLinesBelongToTheirProcessAndStayRed() {
        var buffer = LogBuffer()
        buffer.append("""
        10:00:01 web.1 | GET /app 200
        10:00:02 web.1 | Traceback (most recent call last):
          File "x.py", line 1, in <module>
        ValueError: bad
        10:00:03 worker.1 | job done

        """)
        let lines = buffer.lines
        #expect(lines.map(\.process) == ["web", "web", "web", "web", "worker"])
        #expect(lines.map(\.isError) == [false, true, true, true, false])
    }

    @Test func partialLinesWaitForTheirEnd() {
        var buffer = LogBuffer()
        #expect(buffer.append("10:00:01 web.1 | hel").isEmpty)
        let added = buffer.append("lo\n10:00:02 web.1 | next\n")
        #expect(added.map(\.text) == ["10:00:01 web.1 | hello", "10:00:02 web.1 | next"])
        #expect(added.map(\.id) == [0, 1])
    }

    @Test func memoryIsCapped() {
        var buffer = LogBuffer(capacity: 3)
        for i in 0..<10 { buffer.append("line \(i)\n") }
        #expect(buffer.lines.map(\.text) == ["line 7", "line 8", "line 9"])
        #expect(buffer.lines.first?.id == 7)
        buffer.clear()
        #expect(buffer.lines.isEmpty)
        #expect(buffer.append("again\n").first?.id == 10)
    }

    @Test func filterAndSearch() {
        var buffer = LogBuffer()
        buffer.append("10:00:01 web.1 | GET /api ok\n10:00:02 worker.1 | api job\n10:00:03 web.1 | POST /API\n")
        var query = LogQuery()
        #expect(query.visible(buffer.lines).count == 3)
        query.process = "web"
        let visible = query.visible(buffer.lines)
        #expect(visible.count == 2)
        query.search = "api"
        #expect(query.matches(in: visible) == [0, 2])
        query.search = "   "
        #expect(query.matches(in: visible).isEmpty)
    }

    @Test func searchCountAndWrap() {
        #expect(SearchText.describe(current: nil, total: 0, searching: false) == "")
        #expect(SearchText.describe(current: nil, total: 0, searching: true) == "no matches")
        #expect(SearchText.describe(current: 2, total: 12, searching: true) == "3 of 12")
        #expect(SearchText.step(nil, total: 3, forward: true) == 0)
        #expect(SearchText.step(nil, total: 3, forward: false) == 2)
        #expect(SearchText.step(2, total: 3, forward: true) == 0)
        #expect(SearchText.step(0, total: 3, forward: false) == 2)
        #expect(SearchText.step(0, total: 0, forward: true) == nil)
    }
}
