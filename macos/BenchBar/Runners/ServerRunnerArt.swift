import CoreGraphics
import Foundation

/// A small server rack of three units with a face on the top one. Its
/// lights and the data it sends carry the state. The tray draws the same
/// frames (windows/tray/Tray.Core/ServerRunnerArt.cs).
nonisolated enum ServerRunnerArt {
    static let width: CGFloat = 24
    static let pivot = CGPoint(x: 8.8, y: 0.6)
    static let eyes = [CGPoint(x: 6.9, y: 14), CGPoint(x: 9.7, y: 14)]
    /// Bottom and height of each unit, from the bottom up.
    static let units: [(y: CGFloat, height: CGFloat)] = [(1.6, 4.4), (6.7, 4.4), (11.8, 4.6)]

    static func make() -> Runner {
        Runner(
            id: "server",
            name: "Server rack",
            author: "BenchBar",
            isTemplate: true,
            pointWidth: width,
            frames: [
                .sleeping: (0..<4).map { sleeping($0) },
                .starting: (0..<6).map { booting($0) },
                .running: (0..<6).map { serving($0) },
                .crashed: (0..<4).map { failing($0) },
                .alert: [alert()],
                .unknown: [question()],
            ])
    }

    /// The rack: feet, three units, a light per unit (`lit`, bottom up), a
    /// drive slot on the two lower units and the face on the top one. The
    /// middle unit can stick out by `drawer` points.
    static func body(_ c: RunnerCanvas, eyes style: RunnerCanvas.EyeStyle, lit: [Bool], drawer: CGFloat = 0) {
        c.fill(CGRect(x: 4.8, y: 0.6, width: 1.4, height: 1.4), radius: 0.3)
        c.fill(CGRect(x: 11.4, y: 0.6, width: 1.4, height: 1.4), radius: 0.3)
        for (n, unit) in units.enumerated() {
            let x: CGFloat = n == 1 ? 4 + drawer : 4
            c.fill(CGRect(x: x, y: unit.y, width: 9.6, height: unit.height), radius: 1)
            let mid = unit.y + unit.height / 2
            if n < 2 {
                c.cutLine([CGPoint(x: x + 1.5, y: mid), CGPoint(x: x + 5.2, y: mid)], width: 0.8)
            }
            if lit[n] {
                c.cutDot(CGPoint(x: x + 7.7, y: n == 2 ? mid - 0.9 : mid), radius: 0.85)
            }
        }
        c.eyes(eyes, style)
    }

    /// Dashes of data leaving to the right, `i` of 6.
    static func data(_ c: RunnerCanvas, _ i: Int) {
        for (lane, y) in [CGFloat(3.8), 8.9].enumerated() {
            for k in 0..<2 {
                let x = 15 + (CGFloat(i) * 1.4 + CGFloat(k) * 4.2 + CGFloat(lane) * 2.1).truncatingRemainder(dividingBy: 8.4)
                c.line([CGPoint(x: x, y: y), CGPoint(x: min(x + 1.6, 23.4), y: y)], width: 1)
            }
        }
    }

    static func serving(_ i: Int) -> CGImage {
        RunnerCanvas.render(width: width) { c in
            // the lights blink out of step, the data streams out
            let lit = (0..<3).map { (i + $0 * 2) % 3 != 0 }
            body(c, eyes: .open, lit: lit)
            data(c, i)
        }
    }

    static func booting(_ i: Int) -> CGImage {
        RunnerCanvas.render(width: width) { c in
            // the units light up one by one, bottom first
            let on = i % 4
            body(c, eyes: on == 3 ? .open : .closed, lit: (0..<3).map { $0 < on })
        }
    }

    static func sleeping(_ i: Int) -> CGImage {
        RunnerCanvas.render(width: width) { c in
            // every light out; the bottom one breathes slowly
            body(c, eyes: .closed, lit: [i == 1, false, false])
            sleepMarks(c, i, x: 16.4)
        }
    }

    static func failing(_ i: Int) -> CGImage {
        // it shakes, the middle drive jams out and sparks fly
        let poses: [(lean: CGFloat, drawer: CGFloat, eyes: RunnerCanvas.EyeStyle)] = [
            (-3, 0.8, .wide),
            (4, 2.4, .crossed),
            (-4, 3.2, .crossed),
            (2, 1.8, .crossed),
        ]
        let p = poses[i]
        return RunnerCanvas.render(width: width) { c in
            c.transformed(lean: p.lean, pivot: pivot) {
                body(c, eyes: p.eyes, lit: [i % 2 == 0, true, i % 2 == 1], drawer: p.drawer)
            }
            if i == 1 || i == 2 {
                let x = 14.6 + p.drawer
                c.line([CGPoint(x: x, y: 10.6), CGPoint(x: x + 1.6, y: 12)], width: 0.8)
                c.line([CGPoint(x: x + 0.4, y: 8.8), CGPoint(x: x + 2.2, y: 8.8)], width: 0.8)
                c.line([CGPoint(x: x, y: 7.2), CGPoint(x: x + 1.6, y: 5.8)], width: 0.8)
            }
        }
    }

    static func alert() -> CGImage {
        RunnerCanvas.render(width: width) { c in
            body(c, eyes: .wide, lit: [true, true, true])
            c.exclamation(x: 19.4)
        }
    }

    static func question() -> CGImage {
        RunnerCanvas.render(width: width) { c in
            c.transformed(lean: -5, pivot: pivot) {
                body(c, eyes: .open, lit: [false, true, false])
            }
            c.question(x: 19.4)
        }
    }
}
