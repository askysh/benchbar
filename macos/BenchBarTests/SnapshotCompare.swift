import AppKit
import Foundation
import Testing

/// Reference image checks for the snapshot suite (SnapshotTests).
///
/// A render is cut down to `pointsPerPixel` points per pixel before it is
/// stored or compared, so the check sees layout, colour and text blocks, and
/// ignores the anti aliasing that differs between two Macs. A render passes
/// when it has the size of its reference and
///
/// - at most `maxChangedFraction` of its pixels differ by `channelThreshold`
///   or more in any channel (the global limit), and
/// - no 8 by 8 pixel window holds `maxChangedInWindow` or more changed pixels
///   (the local limit). A status dot is 12 to 16 pixels at this scale, far
///   under the global limit of a window, so a dot of the wrong colour, a
///   blank label or a missing icon is caught only by this rule.
///
/// References live in `Snapshots/macos<major>/` next to this file, one folder
/// per macOS major version, because the system draws controls differently
/// from one release to the next. A missing reference fails when the folder
/// exists or the `require` marker does (the Snapshots workflow sets it on a
/// pull request); with neither, a local run only writes the renders. The
/// marker `record` writes the references instead of comparing and is removed
/// as soon as the run reads it, so a recording happens once.
///
/// The markers are files in `snapshotDir`, because xcodebuild passes no
/// environment variables to a hosted test.
nonisolated enum SnapshotCompare {
    static let pointsPerPixel: CGFloat = 2
    static let channelThreshold = 40
    static let maxChangedFraction = 0.005
    static let window = 8
    static let maxChangedInWindow = 6

    /// Where the renders go, and where the markers are.
    static var out: URL { snapshotDir }
    static var major: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

    static func marker(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: out.appendingPathComponent(name).path)
    }

    /// Whether this run writes the references. Read once per process, and the
    /// `record` marker is removed with the first read: every render of the
    /// run records, the next run compares.
    static let recording: Bool = {
        guard marker("record") else { return false }
        try? FileManager.default.removeItem(at: recordMarker)
        return true
    }()

    static var recordMarker: URL { out.appendingPathComponent("record") }

    static var referenceDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Snapshots/macos\(major)", isDirectory: true)
    }

    enum Verdict: Equatable {
        case same
        case differs(String)
    }

    /// How often `settle` measures before it gives up.
    static let settlePasses = 5

    enum Settled: Equatable {
        case size(CGSize)
        case unsettled(String)
    }

    /// The size two layout passes in a row agree on. A sheet sizes its
    /// scrolling content after its first layout, on a later turn of the run
    /// loop. With one fixed wait, a busy Mac measured before that turn and
    /// rendered the sheet a few points short (profile-import-light was 623
    /// points high and its dark render 626, run 45798391475). `measure` lays
    /// out and gives the size, `wait` lets the run loop turn.
    static func settle(passes: Int = settlePasses, measure: () -> CGSize, wait: () -> Void) -> Settled {
        var last = measure()
        var seen = [last]
        for _ in 1..<max(2, passes) {
            wait()
            let next = measure()
            if next == last { return .size(next) }
            seen.append(next)
            last = next
        }
        let sizes = seen.map(text(of:)).joined(separator: " then ")
        return .unsettled("the layout did not settle: \(sizes)")
    }

    /// Nil when every render of one view has the same size; otherwise the
    /// sentence for the failure. Light and dark differ in colour only, so two
    /// sizes mean that one of them was measured too early.
    static func sizeMismatch(of name: String, _ renders: [(look: String, size: CGSize)]) -> String? {
        guard let first = renders.first, let other = renders.dropFirst().first(where: { $0.size != first.size }) else { return nil }
        let sizes = "the \(first.look) render is \(text(of: first.size)) and the \(other.look) render is \(text(of: other.size))"
        return "\(name): \(sizes). One of them was taken before its layout settled."
    }

    static func text(of size: CGSize) -> String {
        String(format: "%g x %g", Double(size.width), Double(size.height))
    }

    /// A raw RGBA bitmap, `width` by `height`.
    struct Pixels: Equatable {
        var width: Int
        var height: Int
        var bytes: [UInt8]
    }

    /// The image cut down to the comparison grid.
    static func normalize(_ image: CGImage, pointsWide: CGFloat, pointsHigh: CGFloat) -> Pixels {
        let width = max(1, Int((pointsWide / pointsPerPixel).rounded()))
        let height = max(1, Int((pointsHigh / pointsPerPixel).rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Pixels(width: width, height: height, bytes: bytes)
    }

    static func compare(_ actual: Pixels, to reference: Pixels, threshold: Int = channelThreshold,
                        maxFraction: Double = maxChangedFraction, window: Int = window,
                        maxInWindow: Int = maxChangedInWindow) -> Verdict {
        guard abs(actual.width - reference.width) <= 1, abs(actual.height - reference.height) <= 1 else {
            return .differs("size \(actual.width)x\(actual.height) against \(reference.width)x\(reference.height) (2 pt per pixel)")
        }
        let width = min(actual.width, reference.width), height = min(actual.height, reference.height)
        var changedAt = [Int32](repeating: 0, count: width * height)
        var changed = 0
        for y in 0..<height {
            for x in 0..<width {
                let a = (y * actual.width + x) * 4, r = (y * reference.width + x) * 4
                for c in 0..<3 where abs(Int(actual.bytes[a + c]) - Int(reference.bytes[r + c])) >= threshold {
                    changedAt[y * width + x] = 1
                    changed += 1
                    break
                }
            }
        }
        let fraction = Double(changed) / Double(max(1, width * height))
        if fraction > maxFraction {
            return .differs(String(format: "%.2f%% of the pixels changed (limit %.2f%%)", fraction * 100, maxFraction * 100))
        }
        if let worst = densestWindow(of: changedAt, width: width, height: height, size: window), worst.count >= maxInWindow {
            return .differs("\(worst.count) changed pixels in one \(window) by \(window) window at x \(worst.x), y \(worst.y) "
                            + "(2 pt per pixel, limit \(maxInWindow - 1))")
        }
        return .same
    }

    /// The `size` by `size` window with the most changed pixels, found with a
    /// running sum over rows and columns; every window position counts, so a
    /// dot that straddles two aligned tiles is still seen whole.
    static func densestWindow(of changedAt: [Int32], width: Int, height: Int, size: Int) -> (count: Int, x: Int, y: Int)? {
        guard width > 0, height > 0, changedAt.contains(1) else { return nil }
        let w = min(size, width), h = min(size, height)
        // sums[y][x] counts the changed pixels above and left of (x, y)
        var sums = [Int32](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var row: Int32 = 0
            for x in 0..<width {
                row += changedAt[y * width + x]
                sums[(y + 1) * (width + 1) + x + 1] = sums[y * (width + 1) + x + 1] + row
            }
        }
        var best: (count: Int, x: Int, y: Int)?
        for y in 0...(height - h) {
            for x in 0...(width - w) {
                let count = Int(sums[(y + h) * (width + 1) + x + w] - sums[y * (width + 1) + x + w]
                                - sums[(y + h) * (width + 1) + x] + sums[y * (width + 1) + x])
                if count > (best?.count ?? 0) { best = (count, x, y) }
            }
        }
        return best
    }

    static func pixels(ofPNG data: Data) -> Pixels? {
        guard let rep = NSBitmapImageRep(data: data), let image = rep.cgImage else { return nil }
        return normalize(image, pointsWide: CGFloat(image.width) * pointsPerPixel, pointsHigh: CGFloat(image.height) * pointsPerPixel)
    }

    static func png(of pixels: Pixels) -> Data? {
        var bytes = pixels.bytes
        return bytes.withUnsafeMutableBytes { buffer -> Data? in
            guard let context = CGContext(data: buffer.baseAddress, width: pixels.width, height: pixels.height, bitsPerComponent: 8,
                                          bytesPerRow: pixels.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = context.makeImage() else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }
    }

    /// Checks one render: `png` is the full size image, `points` its size in points.
    static func verify(_ png: Data, points: CGSize, name: String, fileID: String = #fileID, line: Int = #line) throws {
        guard let rep = NSBitmapImageRep(data: png), let image = rep.cgImage else {
            Issue.record("\(name): the render is not a PNG")
            return
        }
        let actual = normalize(image, pointsWide: points.width, pointsHigh: points.height)
        let reference = referenceDir.appendingPathComponent("\(name).png")
        if Self.recording {
            try FileManager.default.createDirectory(at: referenceDir, withIntermediateDirectories: true)
            try (try #require(Self.png(of: actual))).write(to: reference)
            return
        }
        guard let data = try? Data(contentsOf: reference), let expected = pixels(ofPNG: data) else {
            if marker("require") || FileManager.default.fileExists(atPath: referenceDir.path) {
                Issue.record("\(name): no reference image at \(reference.path). Record it: touch \(out.path)/record and run the suite once (the marker removes itself).")
            }
            return
        }
        if case .differs(let why) = compare(actual, to: expected) {
            Issue.record("\(name): \(why). The render is \(out.path)/\(name).png, the reference \(reference.path).")
        }
    }
}
