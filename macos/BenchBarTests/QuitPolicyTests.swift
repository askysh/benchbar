import Foundation
import Testing
@testable import BenchBar

@Suite("Quit policy")
struct QuitPolicyTests {
    @Test func nothingRunningQuitsAtOnce() {
        #expect(QuitPolicy.prompt(for: QuitFacts()) == nil)
        #expect(QuitPolicy.prompt(for: QuitFacts(labOn: true)) == nil)
    }

    /// MAC-1: an install, repair, app update or site change must not be cut off by Cmd-Q.
    @Test func aRunningChangeAsksAndCanBeWaitedFor() throws {
        let prompt = try #require(QuitPolicy.prompt(for: QuitFacts(changeRunning: "Updating erpnext")))
        #expect(prompt.title == "Updating erpnext is still running.")
        #expect(prompt.canWaitForIt)
    }

    @Test func aChangeAsksWithTheLabOffToo() {
        #expect(QuitPolicy.prompt(for: QuitFacts(labOn: false, changeRunning: "Repair")) != nil)
    }

    @Test func aChangeComesBeforeTheShareCases() throws {
        let facts = QuitFacts(labOn: true, shareSetupRunning: true, changeRunning: "Installing macdev")
        #expect(try #require(QuitPolicy.prompt(for: facts)).canWaitForIt)
    }

    @Test func shareCasesNeedTheLabAndCannotBeWaitedFor() throws {
        let setup = QuitFacts(labOn: false, shareSetupRunning: true)
        #expect(QuitPolicy.prompt(for: setup) == nil)
        let on = QuitFacts(labOn: true, shareSetupRunning: true)
        let prompt = try #require(QuitPolicy.prompt(for: on))
        #expect(prompt.title == "Sharing setup is still running.")
        #expect(!prompt.canWaitForIt)
    }

    @Test func roomsNameThePeople() throws {
        var facts = QuitFacts(labOn: true)
        facts.hostedRoom = .init(bench: "frappe-bench", people: 1)
        #expect(try #require(QuitPolicy.prompt(for: facts)).detail == "1 person is in the room on frappe-bench. Quitting disconnects them.")
        facts.hostedRoom = .init(bench: "frappe-bench", people: 3)
        #expect(try #require(QuitPolicy.prompt(for: facts)).detail.hasPrefix("3 people are in the room"))
        facts = QuitFacts(labOn: true, guestForwarderUp: true)
        #expect(try #require(QuitPolicy.prompt(for: facts)).title == "You are connected to a room.")
    }

    @Test func quitWhenItFinishesFiresOnceAfterTheChangeEnds() {
        var wait = QuitAfterChange()
        let notArmed = wait.shouldQuitNow(changeRunning: false)
        wait.arm()
        let whileRunning = wait.shouldQuitNow(changeRunning: true)
        let whenDone = wait.shouldQuitNow(changeRunning: false)
        let again = wait.shouldQuitNow(changeRunning: false)
        #expect(!notArmed)
        #expect(!whileRunning)
        #expect(whenDone)
        #expect(!again, "once")
    }

    @Test func keepingRunningDisarms() {
        var wait = QuitAfterChange()
        wait.arm()
        wait.disarm()
        let fired = wait.shouldQuitNow(changeRunning: false)
        #expect(!fired)
    }
}
