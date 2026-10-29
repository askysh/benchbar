import Foundation
import Testing
@testable import BenchBar

@Suite("Folder discovery", .serialized)
struct DiscoveryTests {
    let base: BenchStoreTests
    init() throws { base = try BenchStoreTests() }

    func scanJSON() throws -> String {
        var result = try JSONSerialization.jsonObject(with: Data(base.listJSON(installed: false).utf8)) as! [String: Any]
        result["root"] = "/Projects with spaces"
        result["warnings"] = ["Cannot read folder: /Projects with spaces/private"]
        return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
    }

    func makeDiscovery() async throws -> (BenchStore, BenchDiscovery) {
        base.cli.answer("list", json: try Fixture.string("list-empty"))
        base.cli.answer("scan", json: try scanJSON())
        base.cli.answer("status", json: base.statusJSON("stopped"))
        let store = base.makeStore()
        await store.start(polling: false)
        return (store, BenchDiscovery(store: store))
    }

    @Test func scanningFindsSelectableBenchesWithoutAdopting() async throws {
        let (_, discovery) = try await makeDiscovery()
        await discovery.scan(folder: "/Projects with spaces").value
        #expect(discovery.results.map(\.path) == [base.benchPath])
        #expect(discovery.selected == [base.benchPath])
        #expect(discovery.warnings.count == 1)
        #expect(discovery.isScanning == false)
        #expect(base.settings.scanFolder == "/Projects with spaces")
        #expect(!base.cli.calls.contains { ["register", "adopt", "up", "repair"].contains($0[0]) })
    }

    @Test func addingSelectionRemembersItAndReloadsTheList() async throws {
        let (store, discovery) = try await makeDiscovery()
        await discovery.scan(folder: "/Projects with spaces").value
        base.cli.answer("register", json: base.listJSON(installed: false))
        base.cli.answer("list", json: base.listJSON(installed: false))
        await discovery.addSelected()
        #expect(store.benches.map(\.path) == [base.benchPath])
        #expect(discovery.selected.isEmpty)
        #expect(discovery.message == "Added 1 bench to BenchBar.")
        #expect(!base.cli.calls.contains { $0[0] == "adopt" })
        await discovery.scan(folder: "/Projects with spaces").value
        #expect(discovery.selected.isEmpty, "Known benches are not selected for adding again")
    }

    /// Adopt Existing Bench: a scan of the bench's own folder leads to its
    /// setup plan, without becoming the folder Find Benches offers.
    @Test func adoptingScansOneBenchFolder() async throws {
        let (store, discovery) = try await makeDiscovery()
        base.settings.scanFolder = "/Users/you/dev"
        await discovery.scan(folder: base.benchPath, remember: false).value
        let candidate = try #require(discovery.adoptCandidate)
        #expect(candidate.path == base.benchPath)
        #expect(PortSetupRun(summaries: [candidate], store: store).title == "Set Up frappe-bench")
        #expect(base.settings.scanFolder == "/Users/you/dev")
        #expect(!base.cli.calls.contains { ["register", "adopt", "up", "repair"].contains($0[0]) })

        base.cli.answer("list", json: base.listJSON(installed: true))
        await store.reloadBenches()
        #expect(discovery.adoptCandidate == nil, "a managed bench has nothing to adopt")
    }

    /// Hundreds of "Stopped at 6 folders deep" are one line; other warnings stay.
    @Test func deepFolderWarningsAreOneLine() {
        let deep = (1...117).map { "Stopped at 6 folders deep: /Users/you/dev/a/b/c/d/e/f\($0)" }
        let lines = BenchDiscovery.warningLines(deep + ["Cannot read folder: /Users/you/dev/private"])
        #expect(lines == ["Stopped at 6 folders deep in 117 folders: a bench deeper than that is not found. Choose a folder closer to it.",
                          "Cannot read folder: /Users/you/dev/private"])
        #expect(BenchDiscovery.warningLines([deep[0]]) == [deep[0]])
    }

    /// A bench BenchBar already manages is shown as managed: not selectable.
    @Test func managedBenchesAreNotSelectable() async throws {
        let (store, discovery) = try await makeDiscovery()
        base.cli.answer("list", json: base.listJSON(installed: true))
        await store.reloadBenches()
        await discovery.scan(folder: "/Projects with spaces").value
        #expect(discovery.managedPaths == [base.benchPath])
        #expect(discovery.selectablePaths.isEmpty && discovery.selected.isEmpty)
    }

    @Test func aFailedScanClearsOldResultsAndShowsAnError() async throws {
        let (_, discovery) = try await makeDiscovery()
        await discovery.scan(folder: "/Projects with spaces").value
        base.cli.answer("scan", CommandOutput(exitCode: 1, stdout: "", stderr: "[FAIL] not a readable folder"))
        await discovery.scan(folder: "/Missing").value
        #expect(discovery.results.isEmpty && discovery.selected.isEmpty)
        #expect(discovery.error?.contains("not a readable folder") == true)
        #expect(discovery.isScanning == false)
    }

    @Test func cancellingDoesNotPublishLateResults() async throws {
        let (_, discovery) = try await makeDiscovery()
        let task = discovery.scan(folder: "/Projects with spaces")
        discovery.cancelScan()
        await task.value
        #expect(!discovery.isScanning && discovery.results.isEmpty)
        #expect(discovery.message == "Scan cancelled.")
    }

    @Test func failedRegistrationKeepsSelectionForRetry() async throws {
        let (_, discovery) = try await makeDiscovery()
        await discovery.scan(folder: "/Projects with spaces").value
        base.cli.answer("register", CommandOutput(exitCode: 1, stdout: "", stderr: "[FAIL] Another run is active"))
        await discovery.addSelected()
        #expect(discovery.selected == [base.benchPath])
        #expect(discovery.error?.contains("Another run") == true)
        #expect(!discovery.isAdding)
    }
}
