import Foundation

/// The store's safety poll: the rare look at every bench that catches what
/// the folder watcher and the heartbeat cannot (a hung runner, a bench
/// started with benchfg). A protocol, so the tests fire it by hand.
protocol SafetyPolling: AnyObject {
    func start(_ work: @escaping @MainActor @Sendable () async -> Void)
    func stop()
}

/// Every 5 minutes through NSBackgroundActivityScheduler, with 150 seconds
/// of tolerance at utility quality of service: macOS picks the moment,
/// batches it with other work and defers it while the Mac is busy.
final class BackgroundSafetyPoll: SafetyPolling {
    static let identifier = "com.akashmishra.benchbar.status"
    static let interval: TimeInterval = 300
    static let tolerance: TimeInterval = 150

    private let scheduler: NSBackgroundActivityScheduler
    private var scheduled = false

    init() {
        scheduler = NSBackgroundActivityScheduler(identifier: Self.identifier)
        scheduler.repeats = true
        scheduler.interval = Self.interval
        scheduler.tolerance = Self.tolerance
        scheduler.qualityOfService = .utility
    }

    func start(_ work: @escaping @MainActor @Sendable () async -> Void) {
        guard !scheduled else { return }
        scheduled = true
        Self.schedule(scheduler, work)
    }

    func stop() {
        scheduled = false
        scheduler.invalidate()
    }

    /// The block runs on the scheduler's own queue, not the main thread:
    /// it hops to the main actor for the work and reports back when done.
    nonisolated private static func schedule(_ scheduler: NSBackgroundActivityScheduler,
                                             _ work: @escaping @MainActor @Sendable () async -> Void) {
        scheduler.schedule { completion in
            let done = SendableCompletion(completion)
            Task { @MainActor in
                await work()
                done.call(.finished)
            }
        }
    }
}

/// NSBackgroundActivityScheduler's completion handler, passed to the task
/// that calls it once.
nonisolated private final class SendableCompletion: @unchecked Sendable {
    private let completion: NSBackgroundActivityScheduler.CompletionHandler
    init(_ completion: @escaping NSBackgroundActivityScheduler.CompletionHandler) { self.completion = completion }
    func call(_ result: NSBackgroundActivityScheduler.Result) { completion(result) }
}

/// What the store's legacy loop waits on between rounds. A protocol, so the
/// store tests run ten minutes of rounds in no time.
nonisolated protocol PollSleeper: Sendable {
    func sleep(for duration: Duration, tolerance: Duration) async
}

/// `Task.sleep` with a tolerance, so macOS can batch the wakeup with others.
nonisolated struct TaskSleeper: PollSleeper {
    func sleep(for duration: Duration, tolerance: Duration) async {
        try? await Task.sleep(for: duration, tolerance: tolerance)
    }
}
