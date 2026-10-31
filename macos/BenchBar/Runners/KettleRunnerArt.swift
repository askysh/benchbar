import CoreGraphics
import Foundation

/// A round kettle with a face, its spout to the right. It has no legs:
/// it boils instead of running. The tray draws the same frames
/// (windows/tray/Tray.Core/KettleRunnerArt.cs).
nonisolated enum KettleRunnerArt {
    static let width: CGFloat = 24
    static let pivot = CGPoint(x: 8, y: 1.2)
    static let eyes = [CGPoint(x: 6.4, y: 6.4), CGPoint(x: 9.6, y: 6.4)]
    /// Where steam leaves the spout.
    static let spoutTip = CGPoint(x: 16.8, y: 10)

    static func make() -> Runner {
        Runner(
            id: "kettle",
            name: "Kettle",
            author: "BenchBar",
            isTemplate: true,
            pointWidth: width,
            frames: [
                .sleeping: (0..<4).map { sleeping($0) },
                .starting: (0..<6).map { warming($0) },
                .running: (0..<6).map { boiling($0) },
                .crashed: (0..<4).map { boilingOver($0) },
                .alert: [alert()],
                .unknown: [question()],
            ])
    }

    /// The pot, the spout and the handle; the lid sits `lid` points up.
    static func body(_ c: RunnerCanvas, eyes style: RunnerCanvas.EyeStyle, lid: CGFloat = 0, lidTilt: CGFloat = 0) {
        // the pot, wider at the bottom
        c.shape([
            CGPoint(x: 2.6, y: 1.2), CGPoint(x: 13.4, y: 1.2), CGPoint(x: 13.8, y: 2.2),
            CGPoint(x: 12.6, y: 9.4), CGPoint(x: 3.4, y: 9.4), CGPoint(x: 2.2, y: 2.2),
        ])
        c.fill(CGRect(x: 3.2, y: 6.2, width: 9.6, height: 3.6), radius: 1.8)
        // the spout, rising to the right
        c.shape([
            CGPoint(x: 12.4, y: 2.2), CGPoint(x: 15.4, y: 7.2), CGPoint(x: 17.4, y: 9.4),
            CGPoint(x: 16.2, y: 10.6), CGPoint(x: 13.8, y: 8.8), CGPoint(x: 12.4, y: 7.6),
        ])
        // the handle, an arch over the lid
        c.arc(center: CGPoint(x: 8, y: 9.6), radius: 4.4, start: .pi * 0.12, sweep: .pi * 0.76, width: 1.3)
        // the lid and its knob
        c.transformed(lean: lidTilt, pivot: CGPoint(x: 8, y: 10), offset: CGPoint(x: 0, y: lid)) {
            c.fill(CGRect(x: 5.2, y: 9.4, width: 5.6, height: 1.4), radius: 0.7)
            c.dot(CGPoint(x: 8, y: 11.4), radius: 0.8)
        }
        c.eyes(eyes, style)
    }

    /// A curl of steam rising from the spout; `t` from 0 (at the spout) to
    /// 1 (gone), `length` in points.
    static func wisp(_ c: RunnerCanvas, _ t: CGFloat, x: CGFloat, length: CGFloat = 3.2, flip: Bool = false) {
        let y = spoutTip.y + 1.4 + 4 * t
        let sway: CGFloat = flip ? -0.7 : 0.7
        c.line([
            CGPoint(x: x, y: y),
            CGPoint(x: x + sway, y: y + length * 0.35),
            CGPoint(x: x - sway, y: y + length * 0.7),
            CGPoint(x: x, y: y + length),
        ], width: 0.9)
    }

    static func boiling(_ i: Int) -> CGImage {
        RunnerCanvas.render(width: width) { c in
            // the lid rattles on every other frame, the pot jiggles
            let lid: CGFloat = i % 2 == 0 ? 0 : 0.9
            let tilt: CGFloat = i % 4 == 1 ? 8 : (i % 4 == 3 ? -8 : 0)
            let jiggle: CGFloat = i % 2 == 0 ? -0.25 : 0.25
            c.transformed(lean: 0, pivot: pivot, offset: CGPoint(x: jiggle, y: 0)) {
                body(c, eyes: .open, lid: lid, lidTilt: tilt)
            }
            // two curls half a cycle apart, so one leaves as the other arrives
            for k in 0..<2 {
                let t = (CGFloat(i) / 6 + CGFloat(k) / 2).truncatingRemainder(dividingBy: 1)
                wisp(c, t, x: 18.6 + CGFloat(k) * 2.2, flip: (i + k) % 2 == 0)
            }
        }
    }

    static func warming(_ i: Int) -> CGImage {
        RunnerCanvas.render(width: width) { c in
            body(c, eyes: .open)
            // one small wisp at a time, and a little heat under the pot
            wisp(c, CGFloat(i) / 10, x: 18.8, length: 2, flip: i % 2 == 0)
            let shimmer: CGFloat = i % 2 == 0 ? 0 : 0.6
            for x in [CGFloat(5), 8, 11] {
                c.line([CGPoint(x: x - 0.6 + shimmer, y: 0.45), CGPoint(x: x + 0.6 + shimmer, y: 0.45)], width: 0.6)
            }
        }
    }

    static func sleeping(_ i: Int) -> CGImage {
        RunnerCanvas.render(width: width) { c in
            // a cold kettle: no steam, the lid shut, breathing a little
            let breath: CGFloat = i % 2 == 0 ? 0 : 0.25
            c.transformed(lean: 0, pivot: pivot, offset: CGPoint(x: 0, y: breath)) {
                body(c, eyes: .closed)
            }
            sleepMarks(c, i, x: 18.2)
        }
    }

    static func boilingOver(_ i: Int) -> CGImage {
        // it shakes, the lid pops off and water spits out of the spout
        let poses: [(tilt: CGFloat, lid: CGFloat, lidTilt: CGFloat, eyes: RunnerCanvas.EyeStyle)] = [
            (-6, 1.0, 10, .wide),
            (7, 3.4, -24, .crossed),
            (-7, 5.0, 30, .crossed),
            (4, 2.0, -12, .crossed),
        ]
        let p = poses[i]
        return RunnerCanvas.render(width: width) { c in
            c.transformed(lean: p.tilt, pivot: pivot) {
                body(c, eyes: p.eyes, lid: p.lid, lidTilt: p.lidTilt)
            }
            let spray: [[CGPoint]] = [
                [CGPoint(x: 18.4, y: 11)],
                [CGPoint(x: 18.6, y: 12), CGPoint(x: 20.4, y: 10.4)],
                [CGPoint(x: 19.4, y: 13), CGPoint(x: 21.6, y: 11), CGPoint(x: 20.4, y: 8.4)],
                [CGPoint(x: 20.6, y: 9.2), CGPoint(x: 22.4, y: 7)],
            ]
            for (n, drop) in spray[i].enumerated() {
                c.dot(drop, radius: n == 0 ? 0.8 : 0.6)
            }
        }
    }

    static func alert() -> CGImage {
        RunnerCanvas.render(width: width) { c in
            body(c, eyes: .wide, lid: 0.6)
            c.exclamation(x: 20.6)
        }
    }

    static func question() -> CGImage {
        RunnerCanvas.render(width: width) { c in
            c.transformed(lean: -5, pivot: pivot) {
                body(c, eyes: .open)
            }
            c.question(x: 20.6)
        }
    }
}
