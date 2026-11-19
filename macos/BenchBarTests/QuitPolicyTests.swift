import Testing
@testable import BenchBar

/// MAC-13: the quit rules, away from AppDelegate. MAC-1: a running change asks too.
@Suite("Quit policy")
struct QuitPolicyTests {
    private func facts(lab: Bool = true, setup: Bool = false, bench: String? = nil, people: Int = 0, guest: Bool = false,
                       change: String? = nil) -> QuitPolicy.Facts {
        QuitPolicy.Facts(labOn: lab, setupRunning: setup, hostedBench: bench, people: people, guestForwarder: guest,
                         changeRunning: change)
    }

    @Test func nothingSharedQuitsAtOnce() {
        #expect(QuitPolicy.question(facts()) == nil)
    }

    @Test func withTheLabOffNothingAsks() {
        #expect(QuitPolicy.question(facts(lab: false, setup: true, bench: "/b", people: 2, guest: true)) == nil)
    }

    @Test func aRunningSetupAsksFirst() {
        let question = QuitPolicy.question(facts(setup: true, bench: "/b", people: 2, guest: true))
        #expect(question?.title == "Sharing setup is still running.")
        #expect(question?.detail.contains("halfway") == true)
    }

    @Test func peopleInARoomAreCountedAndTheBenchIsNamed() {
        #expect(QuitPolicy.question(facts(bench: "/Users/you/frappe-bench", people: 1))?.detail
                == "1 person is in the room on frappe-bench. Quitting disconnects them.")
        #expect(QuitPolicy.question(facts(bench: "/Users/you/v16", people: 3))?.detail
                == "3 people are in the room on v16. Quitting disconnects them.")
        #expect(QuitPolicy.question(facts(bench: "/b", people: 2, guest: true))?.title == "People are in your room.")
    }

    @Test func aJoinedRoomAsksLast() {
        #expect(QuitPolicy.question(facts(guest: true))?.title == "You are connected to a room.")
    }

    /// MAC-1: an install, repair, app update or site change must not be cut off by Cmd-Q.
    @Test func aRunningChangeAsksAndCanBeWaitedFor() throws {
        let question = try #require(QuitPolicy.question(facts(change: "Updating erpnext")))
        #expect(question.title == "Updating erpnext is still running.")
        #expect(question.canWaitForIt)
    }

    @Test func aChangeAsksWithTheLabOffToo() {
        #expect(QuitPolicy.question(facts(lab: false, change: "Repair")) != nil)
    }

    @Test func aChangeComesBeforeTheShareCases() throws {
        let question = try #require(QuitPolicy.question(facts(setup: true, bench: "/b", people: 2, guest: true, change: "Installing macdev")))
        #expect(question.canWaitForIt)
        #expect(question.title == "Installing macdev is still running.")
    }

    @Test func shareCasesCannotBeWaitedFor() throws {
        #expect(try #require(QuitPolicy.question(facts(setup: true))).canWaitForIt == false)
        #expect(try #require(QuitPolicy.question(facts(bench: "/b", people: 1))).canWaitForIt == false)
        #expect(try #require(QuitPolicy.question(facts(guest: true))).canWaitForIt == false)
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
