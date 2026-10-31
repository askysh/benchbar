import CoreGraphics
import Foundation

/// A small rocket with fins and a round window for an eye. It flies up
/// to the right while the bench runs, smokes on the pad while it starts and
/// tumbles when it crashes. The tray draws the same frames
/// (windows/tray/Tray.Core/RocketRunnerArt.cs).
nonisolated enum RocketRunnerArt {
    static let width: CGFloat = 24

    static func make() -> Runner {
        Runner(
            id: "rocket",
            name: "Rocket",
            author: "BenchBar",
            isTemplate: true,
            pointWidth: width,
            frames: [
                .sleeping: (0..<4).map { sleeping($0) },
                .starting: (0..<6).map { countdown($0) },
                .running: (0..<6).map { flying($0) },
                .crashed: (0..<4).map { tumbling($0) },
                .alert: [alert()],
                .unknown: [question()],
            ])
    }

    enum Window { case open, wide, closed, crossed }

    /// The rocket standing up with its middle at `center`, turned `lean`
    /// degrees clockwise; a flame `flame` points long under it.
    static func rocket(_ c: RunnerCanvas, center: CGPoint, lean: CGFloat = 0, flame: CGFloat = 0, window: Window = .open) {
        c.transformed(lean: lean, pivot: .zero, offset: center) {
            if flame > 0 {
                c.shape([CGPoint(x: -1.3, y: -4.6), CGPoint(x: 1.3, y: -4.6), CGPoint(x: 0, y: -4.8 - flame)])
            }
            c.fill(CGRect(x: -2.1, y: -3.8, width: 4.2, height: 7.6), radius: 1.4)
            c.shape([
                CGPoint(x: -2.1, y: 2.6), CGPoint(x: 2.1, y: 2.6), CGPoint(x: 1.4, y: 4.8),
                CGPoint(x: 0, y: 6.4), CGPoint(x: -1.4, y: 4.8),
            ])
            c.shape([CGPoint(x: -2.0, y: -0.6), CGPoint(x: -4.2, y: -4.6), CGPoint(x: -2.0, y: -3.4)])
            c.shape([CGPoint(x: 2.0, y: -0.6), CGPoint(x: 4.2, y: -4.6), CGPoint(x: 2.0, y: -3.4)])
            c.fill(CGRect(x: -1.3, y: -4.8, width: 2.6, height: 1.4), radius: 0.3)
            let eye = CGPoint(x: 0, y: 1.2)
            switch window {
            case .open: c.cutDot(eye, radius: 1.1)
            case .wide: c.cutDot(eye, radius: 1.4)
            case .closed: c.cutLine([CGPoint(x: -0.8, y: 1), CGPoint(x: 0.8, y: 1)], width: 0.7)
            case .crossed:
                c.cutLine([CGPoint(x: -0.8, y: 0.4), CGPoint(x: 0.8, y: 2)], width: 0.6)
                c.cutLine([CGPoint(x: -0.8, y: 2), CGPoint(x: 0.8, y: 0.4)], width: 0.6)
            }
        }
    }

    static func flying(_ i: Int) -> CGImage {
        RunnerCanvas.render(width: width) { c in
            let shake: CGFloat = i % 2 == 0 ? 0.25 : -0.25
            let flame: CGFloat = [3.2, 4.4, 3.6, 4.8, 3.0, 4.2][i]
            rocket(c, center: CGPoint(x: 13 + shake, y: 9.6 - shake), lean: 45, flame: flame)
            // puffs of exhaust drifting away down to the left
            for k in 0..<3 {
                let t = (CGFloat(i) / 6 + CGFloat(k) / 3).truncatingRemainder(dividingBy: 1)
                let d = 8.6 + 5 * t
                c.dot(CGPoint(x: 13 - d * 0.707, y: 9.6 - d * 0.707), radius: 0.6 + 0.8 * t)
            }
        }
    }

    static func countdown(_ i: Int) -> CGImage {
        RunnerCanvas.render(width: width) { c in
            // on the pad, rumbling, the smoke spreading out at its feet
            let shake: CGFloat = i % 2 == 0 ? 0.2 : -0.2
            rocket(c, center: CGPoint(x: 10 + shake, y: 6.4), flame: i % 2 == 0 ? 0.8 : 1.4)
            let spread = CGFloat(i % 3)
            for side in [CGFloat(-1), 1] {
                c.dot(CGPoint(x: 10 + side * (3.6 + spread * 0.9), y: 1.4), radius: 0.8 + spread * 0.25)
                c.dot(CGPoint(x: 10 + side * (5.8 + spread * 1.1), y: 1.2), radius: 0.6 + spread * 0.2)
            }
        }
    }

    static func sleeping(_ i: Int) -> CGImage {
        RunnerCanvas.render(width: width) { c in
            // parked on its fins, engine cold
            let breath: CGFloat = i % 2 == 0 ? 0 : 0.25
            rocket(c, center: CGPoint(x: 9, y: 5.2 + breath), window: .closed)
            sleepMarks(c, i, x: 15.6)
        }
    }

    static func tumbling(_ i: Int) -> CGImage {
        // the engine coughs, it flips over and falls, smoke behind it
        let poses: [(center: CGPoint, lean: CGFloat, flame: CGFloat, window: Window)] = [
            (CGPoint(x: 12, y: 10), 40, 1.6, .wide),
            (CGPoint(x: 13, y: 9), 110, 0, .crossed),
            (CGPoint(x: 13.6, y: 7.6), 190, 0.8, .crossed),
            (CGPoint(x: 13, y: 8.6), 270, 0, .crossed),
        ]
        let p = poses[i]
        return RunnerCanvas.render(width: width) { c in
            rocket(c, center: p.center, lean: p.lean, flame: p.flame, window: p.window)
            c.dot(CGPoint(x: 4.4, y: 11 - CGFloat(i) * 0.6), radius: 1.2)
            c.dot(CGPoint(x: 2.2, y: 13 - CGFloat(i) * 0.4), radius: 0.8)
        }
    }

    static func alert() -> CGImage {
        RunnerCanvas.render(width: width) { c in
            rocket(c, center: CGPoint(x: 9, y: 5.2), window: .wide)
            c.exclamation(x: 18.6)
        }
    }

    static func question() -> CGImage {
        RunnerCanvas.render(width: width) { c in
            rocket(c, center: CGPoint(x: 9, y: 5.2), lean: -8)
            c.question(x: 18.6)
        }
    }
}
