import AppKit
import Observation

/// Owns the menu bar item: the runner layer on its button, and the logic
/// that picks what the runner does from the selected bench's state.
final class StatusItemController {
    let statusItem: NSStatusItem
    let animator: RunnerAnimator

    private let store: BenchStore
    private let settings: AppSettings
    private let library: RunnerLibrary
    private let speed: SpeedController
    private let activity: SystemActivityMonitor
    private var appearanceObservation: NSKeyValueObservation?
    private var occlusionObserver: NSObjectProtocol?
    /// The item's window is on screen: false under a full screen app that
    /// hides the menu bar, or on a display that sleeps. The runner is paused
    /// and the speed loop stops while it is hidden.
    private var itemVisible = true

    /// Room on each side of the runner inside the button.
    static let padding: CGFloat = 3

    init(store: BenchStore, settings: AppSettings, library: RunnerLibrary, speed: SpeedController = SpeedController(),
         activity: SystemActivityMonitor = SystemActivityMonitor()) {
        self.store = store
        self.settings = settings
        self.library = library
        self.speed = speed
        self.activity = activity
        let runner = library.runner(settings.runnerID)
        animator = RunnerAnimator(runner: runner)
        statusItem = NSStatusBar.system.statusItem(withLength: runner.pointWidth + Self.padding * 2)
        setUpButton()

        speed.onSpeed = { [weak self] value in self?.animator.setSpeed(value) }
        // the speed loop's snapshots are the speed bench's resource history
        speed.onSnapshot = { [weak store] target, snapshot in store?.record(snapshot, bench: target.bench, root: target.pid) }
        activity.onActiveChange = { [weak self] active in self?.activeChanged(active) }
        activity.onReduceMotionChange = { [weak self] _ in self?.update() }
        activity.onLowPowerChange = { [weak self] on in
            Log.poll.info("Low Power Mode \(on ? "on" : "off", privacy: .public)")
            self?.update()
        }
        activity.start()
        observeOcclusion()
        observeSettings()
        update()
    }

    private func setUpButton() {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        button.layer?.addSublayer(animator.layer)
        placeRunner()
        button.setAccessibilityLabel("BenchBar")
        // the menu bar turns light or dark with the wallpaper (and in the
        // macOS 26 transparent menu bar), so follow the button's appearance
        appearanceObservation = button.observe(\.effectiveAppearance, options: [.initial]) { [weak self] button, _ in
            MainActor.assumeIsolated { self?.appearanceChanged(button) }
        }
    }

    /// Centers the runner in the button.
    private func placeRunner() {
        guard let button = statusItem.button else { return }
        statusItem.length = animator.runner.pointWidth + Self.padding * 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        animator.layer.position = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        animator.layer.autoresizingMask = [.layerMinXMargin, .layerMaxXMargin, .layerMinYMargin, .layerMaxYMargin]
        CATransaction.commit()
    }

    private func appearanceChanged(_ button: NSStatusBarButton) {
        var color = CGColor(gray: 0, alpha: 0.85)
        // labelColor resolves to the menu bar's own text color for this appearance
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.cgColor
        }
        animator.setTint(color)
    }

    // MARK: state

    /// Called whenever the store, the settings, Reduce Motion, Low Power
    /// Mode, sleep or the item's visibility change.
    func update() {
        let runner = library.runner(settings.runnerID)
        if !runner.isSame(as: animator.runner) {
            animator.setRunner(runner)
            placeRunner()
        }

        let state = store.displayState
        let plan = RunnerPlan.forState(state, reduceMotion: activity.reduceMotion)
        animator.play(plan)
        updateSpeed(plan)
        describe(state)
    }

    /// The 2 second libproc loop runs only while someone can see the runner
    /// move: not asleep or locked, not in Low Power Mode (the runner plays
    /// at speed 1 there), not with the item hidden.
    private func updateSpeed(_ plan: RunnerPlan) {
        guard plan.followsSpeed, settings.speedEnabled, activity.isActive, !activity.lowPower, itemVisible,
              let bench = store.speedBench, let pid = bench.status?.pid, pid > 0 else {
            speed.stop()
            animator.setSpeed(1)
            store.setSpeedSampled(nil)
            return
        }
        speed.run(SpeedTarget(bench: bench.path, pid: pid, ports: bench.summary.ports))
        store.setSpeedSampled(bench.path)
    }

    private func activeChanged(_ active: Bool) {
        if active {
            store.resume()
        } else {
            store.suspend()
        }
        applyPause()
        update()
    }

    /// One rule for the frozen frame: asleep or locked, or the item hidden.
    private func applyPause() {
        if activity.isActive && itemVisible {
            animator.resume()
        } else {
            animator.pause()
        }
    }

    /// Any window's occlusion change re-reads the item's own: its window can
    /// be replaced when the menu bar is rebuilt, so it is not the filter.
    private func observeOcclusion() {
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.occlusionChanged() }
            }
    }

    private func occlusionChanged() {
        guard let window = statusItem.button?.window else { return }
        let visible = window.occlusionState.contains(.visible)
        guard visible != itemVisible else { return }
        itemVisible = visible
        Log.poll.info("menu bar item \(visible ? "visible" : "hidden", privacy: .public)")
        applyPause()
        update()
    }

    /// Tooltip and VoiceOver text: the runner itself says nothing. Set only
    /// when it changed, so an unchanged state costs the button nothing.
    private func describe(_ state: BenchState) {
        let text: String
        if case .missing = store.cli {
            text = "BenchBar: benchbar CLI not found"
        } else if store.benches.count > 1 {
            text = "BenchBar: \(store.benches.count) benches, \(BenchAggregate.upText(store.benches.map(\.state)))"
        } else if let bench = store.selected {
            text = "BenchBar: \(bench.name) \(Self.word(for: state))"
        } else {
            text = "BenchBar: no bench"
        }
        guard let button = statusItem.button else { return }
        if button.toolTip != text { button.toolTip = text }
        let word = Self.word(for: state)
        if button.accessibilityValue() as? String != word { button.setAccessibilityValue(word) }
    }

    static func word(for state: BenchState) -> String {
        switch state {
        case .stopped: "stopped"
        case .starting: "starting"
        case .running: "running"
        case .crashed: "crashed"
        case .paused: "paused after crashes"
        case .unknown: "state unknown"
        }
    }

    /// Re-runs update when a setting the runner uses changes. Observation
    /// fires once per registration, so it registers again each time.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.runnerID
            _ = settings.speedEnabled
            _ = library.custom.count
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observeSettings()
            }
        }
    }
}
