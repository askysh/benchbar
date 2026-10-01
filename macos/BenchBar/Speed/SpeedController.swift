import Foundation

/// Samples a speed source every 2 seconds while a bench runs, smooths the
/// result and hands it to the animator. It is the app's one 2 second
/// libproc loop: each snapshot also goes to the bench's resource history,
/// so the charts never read the same tree a second time.
final class SpeedController {
    static let interval: Duration = .seconds(2)
    static let tolerance: Duration = .milliseconds(500)

    var onSpeed: ((Double) -> Void)?
    /// Every process tree snapshot, for the bench's resource history.
    var onSnapshot: ((SpeedTarget, ProcessTree.Snapshot) -> Void)?
    private(set) var target: SpeedTarget?

    private let source: any SpeedSource
    private var smoother = SpeedSmoother()
    private var task: Task<Void, Never>?

    init(source: any SpeedSource = ProcessTreeCPUSource()) {
        self.source = source
    }

    /// Starts sampling `target`, or keeps sampling it if it already is.
    func run(_ target: SpeedTarget) {
        guard target != self.target || task == nil else { return }
        stop()
        self.target = target
        // utility: a menu bar animation must not compete with the person's work
        task = Task(priority: .utility) { [weak self, source] in
            while !Task.isCancelled {
                let reading = await source.sample(target)
                guard !Task.isCancelled, let self else { return }
                if let snapshot = reading.snapshot { self.onSnapshot?(target, snapshot) }
                if let raw = reading.speed { self.onSpeed?(self.smoother.add(raw)) }
                try? await Task.sleep(for: Self.interval, tolerance: Self.tolerance)
            }
        }
    }

    /// Stops sampling and forgets the smoothed speed.
    func stop() {
        task?.cancel()
        task = nil
        target = nil
        smoother.reset()
    }
}
