import Foundation
import Testing
@testable import BenchBar

@Suite("benchbar:// links")
struct URLRouterTests {
    let main = URLRouter.Bench(path: "/Users/me/frappe-bench", name: "frappe-bench", sites: ["macdev", "second"])
    let v16 = URLRouter.Bench(path: "/Users/me/v16-bench", name: "v16-bench", sites: ["v16dev"])

    func route(_ text: String, benches: [URLRouter.Bench]? = nil, selected: String? = nil) -> URLRouter.Outcome {
        URLRouter.route(URL(string: text)!, benches: benches ?? [main, v16], selected: selected)
    }

    @Test func everyRouteOnANamedBench() {
        for name in ["up", "down", "restart", "open", "logs", "window", "doctor"] {
            let expected = URLRouter.Route(rawValue: name)!
            #expect(route("benchbar://\(name)?bench=v16-bench") == .run(expected, bench: v16.path, site: nil))
        }
    }

    @Test func routeSpellings() {
        #expect(route("benchbar://UP?bench=v16-bench") == .run(.up, bench: v16.path, site: nil))
        #expect(route("benchbar://up/?bench=v16-bench") == .run(.up, bench: v16.path, site: nil))
        #expect(route("benchbar:up?bench=v16-bench") == .run(.up, bench: v16.path, site: nil))
        #expect(route("benchbar:///up?bench=v16-bench") == .run(.up, bench: v16.path, site: nil))
        #expect(route("BenchBar://up?bench=v16-bench") == .run(.up, bench: v16.path, site: nil))
    }

    /// Links can come from any web page: nothing destructive is a route.
    @Test func destructiveAndUnknownRoutesAreIgnored() {
        for word in ["repair", "drop", "restore", "pull", "install", "update", "delete", "wipe", "rm", "service", "site", ""] {
            if case .ignore = route("benchbar://\(word)?bench=v16-bench") {} else {
                Issue.record("\(word) was not ignored")
            }
        }
        #expect(route("https://up?bench=v16-bench") == .ignore("not a benchbar:// link"))
        #expect(route("benchbar://drop?bench=v16-bench") == .ignore("unknown route \"drop\""))
    }

    @Test func benchByPath() {
        #expect(route("benchbar://up?bench=/Users/me/v16-bench") == .run(.up, bench: v16.path, site: nil))
        #expect(route("benchbar://up?bench=/Users/me/v16-bench/") == .run(.up, bench: v16.path, site: nil))
        #expect(route("benchbar://up?bench=%2FUsers%2Fme%2Fv16-bench") == .run(.up, bench: v16.path, site: nil))
        if case .explain = route("benchbar://up?bench=/Users/me/nothing") {} else { Issue.record("unknown path ran") }
    }

    @Test func benchByNameIgnoresCase() {
        #expect(route("benchbar://down?bench=Frappe-Bench") == .run(.down, bench: main.path, site: nil))
    }

    @Test func twoBenchesWithOneNameNeedAPath() {
        let other = URLRouter.Bench(path: "/Users/me/work/frappe-bench", name: "frappe-bench", sites: [])
        guard case .explain(let text) = route("benchbar://up?bench=frappe-bench", benches: [main, other]) else {
            Issue.record("an ambiguous name ran"); return
        }
        #expect(text.contains("full path"))
        #expect(route("benchbar://up?bench=/Users/me/work/frappe-bench", benches: [main, other])
                == .run(.up, bench: other.path, site: nil))
    }

    @Test func withoutBenchUsesTheSelectedOrOnlyBench() {
        #expect(route("benchbar://restart", selected: v16.path) == .run(.restart, bench: v16.path, site: nil))
        #expect(route("benchbar://restart", benches: [main]) == .run(.restart, bench: main.path, site: nil))
        // a stale selection is not a choice
        #expect(route("benchbar://restart", benches: [main], selected: "/gone") == .run(.restart, bench: main.path, site: nil))
    }

    @Test func withoutBenchAndNoChoiceExplains() {
        guard case .explain(let text) = route("benchbar://up") else { Issue.record("ran without a bench"); return }
        #expect(text.contains("?bench="))
        guard case .explain = route("benchbar://up", benches: []) else { Issue.record("ran without benches"); return }
        // the window needs no bench
        #expect(route("benchbar://window") == .window)
        #expect(route("benchbar://window", benches: []) == .window)
    }

    @Test func siteOnlyForOpen() {
        #expect(route("benchbar://open?bench=frappe-bench&site=second") == .run(.open, bench: main.path, site: "second"))
        #expect(route("benchbar://open?bench=frappe-bench&site=SECOND") == .run(.open, bench: main.path, site: "second"))
        #expect(route("benchbar://up?bench=frappe-bench&site=second") == .run(.up, bench: main.path, site: nil))
        guard case .explain(let text) = route("benchbar://open?bench=frappe-bench&site=nope") else {
            Issue.record("an unknown site opened"); return
        }
        #expect(text.contains("nope"))
    }

    @Test func emptyQueryValuesCountAsMissing() {
        #expect(route("benchbar://open?bench=&site=", selected: main.path) == .run(.open, bench: main.path, site: nil))
    }
}
