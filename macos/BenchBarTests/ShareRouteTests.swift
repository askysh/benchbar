import Foundation
import Testing
@testable import BenchBar

@Suite struct ShareRouteTests {
    @Test func aJoinedRoomPageIsAShareOutcome() {
        let outcome = URLRouter.route(URL(string: "benchbar://share/0011223344556677/app/todo")!, benches: [], selected: nil, lanRooms: true)
        #expect(outcome == .share(.init(fp16: "0011223344556677", path: "/app/todo")))
    }

    @Test func anUnsafeShareLinkIsIgnoredAndOtherRoutesAreUntouched() {
        if case .ignore = URLRouter.route(URL(string: "benchbar://share/0011223344556677/api/method/x")!, benches: [], selected: nil, lanRooms: true) {} else {
            Issue.record("expected ignore")
        }
        #expect(URLRouter.shareRoute(URL(string: "benchbar://window")!) == nil)
    }

    @Test func shareRoutesAreIgnoredWhileTheLabIsOff() {
        for link in ["benchbar://share/0011223344556677/app/todo", "benchbar://share/join?code=123456"] {
            guard case .ignore(let reason) = URLRouter.route(URL(string: link)!, benches: [], selected: nil, lanRooms: false) else {
                Issue.record("expected ignore for \(link)"); continue
            }
            #expect(reason.contains("lan-rooms"))
            #expect(!reason.contains("123456"))
        }
        // other routes are not touched by the lab
        #expect(URLRouter.route(URL(string: "benchbar://window")!, benches: [], selected: nil, lanRooms: false) == .window)
    }

    @Test func theNetworkItemAndSharingTabFollowTheLab() {
        #expect(SidebarModel([]).showsNetwork == false)
        #expect(SidebarModel([], showsNetwork: true).showsNetwork)
        #expect(!BenchTab.visible(lanRooms: false, sharingAvailable: true).contains(.sharing))
        #expect(!BenchTab.visible(lanRooms: true, sharingAvailable: false).contains(.sharing))
        #expect(BenchTab.visible(lanRooms: true, sharingAvailable: true).contains(.sharing))
        #expect(BenchTab.visible(lanRooms: false, sharingAvailable: true) == [.overview, .sites, .apps, .health])
    }
}
