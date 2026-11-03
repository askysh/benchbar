import Foundation
import Testing
@testable import BenchBar

@Suite struct ShareRouteTests {
    @Test func aJoinedRoomPageIsAShareOutcome() {
        let outcome = URLRouter.route(URL(string: "benchbar://share/0011223344556677/app/todo")!, benches: [], selected: nil)
        #expect(outcome == .share(.init(fp16: "0011223344556677", path: "/app/todo")))
    }

    @Test func anUnsafeShareLinkIsIgnoredAndOtherRoutesAreUntouched() {
        if case .ignore = URLRouter.route(URL(string: "benchbar://share/0011223344556677/api/method/x")!, benches: [], selected: nil) {} else {
            Issue.record("expected ignore")
        }
        #expect(URLRouter.shareRoute(URL(string: "benchbar://window")!) == nil)
    }
}
