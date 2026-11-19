import Testing
@testable import BenchBar

/// MAC-13: the quit rules, away from AppDelegate.
@Suite("Quit policy")
struct QuitPolicyTests {
    private func facts(lab: Bool = true, setup: Bool = false, bench: String? = nil, people: Int = 0, guest: Bool = false) -> QuitPolicy.Facts {
        QuitPolicy.Facts(labOn: lab, setupRunning: setup, hostedBench: bench, people: people, guestForwarder: guest)
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
}
