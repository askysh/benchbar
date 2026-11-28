import Testing
@testable import BenchBar

/// MAC-13: the quit decision, away from AppDelegate and NSAlert.
@Suite("Quit coordinator")
struct QuitCoordinatorTests {
    private final class FakeEnvironment: QuitEnvironment {
        var facts: QuitPolicy.Facts
        var answer: Bool
        private(set) var asked: [QuitPolicy.Question] = []

        init(facts: QuitPolicy.Facts = QuitPolicy.Facts(labOn: false, setupRunning: false, guestForwarder: false), answer: Bool = false) {
            self.facts = facts
            self.answer = answer
        }

        func quitFacts() -> QuitPolicy.Facts { facts }
        func confirmQuit(_ question: QuitPolicy.Question) -> Bool {
            asked.append(question)
            return answer
        }
    }

    private func running(_ label: String) -> QuitPolicy.Facts {
        QuitPolicy.Facts(labOn: false, setupRunning: false, guestForwarder: false, changeRunning: label)
    }

    @Test func nothingRunningQuitsWithoutAsking() {
        let environment = FakeEnvironment()
        #expect(QuitCoordinator().reply(in: environment) == .terminateNow)
        #expect(environment.asked.isEmpty)
    }

    @Test func keepRunningCancelsTheQuit() {
        let environment = FakeEnvironment(facts: running("Installing macdev"), answer: false)
        let coordinator = QuitCoordinator()
        #expect(coordinator.reply(in: environment) == .terminateCancel)
        #expect(environment.asked.first?.title == "Installing macdev is still running.")
        #expect(!coordinator.isWaiting)
    }

    @Test func quitWhenItFinishesCancelsNowAndQuitsOnceWhenIdle() {
        let environment = FakeEnvironment(facts: running("Updating erpnext"), answer: true)
        let coordinator = QuitCoordinator()
        #expect(coordinator.reply(in: environment) == .terminateCancel)
        #expect(coordinator.isWaiting)
        #expect(!coordinator.storeIsIdle(changeRunning: true), "the change still runs")
        #expect(coordinator.storeIsIdle(changeRunning: false))
        #expect(!coordinator.storeIsIdle(changeRunning: false), "once")
    }

    @Test func anIdleStoreDoesNothingWhenNobodyWaits() {
        #expect(!QuitCoordinator().storeIsIdle(changeRunning: false))
    }

    @Test func quitAnywayQuitsAtOnceForAShareQuestion() {
        let facts = QuitPolicy.Facts(labOn: true, setupRunning: true, guestForwarder: false)
        let environment = FakeEnvironment(facts: facts, answer: true)
        let coordinator = QuitCoordinator()
        #expect(coordinator.reply(in: environment) == .terminateNow)
        #expect(!coordinator.isWaiting)
    }

    @Test func aLaterQuitWithNothingRunningDisarmsTheWait() {
        let environment = FakeEnvironment(facts: running("Repair"), answer: true)
        let coordinator = QuitCoordinator()
        _ = coordinator.reply(in: environment)
        #expect(coordinator.isWaiting)
        environment.facts = QuitPolicy.Facts(labOn: false, setupRunning: false, guestForwarder: false)
        #expect(coordinator.reply(in: environment) == .terminateNow)
        #expect(!coordinator.isWaiting)
    }
}
