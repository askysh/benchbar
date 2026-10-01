import AppKit
import QuartzCore

/// Plays a runner on a CALayer.
///
/// One `CAKeyframeAnimation` on the layer's `contents`, in discrete mode,
/// flips through the frames. Core Animation runs it in the render server,
/// so the app does no work per frame. Speed changes go through
/// `layer.speed`, never by swapping images on a timer.
///
/// A layer draws its `contents` as they are: it ignores `NSImage.isTemplate`.
/// So template frames are tinted here with the menu bar's text color, and
/// tinted again when the menu bar turns light or dark.
final class RunnerAnimator {
    /// Add this to the status bar button's layer.
    let layer = CALayer()

    private(set) var runner: Runner
    private(set) var plan: RunnerPlan?
    private(set) var speed: Double = 1
    private(set) var isPaused = false
    private var tint: CGColor
    /// Tinted frames for the current runner and tint, built on first use.
    private var tinted: [RunnerPose: [CGImage]] = [:]
    /// When the current stumble or settle ends, in media time, so a re-tint
    /// after it holds the still frame instead of playing it again.
    private var finiteEndsAt: CFTimeInterval = 0

    static let animationKey = "frames"

    init(runner: Runner, tint: CGColor = CGColor(gray: 0, alpha: 0.85)) {
        self.runner = runner
        self.tint = tint
        layer.bounds = CGRect(origin: .zero, size: runner.size)
        layer.contentsScale = Runner.scale
        layer.contentsGravity = .resize
        layer.magnificationFilter = .nearest
        // no implicit fades when contents or geometry change
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    // MARK: inputs

    func setRunner(_ runner: Runner) {
        guard !runner.isSame(as: self.runner) else { return }
        self.runner = runner
        tinted = [:]
        layer.bounds = CGRect(origin: .zero, size: runner.size)
        replay()
    }

    func setTint(_ color: CGColor) {
        guard color != tint else { return }
        tint = color
        tinted = [:]
        replay()
    }

    /// Plays a plan; the same plan again is a no-op, so a crashed to paused
    /// move (both stumble) does not start the stumble over. A new plan (a
    /// state change) plays from the start, settle loops included.
    func play(_ plan: RunnerPlan) {
        guard plan != self.plan else { return }
        self.plan = plan
        finiteEndsAt = 0
        start(plan, finished: false)
    }

    /// Speed of the running loop: 1 is idle, 12 is flat out. Other poses
    /// keep their own pace. The layer plays no faster than
    /// `RunnerPose.maxFPS` whatever the speed.
    func setSpeed(_ speed: Double) {
        let clamped = min(max(speed, SpeedMapping.range.lowerBound), SpeedMapping.range.upperBound)
        guard abs(clamped - self.speed) >= 0.05 else { return }
        self.speed = clamped
        applySpeed()
    }

    /// Freezes the current frame (sleep, screen lock, the menu bar hidden).
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        applySpeed()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        applySpeed()
    }

    // MARK: building the animation

    private func replay() {
        guard let plan else { return }
        start(plan, finished: CACurrentMediaTime() >= finiteEndsAt)
    }

    private func start(_ plan: RunnerPlan, finished: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        layer.removeAnimation(forKey: Self.animationKey)
        let built = Self.animation(for: plan, frames: frames(for:), finished: finished)
        // the model value is what shows when no animation runs, and what a
        // finite animation (the stumble, the settle loops) rests on when it ends
        layer.contents = built.rest
        applySpeed()
        if let animation = built.animation {
            layer.add(animation, forKey: Self.animationKey)
            if animation.repeatCount.isFinite, !finished {
                finiteEndsAt = CACurrentMediaTime() + animation.duration * Double(animation.repeatCount)
            }
        }
    }

    /// The keyframe animation for a plan, and the frame to rest on.
    /// Static so tests can check it without a layer or a window.
    /// `finished`: the stumble or the settle loops already played.
    nonisolated static func animation(
        for plan: RunnerPlan,
        frames: (RunnerPose) -> [CGImage],
        finished: Bool = false
    ) -> (animation: CAKeyframeAnimation?, rest: CGImage?) {
        switch plan {
        case .still(let pose):
            return (nil, restFrame(pose, frames(pose)))

        case .loop(let pose):
            let images = frames(pose)
            guard images.count > 1 else { return (nil, images.first) }
            let perFrame = 1 / pose.baseFPS
            let animation = keyframes(images, durations: Array(repeating: perFrame, count: images.count))
            animation.repeatCount = .infinity
            return (animation, images[0])

        case .settle(let pose, let times):
            let images = frames(pose)
            let rest = restFrame(pose, images)
            guard images.count > 1, !finished else { return (nil, rest) }
            let animation = keyframes(images, durations: Array(repeating: 1 / pose.baseFPS, count: images.count))
            // removed when done (keyframes sets it): the layer shows `rest`
            animation.repeatCount = Float(max(times, 1))
            return (animation, rest)

        case .stumble(let times, let then):
            let alert = frames(then)
            let rest = restFrame(then, alert)
            if finished { return (nil, rest) }
            let stumble = frames(.crashed)
            var images: [CGImage] = []
            var durations: [CFTimeInterval] = []
            for _ in 0..<max(times, 1) {
                images += stumble
                durations += Array(repeating: 1 / RunnerPose.crashed.baseFPS, count: stumble.count)
            }
            images += alert
            durations += Array(repeating: 1 / then.baseFPS, count: alert.count)
            guard images.count > 1 else { return (nil, rest) }
            let animation = keyframes(images, durations: durations)
            animation.repeatCount = 1
            return (animation, rest)
        }
    }

    /// The alert pose ends a stumble, so it rests on its last frame; every
    /// other pose rests on its first.
    nonisolated static func restFrame(_ pose: RunnerPose, _ images: [CGImage]) -> CGImage? {
        pose == .alert ? images.last : images.first
    }

    /// A discrete keyframe animation: frame i shows for durations[i].
    /// In discrete mode keyTimes has one more entry than values: each value
    /// holds from its key time to the next, and the last entry is 1.
    nonisolated static func keyframes(_ images: [CGImage], durations: [CFTimeInterval]) -> CAKeyframeAnimation {
        let total = durations.reduce(0, +)
        var times: [NSNumber] = [0]
        var elapsed: CFTimeInterval = 0
        for duration in durations.dropLast() {
            elapsed += duration
            times.append(NSNumber(value: elapsed / total))
        }
        times.append(1)

        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.calculationMode = .discrete
        animation.values = images
        animation.keyTimes = times
        animation.duration = total
        animation.isRemovedOnCompletion = true
        return animation
    }

    // MARK: speed

    /// Changes layer.speed without a jump: the layer's local time is
    /// (parent time - beginTime) * speed + timeOffset, so pinning beginTime
    /// to now and timeOffset to the current local time keeps the animation
    /// at the frame it was on.
    private func applySpeed() {
        let target: Float
        if isPaused {
            target = 0
        } else if plan?.followsSpeed == true {
            // the speed keeps its 1 to 12 range; the layer stops at 30 fps
            target = Float(min(speed, RunnerPose.maxFPS / RunnerPose.running.baseFPS))
        } else {
            target = 1
        }
        guard layer.speed != target else { return }
        let now = CACurrentMediaTime()
        let parentNow = layer.superlayer?.convertTime(now, from: nil) ?? now
        let localNow = layer.convertTime(now, from: nil)
        layer.beginTime = parentNow
        layer.timeOffset = localNow
        layer.speed = target
    }

    // MARK: frames

    private func frames(for pose: RunnerPose) -> [CGImage] {
        let raw = runner.frames(for: pose)
        guard runner.isTemplate else { return raw }
        if let cached = tinted[pose] { return cached }
        let made = raw.map { Self.tint($0, with: tint) }
        tinted[pose] = made
        return made
    }

    /// The template frame's alpha, filled with `color`.
    nonisolated static func tint(_ image: CGImage, with color: CGColor) -> CGImage {
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        // clipping to an image with alpha uses the alpha as coverage
        context.clip(to: rect, mask: image)
        context.setFillColor(color)
        context.fill(rect)
        return context.makeImage() ?? image
    }
}
