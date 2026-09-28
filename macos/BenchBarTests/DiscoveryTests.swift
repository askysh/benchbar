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
