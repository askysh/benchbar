import AppKit
import SwiftUI

/// A runner playing in a SwiftUI view, for the Menu Bar pane and the wizard.
/// It uses the same RunnerAnimator as the menu bar, but a built in runner is
/// drawn again at the preview's own size and the screen's backing scale
/// (`Runner.builtIn(_:renderedAt:)`), not the menu bar's 36 px frames
/// stretched: those were chunky at 3x and worse at 5x. A custom runner has
/// only its own bitmaps, so it is smoothed (linear) rather than pixelated.
struct RunnerPreview: NSViewRepresentable {
    var runner: Runner
    var state: BenchState
    var scale: CGFloat = 2

    func makeNSView(context: Context) -> RunnerPreviewView {
        RunnerPreviewView(runner: sharp(runner), scale: scale)
    }

    func updateNSView(_ view: RunnerPreviewView, context: Context) {
        view.show(runner: sharp(runner), state: state)
    }

    /// The runner redrawn for this size, kept per (id, scale) so a view
    /// update does not draw every frame again.
    private func sharp(_ runner: Runner) -> Runner {
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        let pixels = max(Runner.scale, (scale * backing).rounded(.up))
        return PreviewFrames.runner(runner, pixelsPerPoint: pixels)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RunnerPreviewView, context: Context) -> CGSize? {
        CGSize(width: runner.pointWidth * scale, height: Runner.pointHeight * scale)
    }
}

/// Built in runners drawn at a preview size, remembered. The preview shows one
/// runner at a time, so the cache holds a few entries at most.
@MainActor enum PreviewFrames {
    private static var cache: [String: Runner] = [:]

    static func runner(_ runner: Runner, pixelsPerPoint: CGFloat) -> Runner {
        let key = "\(runner.id)@\(pixelsPerPoint)"
        if let hit = cache[key] { return hit }
        guard let big = Runner.builtIn(runner.id, renderedAt: pixelsPerPoint),
              big.name == runner.name, big.author == runner.author else { return runner }
        if cache.count > 8 { cache.removeAll() }
        cache[key] = big
        return big
    }
}

final class RunnerPreviewView: NSView {
    private let animator: RunnerAnimator
    private let scale: CGFloat

    init(runner: Runner, scale: CGFloat) {
        animator = RunnerAnimator(runner: runner)
        self.scale = scale
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: runner.pointWidth * scale, height: Runner.pointHeight * scale)))
        wantsLayer = true
        animator.layer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        // custom runners are enlarged bitmaps: smooth, not blocky
        animator.layer.magnificationFilter = .trilinear
        layer?.addSublayer(animator.layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(runner: Runner, state: BenchState) {
        animator.setRunner(runner)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        animator.play(RunnerPlan.forState(state, reduceMotion: reduceMotion))
        // show the running loop at a lively pace, as if the bench were busy
        animator.setSpeed(state == .running ? 3 : 1)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        animator.layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        var color = CGColor(gray: 0, alpha: 0.85)
        effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.cgColor }
        animator.setTint(color)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeEffectiveAppearance()
    }
}
