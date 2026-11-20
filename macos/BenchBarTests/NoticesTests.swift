import Foundation
import Testing
@testable import BenchBar

/// The notices an update leaves (CLI `status --json` notices[], issue 188): decoded
/// from the CLI's own output, shown by the window until dismissed, and dismissed
/// through `benchbar notices --dismiss ID`.
@Suite("Update notices", .serialized)
struct NoticesTests {
    @Test func statusDecodesTheNoticesTheCLIPrints() throws {
        let status = try BenchJSON.decode(BenchStatus.self, from: Fixture.data("status-notices"))
        let notices = try #require(status.notices)
        #expect(notices.map(\.id) == ["listen-local", "unknown-flags", "pull-neutralise"])
        #expect(notices.map(\.switchBack) == ["benchbar listen all", "BENCHBAR_LENIENT_FLAGS=1", "benchbar pull --keep-secrets"])
        #expect(notices[0].doc?.hasSuffix("/whats-new/#the-bench-listens-on-this-computer-only") == true)
        #expect(notices[0].banner.hasSuffix("\n\nSwitch back: benchbar listen all"))
        #expect(notices[2].since == "0.9.0")
    }

    @Test func aStatusWithoutNoticesAndANoticeWithoutFieldsStillDecode() throws {
        let old = try BenchJSON.decode(BenchStatus.self, from: Fixture.data("status-stopped"))
        #expect(old.notices == nil)
        let json = #"{"schema_version":1,"bench":"/b","state":"stopped","notices":[{"id":"x"}]}"#
        let bare = try #require(try BenchJSON.decode(BenchStatus.self, from: Data(json.utf8)).notices?.first)
        #expect(bare.id == "x")
        #expect(bare.title == "x")
        #expect(bare.switchBack.isEmpty)
        #expect(bare.banner.isEmpty)
    }

    @Test func dismissRunsTheCLICommand() async throws {
        let runner = FakeRunner { _ in .ok(#"{"schema_version":1,"notices":[]}"#) }
        let client = CLIClient(executable: URL(fileURLWithPath: "/Users/you/.local/bin/benchbar"), runner: runner)
        try await client.dismissNotice("listen-local")
        #expect(runner.calls.first?.arguments == ["notices", "--dismiss", "listen-local", "--json"])
    }

    @Test func theStoreShowsTheNoticesAndDismissRemovesOne() async throws {
        let test = try BenchStoreTests()
        test.cli.answer("list", json: test.listJSON())
        test.cli.answer("status", json: try Fixture.string("status-notices")
            .replacingOccurrences(of: "/Users/you/frappe-bench", with: test.benchPath))
        test.cli.answer("notices", json: #"{"schema_version":1,"notices":[]}"#)
        let store = test.makeStore()
        await store.start(polling: false)
        #expect(store.notices.map(\.id) == ["listen-local", "unknown-flags", "pull-neutralise"])

        store.dismissNotice("listen-local")
        #expect(store.notices.map(\.id) == ["unknown-flags", "pull-neutralise"])
        await test.waitUntil { test.cli.calls.contains { $0.first == "notices" } }
        #expect(test.cli.calls.contains(["notices", "--dismiss", "listen-local", "--json"]))

        // a CLI without notices[] (an older one) leaves the list as it is
        test.cli.answer("status", json: test.statusJSON("stopped", reason: "manual"))
        await store.refresh(try #require(store.benches.first))
        #expect(store.notices.map(\.id) == ["unknown-flags", "pull-neutralise"])

        // the CLI says there are none left: the banner goes
        test.cli.answer("status", json: test.statusJSON("stopped", reason: "manual").replacingOccurrences(of: #""state":"stopped""#, with: #""state":"stopped","notices":[]"#))
        await store.refresh(try #require(store.benches.first))
        #expect(store.notices.isEmpty)
    }
}
