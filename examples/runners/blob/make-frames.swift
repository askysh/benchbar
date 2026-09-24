// Draws the frames of the example "blob" runner.
//
//   cd examples/runners/blob && swift make-frames.swift
//
// Each frame is a PNG, 36 px tall (18 pt at 2x) and 40 px wide, drawn in
// black on transparent: the runner is a template, so BenchBar tints it
// with the menu bar's text color. This file is not needed to use the
// runner; it only shows one way to make frames.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let width = 40, height = 36

func frame(_ name: String, _ draw: (CGContext) -> Void) {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.setStrokeColor(CGColor(gray: 0, alpha: 1))
    context.setLineCap(.round)
    draw(context)
    let url = URL(fileURLWithPath: name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    print("wrote \(name)")
}

/// The blob: an ellipse resting on y, with eyes cut out of it.
func blob(_ c: CGContext, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, tilt: CGFloat = 0, eyes: String = "open") {
    c.saveGState()
    c.translateBy(x: x, y: y)
    c.rotate(by: -tilt * .pi / 180)
    c.fillEllipse(in: CGRect(x: -w / 2, y: 0, width: w, height: h))
    c.setBlendMode(.clear)
    for ex in [w * 0.12, w * 0.32] {
        let ey = h * 0.6
        switch eyes {
        case "closed":
            c.setLineWidth(1.5)
            c.move(to: CGPoint(x: ex - 2, y: ey)); c.addLine(to: CGPoint(x: ex + 2, y: ey)); c.strokePath()
        case "crossed":
            c.setLineWidth(1.2)
            c.move(to: CGPoint(x: ex - 2, y: ey - 2)); c.addLine(to: CGPoint(x: ex + 2, y: ey + 2))
            c.move(to: CGPoint(x: ex - 2, y: ey + 2)); c.addLine(to: CGPoint(x: ex + 2, y: ey - 2)); c.strokePath()
        default:
            c.fillEllipse(in: CGRect(x: ex - 1.8, y: ey - 1.8, width: 3.6, height: 3.6))
        }
    }
    c.restoreGState()
}

// running: a hop in four frames, squashed on the ground, stretched in the air
let hops: [(y: CGFloat, w: CGFloat, h: CGFloat)] = [(1, 28, 18), (6, 22, 24), (10, 22, 24), (5, 24, 22)]
for (i, hop) in hops.enumerated() {
    frame("run\(i + 1).png") { c in blob(c, x: 18, y: hop.y, w: hop.w, h: hop.h, tilt: 8) }
}

// sleeping: flat and breathing, with a z
for i in 0..<2 {
    frame("sleep\(i + 1).png") { c in
        blob(c, x: 16, y: 1, w: 28, h: CGFloat(15 + i), eyes: "closed")
        c.setLineWidth(1.5)
        let z = CGFloat(20 + i * 3)
        c.move(to: CGPoint(x: 32, y: z + 6)); c.addLine(to: CGPoint(x: 38, y: z + 6))
        c.addLine(to: CGPoint(x: 32, y: z)); c.addLine(to: CGPoint(x: 38, y: z)); c.strokePath()
    }
}

// crashed: a wobble with crossed eyes
for (i, tilt) in [CGFloat(20), -15].enumerated() {
    frame("wobble\(i + 1).png") { c in blob(c, x: 18, y: 1, w: 26, h: 20, tilt: tilt, eyes: "crossed") }
}

// alert: sitting up, with an exclamation mark
frame("alert.png") { c in
    blob(c, x: 15, y: 1, w: 24, h: 22)
    c.setLineWidth(3.5)
    c.move(to: CGPoint(x: 34, y: 32)); c.addLine(to: CGPoint(x: 34, y: 16)); c.strokePath()
    c.fillEllipse(in: CGRect(x: 32, y: 7, width: 4, height: 4))
}
