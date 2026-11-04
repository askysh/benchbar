import Foundation
import Testing
@testable import BenchBar

@Suite("Host ambient")
struct HostAmbientTests {
    @Test func iconState() {
        #expect(HostAmbient.icon([]) == .off)
        #expect(HostAmbient.icon([ShareStatus(state: .off)]) == .off)
        #expect(HostAmbient.icon([ShareStatus(state: .on)]) == .sharing)
        #expect(HostAmbient.icon([ShareStatus(state: .on, lockReason: .budget)]) == .attention)
    }

    @Test func eachEventHasOneNoticeWithExactWordsAndNoCode() {
        let joined = HostAmbient.notice(.joined(name: "Sam", model: "MacBook Air", ip: "192.168.1.31"), bench: "/b")
        #expect(joined?.title == "Sam joined")
        #expect(joined?.body.hasPrefix("Sam · MacBook Air · 192.168.1.31") == true)
        #expect(HostAmbient.notice(.left(name: "Sam"), bench: "/b")?.title == "Sam left")
        #expect(HostAmbient.notice(.reminder(minutes: 10), bench: "/b")?.title == "Sharing ends in 10 minutes")
        #expect(HostAmbient.notice(.reminder(minutes: 1), bench: "/b")?.title == "Sharing ends in 1 minute")
        #expect(HostAmbient.notice(.lockedByWrongCodes, bench: "/b")?.body.hasPrefix("Someone typed a wrong room code 10 times. The room is locked.") == true)
        #expect(HostAmbient.notice(.networkChanged, bench: "/b")?.body == "Checks are running again.")
        #expect(HostAmbient.notice(.stateChanged(from: .off, to: .on), bench: "/b") == nil)
    }

    @Test func benchConfirmOnlyWhileSharing() {
        #expect(HostAmbient.benchConfirm(nil, restart: false) == nil)
        #expect(HostAmbient.benchConfirm(ShareStatus(state: .off), restart: false) == nil)
        #expect(HostAmbient.benchConfirm(ShareStatus(state: .on), restart: false) == "This also ends sharing.")
        #expect(HostAmbient.benchConfirm(ShareStatus(state: .on, devicesOnline: 2), restart: false) == "This also ends sharing (2 guests online).")
        #expect(HostAmbient.benchConfirm(ShareStatus(state: .on, devicesOnline: 1), restart: true)?.contains("(1 guest online)") == true)
    }
}
