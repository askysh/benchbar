import AppKit
import SwiftUI

/// A runner playing in a SwiftUI view, for the Settings window. It uses the
/// same RunnerAnimator as the menu bar, drawn twice as large.
struct RunnerPreview: NSViewRepresentable {
    var runner: Runner
    var state: BenchState
    var scale: CGFloat = 2

    func makeNSView(context: Context) -> RunnerPreviewView {
        RunnerPreviewView(runner: runner, scale: scale)
    }

    func updateNSView(_ view: RunnerPreviewView, context: Context) {
        view.show(runner: runner, state: state)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RunnerPreviewView, context: Context) -> CGSize? {
        CGSize(width: runner.pointWidth * scale, height: Runner.pointHeight * scale)
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
