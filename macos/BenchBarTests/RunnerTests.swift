import CoreGraphics
import QuartzCore
import Testing
@testable import BenchBar

@Suite("Runner animation")
struct RunnerTests {
    @Test func stateToAnimationFollowsTheTable() {
        #expect(RunnerPlan.forState(.stopped, reduceMotion: false) == .loop(.sleeping))
        #expect(RunnerPlan.forState(.starting, reduceMotion: false) == .loop(.starting))
        #expect(RunnerPlan.forState(.running, reduceMotion: false) == .loop(.running))
        #expect(RunnerPlan.forState(.crashed, reduceMotion: false) == .stumble(times: 3, then: .alert))
        #expect(RunnerPlan.forState(.paused, reduceMotion: false) == .stumble(times: 3, then: .alert))
        #expect(RunnerPlan.forState(.unknown, reduceMotion: false) == .loop(.unknown))
    }

    @Test func reduceMotionShowsOneStillPosePerState() {
        let expected: [BenchState: RunnerPose] = [
            .stopped: .sleeping, .starting: .starting, .running: .running,
            .crashed: .alert, .paused: .alert, .unknown: .unknown,
        ]
        for state in BenchState.allCases {
            #expect(RunnerPlan.forState(state, reduceMotion: true) == .still(expected[state]!))
        }
    }

    @Test func crashedAndPausedShareOnePlanSoTheStumbleDoesNotRestart() {
        #expect(RunnerPlan.forState(.crashed, reduceMotion: false) == RunnerPlan.forState(.paused, reduceMotion: false))
    }

    @Test func onlyTheRunningLoopFollowsTheSpeed() {
        let following = BenchState.allCases.filter { RunnerPlan.forState($0, reduceMotion: false).followsSpeed }
        #expect(following == [.running])
        #expect(!RunnerPlan.forState(.running, reduceMotion: true).followsSpeed)
    }

    @Test func loopIsOneDiscreteKeyframeAnimationOnContents() throws {
        let runner = Runner.builtIn("bench")
        let built = RunnerAnimator.animation(for: .loop(.running), frames: runner.frames(for:))
        let animation = try #require(built.animation)
        let frames = runner.frames(for: .running)
        #expect(animation.keyPath == "contents")
        #expect(animation.calculationMode == .discrete)
        #expect(animation.values?.count == frames.count)
        // discrete mode: one more key time than values, from 0 to 1
        #expect(animation.keyTimes?.count == frames.count + 1)
        #expect(animation.keyTimes?.first == 0)
        #expect(animation.keyTimes?.last == 1)
        #expect(animation.repeatCount == .infinity)
        #expect(abs(animation.duration - Double(frames.count) / RunnerPose.running.baseFPS) < 0.0001)
        #expect(built.rest === frames[0])
    }

    @Test func stumblePlaysThreeTimesThenRestsOnTheAlertPose() throws {
        let runner = Runner.builtIn("cup")
        let built = RunnerAnimator.animation(for: .stumble(times: 3, then: .alert), frames: runner.frames(for:))
        let animation = try #require(built.animation)
        let stumble = runner.frames(for: .crashed).count
        let alert = runner.frames(for: .alert)
        #expect(animation.values?.count == stumble * 3 + alert.count)
        #expect(animation.repeatCount == 1)
        #expect(animation.isRemovedOnCompletion)
        #expect(built.rest === alert.last)
        let expected = Double(stumble * 3) / RunnerPose.crashed.baseFPS + Double(alert.count) / RunnerPose.alert.baseFPS
        #expect(abs(animation.duration - expected) < 0.0001)
    }

    @Test func aFinishedStumbleJustHoldsTheAlert() {
        let runner = Runner.builtIn("bench")
        let built = RunnerAnimator.animation(for: .stumble(times: 3, then: .alert), frames: runner.frames(for:), stumbleDone: true)
        #expect(built.animation == nil)
        #expect(built.rest === runner.frames(for: .alert).last)
    }

    @Test func stillAndSingleFrameLoopsHaveNoAnimation() {
        let runner = Runner.builtIn("bench")
        #expect(RunnerAnimator.animation(for: .still(.running), frames: runner.frames(for:)).animation == nil)
        #expect(RunnerAnimator.animation(for: .loop(.unknown), frames: runner.frames(for:)).animation == nil)
    }

    @Test func keyTimesFollowUnevenDurations() {
        let image = Runner.builtIn("bench").frames(for: .alert)[0]
        let animation = RunnerAnimator.keyframes([image, image, image], durations: [1, 1, 2])
        #expect(animation.keyTimes == [0, 0.25, 0.5, 1])
        #expect(animation.duration == 4)
    }

    @Test func builtInRunnersHaveEveryPoseAtThe36PixelSize() {
        #expect(Runner.builtIns.map(\.id) == ["bench", "cup"])
        for runner in Runner.builtIns {
            #expect(runner.isTemplate)
            for pose in RunnerPose.allCases {
                let frames = runner.frames[pose] ?? []
                #expect(!frames.isEmpty, "\(runner.id) has no \(pose.rawValue) frames")
                for frame in frames {
                    #expect(frame.height == 36)
                    #expect(frame.width == Int(runner.pointWidth * 2))
                    #expect(Self.coverage(frame) > 0.05, "\(runner.id) \(pose.rawValue) frame is nearly empty")
                }
            }
        }
    }

    @Test func missingPoseFallsBackToRunning() {
        let bench = Runner.builtIn("bench")
        let partial = Runner(id: "x", name: "X", author: "", isTemplate: true, pointWidth: 24,
                             frames: [.running: bench.frames(for: .running), .sleeping: []])
        #expect(partial.frames(for: .sleeping).count == bench.frames(for: .running).count)
        #expect(partial.frames(for: .alert).count == bench.frames(for: .running).count)
    }

    @Test func unknownRunnerIDFallsBackToTheDefault() {
        #expect(Runner.builtIn("nope").id == Runner.defaultID)
    }

    @Test func tintKeepsTheShapeAndChangesTheColor() {
        let frame = Runner.builtIn("bench").frames(for: .alert)[0]
        let white = RunnerAnimator.tint(frame, with: CGColor(gray: 1, alpha: 1))
        #expect(white.width == frame.width && white.height == frame.height)
        #expect(abs(Self.coverage(white) - Self.coverage(frame)) < 0.01)
        #expect(Self.maxRed(white) > 200)
        #expect(Self.maxRed(frame) < 10)
    }

    // MARK: helpers

    /// Share of pixels that are mostly opaque.
    static func coverage(_ image: CGImage) -> Double {
        let pixels = rgba(image)
        var opaque = 0
        for i in stride(from: 3, to: pixels.count, by: 4) where pixels[i] > 128 { opaque += 1 }
        return Double(opaque) / Double(pixels.count / 4)
    }

    static func maxRed(_ image: CGImage) -> UInt8 {
        let pixels = rgba(image)
        return stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }.max() ?? 0
    }

    static func rgba(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }
}

@Suite("Runner animator")
@MainActor
struct RunnerAnimatorTests {
    @Test func samePlanTwiceDoesNotRestart() throws {
        let animator = RunnerAnimator(runner: Runner.builtIn("bench"))
        animator.play(.stumble(times: 3, then: .alert))
        let first = try #require(animator.layer.animation(forKey: RunnerAnimator.animationKey))
        animator.play(.stumble(times: 3, then: .alert))
        let second = try #require(animator.layer.animation(forKey: RunnerAnimator.animationKey))
        #expect(first === second)
    }

    @Test func speedOnlyAppliesWhileRunning() {
        let animator = RunnerAnimator(runner: Runner.builtIn("bench"))
        animator.play(.loop(.running))
        animator.setSpeed(6)
        #expect(animator.layer.speed == 6)
        animator.play(.loop(.sleeping))
        #expect(animator.layer.speed == 1)
        animator.play(.loop(.running))
        #expect(animator.layer.speed == 6)
    }

    @Test func speedIsClampedAndPauseFreezes() {
        let animator = RunnerAnimator(runner: Runner.builtIn("bench"))
        animator.play(.loop(.running))
        animator.setSpeed(40)
        #expect(animator.layer.speed == 12)
        animator.pause()
        #expect(animator.layer.speed == 0)
        animator.resume()
        #expect(animator.layer.speed == 12)
    }

    @Test func stillPlanSetsContentsWithoutAnimation() {
        let animator = RunnerAnimator(runner: Runner.builtIn("cup"))
        animator.play(.still(.sleeping))
        #expect(animator.layer.animation(forKey: RunnerAnimator.animationKey) == nil)
        #expect(animator.layer.contents != nil)
    }
}
