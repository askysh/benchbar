import CoreGraphics
import Foundation

/// A folded paper plane seen from the side, nose to the right. It flies
/// while the bench runs, rests on the ground when it stops and nose dives
/// when it crashes. The tray draws the same frames
/// (windows/tray/Tray.Core/PlaneRunnerArt.cs).
nonisolated enum PlaneRunnerArt {
    static let width: CGFloat = 24
    /// The plane turns around its middle.
    static let pivot = CGPoint(x: 13, y: 9)

    static func make() -> Runner {
        Runner(
            id: "plane",
            name: "Paper plane",
            author: "BenchBar",
            isTemplate: true,
            pointWidth: width,
            frames: [
                .sleeping: (0..<4).map { sleeping($0) },
                .starting: (0..<6).map { takingOff($0) },
                .running: (0..<6).map { flying($0) },
                .crashed: (0..<4).map { nosediving($0) },
                .alert: [alert()],
                .unknown: [question()],
            ])
    }

    /// The upper wing and the keel, with the fold between them cut out.
    static func body(_ c: RunnerCanvas) {
        c.shape([CGPoint(x: 5.6, y: 13.2), CGPoint(x: 20.4, y: 9.2), CGPoint(x: 8.6, y: 8.9)])
        c.shape([CGPoint(x: 8.6, y: 8.9), CGPoint(x: 20.4, y: 9.2), CGPoint(x: 10, y: 5.6)])
        c.cutLine([CGPoint(x: 8.2, y: 8.9), CGPoint(x: 18.2, y: 9.13)], width: 0.6)
    }

    /// The plane leaned `pitch` degrees nose down and moved by `offset`.
    static func plane(_ c: RunnerCanvas, pitch: CGFloat, offset: CGPoint) {
        c.transformed(lean: pitch, pivot: pivot, offset: offset) { body(c) }
    }

    static func height(_ i: Int) -> CGFloat {
        1.6 * CGFloat(sin(2 * Double.pi * Double(i) / 6))
    }

    static func flying(_ i: Int) -> CGImage {
        RunnerCanvas.render(width: width) { c in
            // up and down on a gentle wave, nose up while it climbs
            let pitch = -7 * CGFloat(cos(2 * Double.pi * Double(i) / 6))
            plane(c, pitch: pitch, offset: CGPoint(x: 0, y: height(i)))
            // the trail: where it was a moment ago
            for k in 1...3 {
                let y = 9.6 + height(i - k)
                let x = 6.2 - CGFloat(k) * 1.9
                c.line([CGPoint(x: x, y: y), CGPoint(x: x + 1.1, y: y)], width: 0.9)
            }
        }
    }

    static func takingOff(_ i: Int) -> CGImage {
        RunnerCanvas.render(width: width) { c in
            // a run along the ground with little hops, not quite airborne
            let hops: [CGFloat] = [0, 0.3, 1.2, 2.0, 1.2, 0.3]
            plane(c, pitch: -4 - hops[i] * 3, offset: CGPoint(x: -1, y: -5.4 + hops[i]))
            let drift = CGFloat(i % 3) * 0.8
            for x in [CGFloat(1.0), 5.2] {
                c.line([CGPoint(x: x - drift, y: 0.6), CGPoint(x: x + 1.6 - drift, y: 0.6)], width: 0.8)
            }
        }
    }

    static func sleeping(_ i: Int) -> CGImage {
        RunnerCanvas.render(width: width) { c in
            // grounded, nose down a little, rocking now and then
            let rock: CGFloat = i % 2 == 0 ? 0 : 1.5
            plane(c, pitch: 4 + rock, offset: CGPoint(x: -5, y: -5.6))
            sleepMarks(c, i, x: 17)
        }
    }

    static func nosediving(_ i: Int) -> CGImage {
        // a stall, a dive, the nose hits the ground, a bounce back
        let poses: [(pitch: CGFloat, offset: CGPoint)] = [
            (-14, CGPoint(x: -1.6, y: 1.4)),
            (30, CGPoint(x: -1.4, y: -0.4)),
            (62, CGPoint(x: -3.6, y: -2.0)),
            (48, CGPoint(x: -3.6, y: -1.4)),
        ]
        let p = poses[i]
        return RunnerCanvas.render(width: width) { c in
            plane(c, pitch: p.pitch, offset: p.offset)
            if i == 2 {
                // the bump where the nose hit
                c.line([CGPoint(x: 13.6, y: 2.6), CGPoint(x: 12.4, y: 4.2)], width: 0.8)
                c.line([CGPoint(x: 18.6, y: 2.6), CGPoint(x: 19.8, y: 4.2)], width: 0.8)
                c.line([CGPoint(x: 16.2, y: 3.6), CGPoint(x: 16.2, y: 5.4)], width: 0.8)
            }
        }
    }

    static func alert() -> CGImage {
        RunnerCanvas.render(width: width) { c in
            // stuck nose first in the ground
            plane(c, pitch: 62, offset: CGPoint(x: -5.4, y: -2.0))
            c.exclamation(x: 19.6)
        }
    }

    static func question() -> CGImage {
        RunnerCanvas.render(width: width) { c in
            plane(c, pitch: -4, offset: CGPoint(x: -5, y: 0))
            c.question(x: 19.6)
        }
    }
}
