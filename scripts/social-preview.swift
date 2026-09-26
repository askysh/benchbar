#!/usr/bin/env swift
// social-preview.swift: draws the repository's social preview and the docs
// site's og:image from images already in docs/images.
//
// Left: the app icon, the name and the one line tagline, and the running
// frames of the menu bar runner as a strip. Right: the light popover. The
// background is the popover's own light grey, so the two read as one.
//
// Run from the repository root:
//   swift scripts/social-preview.swift                 # both images
//   swift scripts/social-preview.swift 1200x630 out.png
//
// Uses only AppKit, like the app: no Python imaging library to install.
import AppKit

let background = NSColor(srgbRed: 0.961, green: 0.961, blue: 0.961, alpha: 1)
let ink = NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1)
let secondary = NSColor(srgbRed: 0.40, green: 0.40, blue: 0.42, alpha: 1)
let tagline = "Frappe and ERPNext dev benches on your Mac, run by launchd, watched from the menu bar."

func load(_ path: String) -> NSBitmapImageRep {
    guard let data = FileManager.default.contents(atPath: path),
          let rep = NSBitmapImageRep(data: data) else {
        FileHandle.standardError.write("social-preview: cannot read \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    return rep
}

// The "bench running" row of docs/images/runners.png: six frames on grey
// tiles. The tile and the white eyes become transparent, the black stays.
func runnerFrames() -> [CGImage] {
    let sheet = load("docs/images/runners.png")
    var frames: [CGImage] = []
    for i in 0..<6 {
        let x0 = 88 + i * 102, y0 = 165, w = 96, h = 70
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { continue }
        for y in 0..<h {
            for x in 0..<w {
                let c = sheet.colorAt(x: x0 + x, y: y0 + y)?.usingColorSpace(.sRGB) ?? .white
                let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                let alpha = max(0, min(1, (0.8 - lum) / 0.6))
                rep.setColor(NSColor(deviceRed: 0.114, green: 0.114, blue: 0.122, alpha: alpha), atX: x, y: y)
            }
        }
        if let cg = rep.cgImage { frames.append(cg) }
    }
    return frames
}

func render(width: Int, height: Int, to path: String) {
    let W = CGFloat(width), H = CGFloat(height)
    let s = H / 640 // the design is laid out at 1280x640
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    // Flipped coordinates: y grows downwards, like the layout notes.
    let cg = ctx.cgContext
    cg.translateBy(x: 0, y: H)
    cg.scaleBy(x: 1, y: -1)
    let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
    NSGraphicsContext.current = flipped

    background.setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()

    // The popover, right, as a floating panel.
    let popover = load("docs/images/popover-light.png")
    let ph = 560 * s
    let pw = ph * CGFloat(popover.pixelsWide) / CGFloat(popover.pixelsHigh)
    let pRect = NSRect(x: W - pw - 72 * s, y: (H - ph) / 2, width: pw, height: ph)
    let panel = NSBezierPath(roundedRect: pRect, xRadius: 22 * s, yRadius: 22 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.18)
    shadow.shadowBlurRadius = 40 * s
    shadow.shadowOffset = NSSize(width: 0, height: 12 * s)
    shadow.set()
    background.setFill()
    panel.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    panel.addClip()
    popover.draw(in: pRect, from: .zero, operation: .sourceOver, fraction: 1,
                 respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: 0, alpha: 0.10).setStroke()
    panel.lineWidth = 1 * s
    panel.stroke()

    // Left column.
    let left = 80 * s
    let columnWidth = pRect.minX - left - 60 * s
    let icon = load("docs/images/app-icon.png")
    let iconSize = 132 * s
    icon.draw(in: NSRect(x: left - 10 * s, y: 80 * s, width: iconSize, height: iconSize),
              from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
              hints: [.interpolation: NSImageInterpolation.high.rawValue])

    let title = NSAttributedString(string: "BenchBar", attributes: [
        .font: NSFont.systemFont(ofSize: 92 * s, weight: .bold),
        .foregroundColor: ink,
        .kern: -1.5 * s,
    ])
    title.draw(at: NSPoint(x: left - 4 * s, y: 222 * s))

    let para = NSMutableParagraphStyle()
    para.lineSpacing = 6 * s
    let tag = NSAttributedString(string: tagline, attributes: [
        .font: NSFont.systemFont(ofSize: 28 * s, weight: .regular),
        .foregroundColor: secondary,
        .paragraphStyle: para,
    ])
    tag.draw(with: NSRect(x: left, y: 342 * s, width: columnWidth, height: 140 * s),
             options: [.usesLineFragmentOrigin])

    // The runner strip.
    let fh = 50 * s
    let fw = fh * 96 / 70
    var x = left - 6 * s
    for frame in runnerFrames() {
        cg.saveGState()
        // CGContext draws images bottom up; undo the flip for each frame.
        let y = 456 * s
        cg.translateBy(x: x, y: y + fh)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(frame, in: CGRect(x: 0, y: 0, width: fw, height: fh))
        cg.restoreGState()
        x += fw + 10 * s
    }

    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write("social-preview: cannot write \(path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    print("wrote \(path) (\(width)x\(height))")
}

let args = CommandLine.arguments.dropFirst()
if args.count == 2, let size = args.first {
    let parts = size.split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2 else {
        FileHandle.standardError.write("usage: social-preview.swift [WIDTHxHEIGHT OUT.png]\n".data(using: .utf8)!)
        exit(2)
    }
    render(width: parts[0], height: parts[1], to: String(args.last!))
} else if args.isEmpty {
    render(width: 1280, height: 640, to: "docs/images/social-preview.png")
    render(width: 1200, height: 630, to: "docs/images/og-image.png")
} else {
    FileHandle.standardError.write("usage: social-preview.swift [WIDTHxHEIGHT OUT.png]\n".data(using: .utf8)!)
    exit(2)
}
