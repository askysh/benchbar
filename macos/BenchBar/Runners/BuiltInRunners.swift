import CoreGraphics
import Foundation

// The two built in runners, drawn with Core Graphics so there are no image
// files to keep in sync. Everything is drawn in points on an 18 pt tall
// canvas (y goes up), then rendered at 2x: 36 px tall frames.
//
// Both characters are original: a park bench and a coffee cup, each with
// two legs and a face, running to the right. Faces are cut out of the
// filled shapes, so they read as holes once macOS tints the frame.

/// A frame being drawn: the context plus a few shape helpers.
nonisolated struct RunnerCanvas {
    let context: CGContext

    /// Renders one frame `width` points wide.
    static func render(width: CGFloat, _ draw: (RunnerCanvas) -> Void) -> CGImage {
        let scale = Runner.scale
        let context = CGContext(
            data: nil,
            width: Int(width * scale),
            height: Runner.pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        draw(RunnerCanvas(context: context))
        return context.makeImage()!
    }

    /// Runs `body` with the body transform: `lean` degrees clockwise (a
    /// forward lean when facing right) around `pivot`, then moved by `offset`.
    func transformed(lean: CGFloat, pivot: CGPoint, offset: CGPoint = .zero, _ body: () -> Void) {
        context.saveGState()
        context.translateBy(x: pivot.x + offset.x, y: pivot.y + offset.y)
        context.rotate(by: -lean * .pi / 180)
        context.translateBy(x: -pivot.x, y: -pivot.y)
        body()
        context.restoreGState()
    }

    /// Draws with the clear blend mode: whatever is drawn becomes a hole.
    func cutting(_ body: () -> Void) {
        context.saveGState()
        context.setBlendMode(.clear)
        body()
        context.restoreGState()
    }

    func fill(_ rect: CGRect, radius: CGFloat) {
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    func dot(_ center: CGPoint, radius: CGFloat) {
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    func line(_ points: [CGPoint], width: CGFloat) {
        guard let first = points.first else { return }
        context.setLineWidth(width)
        context.move(to: first)
        for point in points.dropFirst() { context.addLine(to: point) }
        context.strokePath()
    }

    /// A two part leg from `hip`. Angles are degrees from straight down,
    /// positive swings forward (to the right). `knee` bends the shin back.
    func leg(hip: CGPoint, thigh: CGFloat, shin: CGFloat, swing: CGFloat, knee: CGFloat, width: CGFloat) {
        let a = swing * .pi / 180
        let kneePoint = CGPoint(x: hip.x + thigh * sin(a), y: hip.y - thigh * cos(a))
        let b = (swing - knee) * .pi / 180
        let foot = CGPoint(x: kneePoint.x + shin * sin(b), y: kneePoint.y - shin * cos(b))
        line([hip, kneePoint, foot], width: width)
    }

    /// Eyes in one of the face styles, cut out of whatever is under them.
    func eyes(_ centers: [CGPoint], _ style: EyeStyle) {
        cutting {
            for c in centers {
                switch style {
                case .open: dot(c, radius: 0.8)
                case .wide: dot(c, radius: 1.05)
                case .closed: line([CGPoint(x: c.x - 0.6, y: c.y), CGPoint(x: c.x + 0.6, y: c.y)], width: 0.7)
                case .crossed:
                    line([CGPoint(x: c.x - 0.75, y: c.y - 0.75), CGPoint(x: c.x + 0.75, y: c.y + 0.75)], width: 0.6)
                    line([CGPoint(x: c.x - 0.75, y: c.y + 0.75), CGPoint(x: c.x + 0.75, y: c.y - 0.75)], width: 0.6)
                }
            }
        }
    }

    enum EyeStyle { case open, wide, closed, crossed }

    // MARK: marks beside the character

    /// A small "z" with its bottom left corner at `origin`.
    func sleepZ(at origin: CGPoint, size: CGFloat) {
        line([
            CGPoint(x: origin.x, y: origin.y + size),
            CGPoint(x: origin.x + size, y: origin.y + size),
            CGPoint(x: origin.x, y: origin.y),
            CGPoint(x: origin.x + size, y: origin.y),
        ], width: 0.9)
    }

    func exclamation(x: CGFloat) {
        line([CGPoint(x: x, y: 15.8), CGPoint(x: x, y: 9.6)], width: 2)
        dot(CGPoint(x: x, y: 6.6), radius: 1.1)
    }

    func question(x: CGFloat) {
        context.setLineWidth(1.6)
        // the hook: an arc from the upper left round to the right, then down
        context.addArc(center: CGPoint(x: x, y: 13.4), radius: 2.1,
                       startAngle: .pi * 0.95, endAngle: -.pi * 0.4, clockwise: true)
        context.addLine(to: CGPoint(x: x, y: 9.4))
        context.strokePath()
        dot(CGPoint(x: x, y: 6.6), radius: 1)
    }
}

/// Leg positions for the gaits, as (swing, knee) pairs in degrees.
nonisolated enum Gait {
    /// Frame `i` of `count` for a leg `offset` of a cycle behind.
    static func run(_ i: Int, of count: Int, offset: Double) -> (swing: CGFloat, knee: CGFloat) {
        let phase = 2 * Double.pi * (Double(i) / Double(count) + offset)
        let swing = 38 * sin(phase)
        // the knee folds while the leg travels forward, and is nearly straight on the ground
        let knee = 55 * max(0, cos(phase))
        return (CGFloat(swing), CGFloat(knee))
    }

    static func walk(_ i: Int, of count: Int, offset: Double) -> (swing: CGFloat, knee: CGFloat) {
        let phase = 2 * Double.pi * (Double(i) / Double(count) + offset)
        return (CGFloat(20 * sin(phase)), CGFloat(18 * max(0, cos(phase))))
    }

    /// Vertical bounce of the body: highest between steps.
    static func bob(_ i: Int, of count: Int, amount: CGFloat) -> CGFloat {
        let phase = 2 * Double.pi * Double(i) / Double(count)
        return amount * CGFloat(abs(sin(phase)))
    }
}

// MARK: the bench

/// A park bench seen from the front, with a face on its backrest.
nonisolated enum BenchRunnerArt {
    static let width: CGFloat = 24
    static let hipY: CGFloat = 6.6
    static let pivot = CGPoint(x: 9, y: 6.6)
    static let eyes = [CGPoint(x: 10.9, y: 12.6), CGPoint(x: 13.6, y: 12.6)]

    static func make() -> Runner {
        Runner(
            id: "bench",
            name: "Bench",
            author: "BenchBar",
            isTemplate: true,
            pointWidth: width,
            frames: [
                .sleeping: (0..<4).map { sleeping($0) },
                .starting: (0..<6).map { walking($0, of: 6) },
                .running: (0..<6).map { running($0, of: 6) },
                .crashed: (0..<4).map { stumbling($0) },
                .alert: [alert()],
                .unknown: [question()],
            ])
    }

    /// The seat, the posts and the backrest, above the hips.
    static func body(_ c: RunnerCanvas, eyes style: RunnerCanvas.EyeStyle) {
        c.fill(CGRect(x: 2.2, y: 6.4, width: 13.6, height: 2.2), radius: 0.8)
        c.fill(CGRect(x: 3.4, y: 8.4, width: 1.5, height: 1.8), radius: 0.3)
        c.fill(CGRect(x: 13.1, y: 8.4, width: 1.5, height: 1.8), radius: 0.3)
        c.fill(CGRect(x: 2.6, y: 9.9, width: 12.8, height: 5.4), radius: 1.6)
        c.eyes(eyes, style)
    }

    static func legs(_ c: RunnerCanvas, back: (CGFloat, CGFloat), front: (CGFloat, CGFloat)) {
        c.leg(hip: CGPoint(x: 7.2, y: hipY), thigh: 3.1, shin: 3.4, swing: back.0, knee: back.1, width: 1.5)
        c.leg(hip: CGPoint(x: 10.8, y: hipY), thigh: 3.1, shin: 3.4, swing: front.0, knee: front.1, width: 1.5)
    }

    static func running(_ i: Int, of n: Int) -> CGImage {
        RunnerCanvas.render(width: width) { c in
            c.transformed(lean: 10, pivot: pivot, offset: CGPoint(x: 1, y: Gait.bob(i, of: n, amount: 0.9))) {
                legs(c, back: Gait.run(i, of: n, offset: 0.5), front: Gait.run(i, of: n, offset: 0))
                body(c, eyes: .open)
            }
            // speed lines behind the bench
            let drift = CGFloat(i % 3) * 0.6
            c.line([CGPoint(x: 0.4 + drift, y: 13), CGPoint(x: 1.6 + drift, y: 13)], width: 0.8)
            c.line([CGPoint(x: 0.2 + drift, y: 10.4), CGPoint(x: 1.2 + drift, y: 10.4)], width: 0.8)
        }
    }

    static func walking(_ i: Int, of n: Int) -> CGImage {
        RunnerCanvas.render(width: width) { c in
            c.transformed(lean: 3, pivot: pivot, offset: CGPoint(x: 0.5, y: Gait.bob(i, of: n, amount: 0.4))) {
                legs(c, back: Gait.walk(i, of: n, offset: 0.5), front: Gait.walk(i, of: n, offset: 0))
                body(c, eyes: .open)
            }
        }
    }

    static func sleeping(_ i: Int) -> CGImage {
        RunnerCanvas.render(width: width) { c in
            // standing still like any bench, breathing a little
            let breath: CGFloat = i % 2 == 0 ? 0 : 0.3
            c.transformed(lean: 0, pivot: pivot, offset: CGPoint(x: 0, y: -0.6 + breath)) {
                c.line([CGPoint(x: 4.2, y: hipY), CGPoint(x: 4.2, y: 0.6 - breath)], width: 1.5)
                c.line([CGPoint(x: 13.8, y: hipY), CGPoint(x: 13.8, y: 0.6 - breath)], width: 1.5)
                body(c, eyes: .closed)
            }
            sleepMarks(c, i, x: 17.6)
        }
    }

    static func stumbling(_ i: Int) -> CGImage {
        // trip, pitch forward, nearly fall, catch itself
        let poses: [(lean: CGFloat, drop: CGFloat, back: (CGFloat, CGFloat), front: (CGFloat, CGFloat), eyes: RunnerCanvas.EyeStyle)] = [
            (14, 0, (-30, 10), (25, 0), .open),
            (32, -0.8, (-45, 30), (40, 5), .crossed),
            (46, -1.8, (-55, 50), (55, 10), .crossed),
            (24, -0.6, (-20, 20), (30, 0), .crossed),
        ]
        let p = poses[i]
        return RunnerCanvas.render(width: width) { c in
            c.transformed(lean: p.lean, pivot: pivot, offset: CGPoint(x: 1, y: p.drop)) {
                legs(c, back: p.back, front: p.front)
                body(c, eyes: p.eyes)
            }
        }
    }

    static func alert() -> CGImage {
        RunnerCanvas.render(width: width) { c in
            legs(c, back: (-8, 0), front: (8, 0))
            body(c, eyes: .wide)
            c.exclamation(x: 20.4)
        }
    }

    static func question() -> CGImage {
        RunnerCanvas.render(width: width) { c in
            c.transformed(lean: -6, pivot: pivot) {
                legs(c, back: (-8, 0), front: (8, 0))
                body(c, eyes: .open)
            }
            c.question(x: 20.2)
        }
    }
}

// MARK: the cup

/// A coffee cup with a handle, a face and steam.
nonisolated enum CupRunnerArt {
    static let width: CGFloat = 24
    static let hipY: CGFloat = 5.8
    static let pivot = CGPoint(x: 8.6, y: 5.8)
    static let eyes = [CGPoint(x: 9.8, y: 10.6), CGPoint(x: 12.2, y: 10.6)]

    static func make() -> Runner {
        Runner(
            id: "cup",
            name: "Coffee cup",
            author: "BenchBar",
            isTemplate: true,
            pointWidth: width,
            frames: [
                .sleeping: (0..<4).map { sleeping($0) },
                .starting: (0..<6).map { walking($0, of: 6) },
                .running: (0..<6).map { running($0, of: 6) },
                .crashed: (0..<4).map { stumbling($0) },
                .alert: [alert()],
                .unknown: [question()],
            ])
    }

    /// The cup, its rim and its handle (on the left, the trailing side).
    static func body(_ c: RunnerCanvas, eyes style: RunnerCanvas.EyeStyle) {
        let cup = CGMutablePath()
        cup.move(to: CGPoint(x: 4.2, y: 13.6))
        cup.addLine(to: CGPoint(x: 13.8, y: 13.6))
        cup.addLine(to: CGPoint(x: 12.6, y: 6.6))
        cup.addQuadCurve(to: CGPoint(x: 11.4, y: 5.4), control: CGPoint(x: 12.4, y: 5.4))
        cup.addLine(to: CGPoint(x: 6.6, y: 5.4))
        cup.addQuadCurve(to: CGPoint(x: 5.4, y: 6.6), control: CGPoint(x: 5.6, y: 5.4))
        cup.closeSubpath()
        c.context.addPath(cup)
        c.context.fillPath()
        c.fill(CGRect(x: 3.4, y: 12.8, width: 11.2, height: 1.9), radius: 0.8)
        c.context.setLineWidth(1.4)
        c.context.addArc(center: CGPoint(x: 4.4, y: 9.6), radius: 2.3, startAngle: .pi * 0.45, endAngle: .pi * 1.55, clockwise: false)
        c.context.strokePath()
        c.eyes(eyes, style)
    }

    /// Two wisps of steam; `lean` bends them back when running.
    static func steam(_ c: RunnerCanvas, phase: Int, lean: CGFloat) {
        for (n, x) in [CGFloat(7.2), 10.4].enumerated() {
            let sway: CGFloat = (phase + n) % 2 == 0 ? 0.5 : -0.5
            c.line([
                CGPoint(x: x, y: 15.4),
                CGPoint(x: x + sway - lean * 0.4, y: 16.4),
                CGPoint(x: x - sway - lean, y: 17.5),
            ], width: 0.9)
        }
    }

    static func legs(_ c: RunnerCanvas, back: (CGFloat, CGFloat), front: (CGFloat, CGFloat)) {
        c.leg(hip: CGPoint(x: 7.4, y: hipY), thigh: 2.8, shin: 3.0, swing: back.0, knee: back.1, width: 1.4)
        c.leg(hip: CGPoint(x: 10.6, y: hipY), thigh: 2.8, shin: 3.0, swing: front.0, knee: front.1, width: 1.4)
    }

    static func running(_ i: Int, of n: Int) -> CGImage {
        RunnerCanvas.render(width: width) { c in
            c.transformed(lean: 10, pivot: pivot, offset: CGPoint(x: 1.2, y: Gait.bob(i, of: n, amount: 0.9))) {
                legs(c, back: Gait.run(i, of: n, offset: 0.5), front: Gait.run(i, of: n, offset: 0))
                body(c, eyes: .open)
                steam(c, phase: i, lean: 1.6)
            }
        }
    }

    static func walking(_ i: Int, of n: Int) -> CGImage {
        RunnerCanvas.render(width: width) { c in
            c.transformed(lean: 3, pivot: pivot, offset: CGPoint(x: 0.6, y: Gait.bob(i, of: n, amount: 0.4))) {
                legs(c, back: Gait.walk(i, of: n, offset: 0.5), front: Gait.walk(i, of: n, offset: 0))
                body(c, eyes: .open)
                steam(c, phase: i / 2, lean: 0.4)
            }
        }
    }

    static func sleeping(_ i: Int) -> CGImage {
        RunnerCanvas.render(width: width) { c in
            // sitting on the ground, legs folded out of sight, no steam: a cold cup
            let breath: CGFloat = i % 2 == 0 ? 0 : 0.3
            c.transformed(lean: 0, pivot: pivot, offset: CGPoint(x: 0, y: -4.6 + breath)) {
                body(c, eyes: .closed)
            }
            sleepMarks(c, i, x: 16.6)
        }
    }

    static func stumbling(_ i: Int) -> CGImage {
        let poses: [(lean: CGFloat, drop: CGFloat, back: (CGFloat, CGFloat), front: (CGFloat, CGFloat), eyes: RunnerCanvas.EyeStyle)] = [
            (14, 0, (-30, 10), (25, 0), .open),
            (32, -0.8, (-45, 30), (40, 5), .crossed),
            (46, -1.8, (-55, 50), (55, 10), .crossed),
            (24, -0.6, (-20, 20), (30, 0), .crossed),
        ]
        let p = poses[i]
        return RunnerCanvas.render(width: width) { c in
            c.transformed(lean: p.lean, pivot: pivot, offset: CGPoint(x: 1.2, y: p.drop)) {
                legs(c, back: p.back, front: p.front)
                body(c, eyes: p.eyes)
            }
            // a splash of coffee flies out on the big pitch
            if i == 2 {
                c.dot(CGPoint(x: 19.4, y: 10.8), radius: 0.8)
                c.dot(CGPoint(x: 21.2, y: 8.6), radius: 0.6)
            }
        }
    }

    static func alert() -> CGImage {
        RunnerCanvas.render(width: width) { c in
            legs(c, back: (-8, 0), front: (8, 0))
            body(c, eyes: .wide)
            c.exclamation(x: 20.4)
        }
    }

    static func question() -> CGImage {
        RunnerCanvas.render(width: width) { c in
            c.transformed(lean: -6, pivot: pivot) {
                legs(c, back: (-8, 0), front: (8, 0))
                body(c, eyes: .open)
            }
            c.question(x: 20.2)
        }
    }
}

/// Two z's floating up and away, frame `i` of 4.
nonisolated private func sleepMarks(_ c: RunnerCanvas, _ i: Int, x: CGFloat) {
    let rise = CGFloat(i) * 0.7
    c.sleepZ(at: CGPoint(x: x, y: 7.2 + rise), size: 2.2)
    if i >= 1 {
        c.sleepZ(at: CGPoint(x: x + 2.6, y: 11 + rise * 0.8), size: 2.8)
    }
}
