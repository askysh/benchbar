import Foundation
import Testing
@testable import BenchBar

/// Move a site to another bench in the Mac app (#183, part of the move). The documents are the CLI's own shape (`site move
/// --dry-run --json` and `--apply TOKEN --yes --jsonl`); nothing here changes a bench, a database or /etc/hosts.
@Suite("Mac app site move (#183)", .serialized)
struct SiteMoveTests {
    let base: BenchStoreTests
    let v16 = "/Users/you/dev/v16-bench"
    let main = "/Users/you/frappe-bench"

    init() throws { base = try BenchStoreTests() }

    static let catalog = #"{"schema_version":1,"commands":[{"name":"site move","flags":[{"name":"--to-bench"},{"name":"--no-migrate"}]}]}"#
    static let oldCatalog = #"{"schema_version":1,"commands":[{"name":"site restore","flags":[]}]}"#

    func workbench(catalog: String? = nil) async throws -> (Workbench, BenchModel, FakeRunner) {
        base.cli.answer("list", json: try Fixture.string("list-two-benches"))
        base.cli.answer("status", json: try Fixture.string("status-v16-two-sites"))
        let runner = base.cli.runner()
        let store = BenchStore(settings: base.settings,
                               locator: CLILocator(home: base.dir.url, isExecutable: { $0 == "/fake/benchbar" }),
                               makeClient: { CLIClient(executable: $0, runner: runner) },
                               pinger: { _, _ in 200 })
        await store.start(polling: false)
        store.setWindow(WindowSight(isOpen: true, isVisible: true))
        let workbench = Workbench(store: store)
        if let catalog {
            base.cli.answer("commands", json: catalog)
            await workbench.loadCommands()
        }
        return (workbench, try #require(store.benches.first { $0.path == v16 }), runner)
    }

    // MARK: the documents

    @Test func thePlanReadsItsStepsAppsAddressAndWhatStays() throws {
        let plan = try BenchJSON.decode(SiteMovePlan.self, from: Fixture.data("site-move-plan"))
        #expect(plan.canRun && plan.token == String(repeating: "a", count: 64) && plan.site == "acme.localhost")
        #expect(plan.steps.map(\.id) == ["backup", "restore", "migrate", "check", "drop"])
        #expect(plan.apps == ["frappe", "erpnext"] && plan.missingApps.isEmpty && plan.migrate)
        #expect(plan.address?.urlBefore == "http://acme.localhost:8000" && plan.address?.urlAfter == "http://acme.localhost:8001")
        #expect(plan.address?.portChanges == true && plan.stays.count == 2 && !plan.needsStop)
        let facts = SiteMoveText.facts(plan)
        #expect(facts.first { $0.label == "Address" }?.text.hasPrefix("http://acme.localhost:8000 becomes http://acme.localhost:8001") == true)
        #expect(facts.first { $0.label == "To" }?.text == "/Users/you/dev/move-tgt")
    }

    @Test func aRunningSourceIsTheCLIsOwnStopTheBenchFirstWithItsCommand() throws {
        let plan = try BenchJSON.decode(SiteMovePlan.self, from: Fixture.data("site-move-plan-running"))
        #expect(!plan.canRun && plan.needsStop && plan.otherErrors.isEmpty)
        #expect(plan.errors == ["Stop the bench first: benchbar down --bench-dir /Users/you/dev/move-src"])
        #expect(plan.nextActions.first?.why.contains("writes made after it would be lost") == true)
        #expect(SiteMoveText.isStop("benchbar down --bench-dir /x") && SiteMoveText.isStop("/opt/homebrew/bin/benchbar down --bench-dir /x"))
        #expect(!SiteMoveText.isStop("benchbar up --bench-dir /x") && !SiteMoveText.isStop("down"))
    }

    @Test func aPlanWithErrorsNeverRunsAndKeepsTheCLIsReasons() throws {
        let plan = try BenchJSON.decode(SiteMovePlan.self, from: Fixture.data("site-move-plan-errors"))
        #expect(!plan.canRun && !plan.needsStop && plan.otherErrors.count == 2 && plan.missingApps == ["hrms"])
        #expect(plan.otherErrors[0].contains("the default site never moves"))
        var open = try BenchJSON.decode(SiteMovePlan.self, from: Fixture.data("site-move-plan"))
        open.needs = ["MARIADB_ROOT_PASSWORD"]
        #expect(!open.canRun, "an input a terminal would ask for cannot be answered here")
        open.needs = []
        open.token = ""
        #expect(!open.canRun, "no --apply with an empty token")
    }

    @Test func aDocumentOfAnotherShapeKeepsWhatItCanRead() throws {
        let odd = try BenchJSON.decode(SiteMovePlan.self, from: Data(#"{"schema_version":1,"site":"a.localhost","token":"T","steps":[{"id":"x","name":5},{"nope":1}],"apps":"x","hosts":3,"future":true}"#.utf8))
        #expect(odd.site == "a.localhost" && odd.steps.map(\.id) == ["x"] && odd.apps.isEmpty && odd.address == nil && !odd.canApply)
        #expect(throws: (any Error).self) { try BenchJSON.decode(SiteMovePlan.self, from: Data(#"{"schema_version":1,"token":"T"}"#.utf8)) }
    }

    // MARK: the arguments

    @Test func thePlanAndTheApplyShareTheirArgumentsAndTheApplyCarriesThePlansToken() {
        let request = SiteMoveRequest(site: "acme.localhost", target: "/t", noMigrate: false)
        #expect(request.planArguments(bench: v16) == ["site", "move", "acme.localhost", "--to-bench", "/t", "--dry-run", "--json", "--bench-dir", v16])
        #expect(request.applyArguments(token: "T", bench: v16) == ["site", "move", "acme.localhost", "--to-bench", "/t", "--apply", "T", "--yes", "--jsonl", "--bench-dir", v16])
        let skip = SiteMoveRequest(site: "acme.localhost", target: "/t", noMigrate: true)
        #expect(skip.planArguments(bench: v16).contains("--no-migrate") && skip.applyArguments(token: "T", bench: v16).contains("--no-migrate"),
                "the flag is part of the plan the token stands for")
        #expect(!request.planArguments(bench: v16).contains("--no-migrate"))
    }

    // MARK: the entry

    @Test func theEntryShowsOnlyWithTheCommandAndAnotherBench() async throws {
        let (old, bench, _) = try await workbench(catalog: Self.oldCatalog)
        #expect(!old.offersMove(from: bench))
        let (newer, newBench, _) = try await workbench(catalog: Self.catalog)
        #expect(newer.offersMove(from: newBench) && newer.moveTargets(for: newBench).map(\.path) == [main])
        #expect(!SiteMoveText.offered(catalog: try JSONDecoder().decode(CommandCatalog.self, from: Data(Self.catalog.utf8)), others: 0), "alone: nowhere to go")
        #expect(!SiteMoveText.offered(catalog: nil, others: 2))
        let rows = newBench.siteRows
        #expect(rows.contains { !SiteMoveText.canMove($0) } && rows.contains { SiteMoveText.canMove($0) }, "the default site is disabled")
        #expect(rows.first { $0.isDefault }.map(SiteMoveText.canMove) == false)
    }

    // MARK: through the workbench

    @Test func theReviewTakesNoChangeSlotAndTheMoveRunsByThePlansOwnToken() async throws {
        let (workbench, bench, runner) = try await workbench(catalog: Self.catalog)
        base.cli.answer("site move", json: try Fixture.string("site-move-plan"))
        let request = SiteMoveRequest(site: "acme.localhost", target: main, noMigrate: false)
        let plan = try await workbench.movePlan(request, on: bench).get()
        #expect(plan.canRun && workbench.result == nil && !runner.calls.contains { $0.arguments.contains("--apply") }, "reading changes nothing")

        base.cli.answer("site move", .ok(try Fixture.lines("site-move-apply")))
        let seen = StepLog()
        let outcome = try await workbench.moveSite(request, token: plan.token, on: bench) { seen.add($0) }.get()
        let apply = try #require(runner.calls.last { $0.arguments.contains("--apply") })
        #expect(apply.arguments == request.applyArguments(token: plan.token, bench: v16))
        #expect(apply.environment["BENCHBAR_SUDO"] == "gui" && apply.environment["BENCHBAR_CALLER"] == "app")
        #expect(apply.environment["BENCHBAR_NONINTERACTIVE"] == nil, "the CLI does not gate this on a person; the typed name is the decision")
        #expect(workbench.result?.succeeded == true && workbench.result?.title == "Move acme.localhost to frappe-bench")
        #expect(seen.ids == ["backup", "backup", "restore", "restore", "drop"] && outcome.steps.map(\.id) == ["backup", "restore", "drop"])
        #expect(outcome.steps.allSatisfy { $0.status == .done } && outcome.envelope.exit == 0)
        // the target bench and both backup lists are read again
        #expect(base.cli.calls.contains { $0.first == "status" && $0.contains(main) })
    }

    @Test func theEndShowsTheCLIsNextActionsWithTheNewAddress() throws {
        let envelope = ResultEnvelope.parse(try Fixture.lines("site-move-apply"))
        let steps = [InstallStep(id: "drop", name: "Drop it here", status: .done)]
        let done = SiteMoveText.result(site: "acme.localhost", target: "/Users/you/dev/move-tgt", outcome: SiteMoveOutcome(envelope: envelope, steps: steps))
        #expect(done.kind == .success && done.title == "acme.localhost moved to move-tgt")
        #expect(done.detail?.contains("http://acme.localhost:8001") == true && done.detail?.contains("benchbar up --bench-dir /Users/you/dev/move-tgt") == true)
        var warned = envelope
        warned.warnings = ["a partial copy"]
        #expect(SiteMoveText.result(site: "a", target: "/t/b", outcome: SiteMoveOutcome(envelope: warned, steps: [])).kind == .warning)
        #expect(SiteMoveText.progress(InstallStep(id: "x", name: "Restore", status: .running)) == "Restore")
        #expect(SiteMoveText.progress(InstallStep(id: "x", name: "Restore", status: .done)) == "Restore: done")
    }

    @Test func aStaleTokenIsRefusedWithNothingChangedAndAnswersWithReviewAgain() async throws {
        let (workbench, bench, _) = try await workbench(catalog: Self.catalog)
        base.cli.answer("site move", .init(exitCode: 1, stdout: try Fixture.lines("site-move-apply-stale"), stderr: ""))
        let request = SiteMoveRequest(site: "acme.localhost", target: main, noMigrate: false)
        guard case .failure(let error) = await workbench.moveSite(request, token: "T", on: bench, onStep: { _ in }) else {
            Issue.record("a refused token ran")
            return
        }
        #expect(StalePlan.isStale(error.message) && error.message.contains("Nothing was changed"))
        var flow = PlanReviewFlow<SiteMovePlan>(stage: .applying(try BenchJSON.decode(SiteMovePlan.self, from: Fixture.data("site-move-plan"))))
        let closes = flow.finish(error: error.message)
        #expect(!closes && flow.stage == .stale(error.message))
        let reads = flow.review()
        #expect(reads && flow.stage == .reading, "Review Again reads a fresh plan")
    }

    @Test func aFailedMoveShowsTheCLIsMessageAndStopBenchUsesTheAppsOwnStop() async throws {
        let (workbench, bench, runner) = try await workbench(catalog: Self.catalog)
        let failed = #"{"schema_version":1,"event":"done","exit":1,"error":"bench migrate failed in the target","changed":[],"warnings":[],"next_actions":[]}"#
        base.cli.answer("site move", .init(exitCode: 1, stdout: failed, stderr: ""))
        let request = SiteMoveRequest(site: "acme.localhost", target: main, noMigrate: false)
        guard case .failure(let error) = await workbench.moveSite(request, token: "T", on: bench, onStep: { _ in }) else {
            Issue.record("a failed run reported success")
            return
        }
        #expect(error.message.contains("bench migrate failed in the target") && !StalePlan.isStale(error.message))
        base.cli.answer("down", .ok(""))
        _ = await workbench.stopForMove(bench)
        #expect(runner.calls.contains { $0.arguments == ["down", "--plain", "--bench-dir", v16] })
    }
}

/// The step ids a run reported, in order.
nonisolated final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    func add(_ step: InstallStep) { lock.withLock { all.append(step.id) } }
    var ids: [String] { lock.withLock { all } }
}
