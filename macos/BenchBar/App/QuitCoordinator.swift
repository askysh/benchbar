import Foundation

/// What the quit decision needs from the app around it: the facts to weigh and a way to ask.
/// `AppDelegate` is the one app implementation; the tests use a recording fake (MAC-13).
protocol QuitEnvironment: AnyObject {
    /// What is running right now (shares, rooms, a change).
    func quitFacts() -> QuitPolicy.Facts
    /// Shows the question. True: the person chose the second button (quit when it finishes, or quit anyway).
    func confirmQuit(_ question: QuitPolicy.Question) -> Bool
}

/// The answer to `applicationShouldTerminate`, without AppKit's type.
enum QuitReply: Equatable {
    case terminateNow
    case terminateCancel
}

/// The quit decision taken out of `AppDelegate`: it asks `QuitPolicy`, asks the person through the
/// environment and remembers "Quit when it finishes" until the store has nothing running.
final class QuitCoordinator {
    private var wait = QuitAfterChange()

    /// The person is waiting for a change to finish, then quits.
    var isWaiting: Bool { wait.armed }

    func reply(in environment: some QuitEnvironment) -> QuitReply {
        guard let question = QuitPolicy.question(environment.quitFacts()) else {
            wait.disarm()
            return .terminateNow
        }
        guard environment.confirmQuit(question) else {
            wait.disarm()
            return .terminateCancel
        }
        guard question.canWaitForIt else { return .terminateNow }
        // the store says when the change slot is free (`storeIsIdle`)
        wait.arm()
        return .terminateCancel
    }

    /// The store has nothing running: true once when the person asked to quit then.
    func storeIsIdle(changeRunning: Bool) -> Bool {
        wait.shouldQuitNow(changeRunning: changeRunning)
    }
}
