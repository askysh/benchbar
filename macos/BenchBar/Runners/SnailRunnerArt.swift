import CoreGraphics
import Foundation

/// A snail with a spiral shell and eyes on stalks, heading right. It
/// hurries (for a snail) while the bench runs and hides in its shell when
/// it stops. The tray draws the same frames
/// (windows/tray/Tray.Core/SnailRunnerArt.cs).
nonisolated enum SnailRunnerArt {
    static let width: CGFloat = 24
    static let shellCenter = CGPoint(x: 8, y: 7.6)
    static let shellRadius: CGFloat = 4.9

    static func make() -> Runner {
        Runner(
            id: "snail",
            name: "Snail",
            author: "BenchBar",
            isTemplate: true,
            pointWidth: width,
            frames: [
                .sleeping: (0..<4).map { sleeping($0) },
                .starting: (0..<6).map { waking($0) },
                .running: (0..<6).map { crawling($0) },
                .crashed: (0..<4).map { rolling($0) },
                .alert: [alert()],
                .unknown: [question()],
            ])
    }

    /// The shell around `center`, its spiral cut out, turned `turn` degrees.
    static func shell(_ c: RunnerCanvas, center: CGPoint, turn: CGFloat = 0) {
        c.dot(center, radius: shellRadius)
        c.transformed(lean: turn, pivot: center) {
            c.cutArc(center: CGPoint(x: center.x + 0.3, y: center.y), radius: 2.9,
                     start: .pi * 0.5, sweep: .pi * 1.55, width: 0.8)
            c.cutArc(center: CGPoint(x: center.x + 0.6, y: center.y + 0.3), radius: 1.3,
                     start: .pi * 1.5, sweep: .pi * 1.4, width: 0.8)
        }
    }

    /// The foot and the head. `reach` moves the head forward (negative pulls
    /// it in), `stalk` scales the stalks (0 hides them), `sway` tips them
    /// back in degrees.
    static func body(_ c: RunnerCanvas, reach: CGFloat = 0, stalk: CGFloat = 1, sway: CGFloat = 0,
                     eyes radius: CGFloat = 0.85, droop: Bool = false) {
        let front = 16.6 + reach
        c.fill(CGRect(x: 2.2, y: 0.6, width: front - 2.2, height: 2.4), radius: 1.2)
        c.fill(CGRect(x: front - 3.4, y: 0.6, width: 3.4, height: 6.2), radius: 1.6)
        guard stalk > 0 else { return }
        for (n, base) in [CGPoint(x: front - 2.6, y: 6.2), CGPoint(x: front - 1.0, y: 6.2)].enumerated() {
            let angle = (CGFloat(n == 0 ? -6 : 22) - sway) * .pi / 180
            let length = 3.8 * stalk
            var tip = CGPoint(x: base.x + length * sin(angle), y: base.y + length * cos(angle))
            if droop, n == 1 {
                // one stalk bends over, puzzled
                let bend = CGPoint(x: base.x + 0.6, y: base.y + 3.2)
                tip = CGPoint(x: bend.x + 1.6, y: bend.y - 0.6)
                c.line([base, bend, tip], width: 0.9)
            } else {
                c.line([base, tip], width: 0.9)
            }
            c.dot(tip, radius: radius)
        }
    }

    static func crawling(_ i: Int) -> CGImage {
        RunnerCanvas.render(width: width) { c in
            // the foot stretches and gathers, the shell rides along, the
            // stalks stream back
            let s = CGFloat(sin(2 * Double.pi * Double(i) / 6))
            body(c, reach: 1.0 + 1.0 * s, sway: 14 + 6 * s)
            shell(c, center: CGPoint(x: shellCenter.x + 0.4 * s, y: shellCenter.y + 0.3 * abs(s)), turn: 4 * s)
            // speed lines behind, the trail on the ground
            let drift = CGFloat(i % 3) * 0.6
            c.line([CGPoint(x: 0.2 + drift, y: 10.6), CGPoint(x: 1.6 + drift, y: 10.6)], width: 0.8)
            c.line([CGPoint(x: 0.4 + drift, y: 7.8), CGPoint(x: 1.6 + drift, y: 7.8)], width: 0.8)
        }
    }

    static func waking(_ i: Int) -> CGImage {
        RunnerCanvas.render(width: width) { c in
            // the head comes out, then the stalks unroll
            let t = CGFloat(i) / 5
            body(c, reach: -4 + 4 * min(1, t * 1.6), stalk: max(0, t * 1.4 - 0.4))
            shell(c, center: shellCenter)
        }
    }

    static func sleeping(_ i: Int) -> CGImage {
        RunnerCanvas.render(width: width) { c in
            // all in the shell, which rests on the ground and breathes
            let breath: CGFloat = i % 2 == 0 ? 0 : 0.3
            shell(c, center: CGPoint(x: shellCenter.x, y: 5.2 + breath))
            c.fill(CGRect(x: 3.4, y: 0.6, width: 9.6, height: 1.2), radius: 0.6)
            sleepMarks(c, i, x: 15)
        }
    }

    static func rolling(_ i: Int) -> CGImage {
        // it pulls in and the shell rolls over, a quarter turn a frame
        RunnerCanvas.render(width: width) { c in
            let center = CGPoint(x: 9 + CGFloat(i) * 1.2, y: 5.6 + (i % 2 == 0 ? 0.6 : 0))
            shell(c, center: center, turn: CGFloat(i) * 90)
            c.line([CGPoint(x: center.x - 6.6, y: 0.6), CGPoint(x: center.x - 5.2, y: 0.6)], width: 0.8)
            if i % 2 == 1 {
                c.line([CGPoint(x: center.x + 5.6, y: 9.6), CGPoint(x: center.x + 6.8, y: 10.8)], width: 0.8)
                c.line([CGPoint(x: center.x + 6, y: 7.4), CGPoint(x: center.x + 7.4, y: 7.4)], width: 0.8)
            }
        }
    }

    static func alert() -> CGImage {
        RunnerCanvas.render(width: width) { c in
            body(c, reach: -0.6, stalk: 1.15, sway: 8, eyes: 1.05)
            shell(c, center: shellCenter)
            c.exclamation(x: 20.6)
        }
    }

    static func question() -> CGImage {
        RunnerCanvas.render(width: width) { c in
            body(c, reach: -0.6, droop: true)
            shell(c, center: shellCenter)
            c.question(x: 20.8)
        }
    }
}
