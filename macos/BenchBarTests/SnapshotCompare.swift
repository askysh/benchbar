import AppKit
import Foundation
import Testing

/// Reference image checks for the snapshot suite (SnapshotTests).
///
/// A render is cut down to `pointsPerPixel` points per pixel before it is
/// stored or compared, so the check sees layout, colour and text blocks, and
/// ignores the anti aliasing that differs between two Macs. A render passes
/// when it has the size of its reference and at most `maxChangedFraction` of
/// its pixels differ by `channelThreshold` or more in any channel.
///
/// References live in `Snapshots/macos<major>/` next to this file, one folder
/// per macOS major version, because the system draws controls differently
/// from one release to the next. With no folder for the running version the
/// renders are written to the output folder and nothing is compared, unless
/// the `require` marker exists (the Snapshots workflow sets it). The marker
/// `record` writes the references instead of comparing.
///
/// The markers are files in `snapshotDir`, because xcodebuild passes no
/// environment variables to a hosted test.
nonisolated enum SnapshotCompare {
    static let pointsPerPixel: CGFloat = 2
    static let channelThreshold = 40
    static let maxChangedFraction = 0.005

    /// Where the renders go, and where the markers are.
    static var out: URL { snapshotDir }
    static var major: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

    static func marker(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: out.appendingPathComponent(name).path)
    }

    static var referenceDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Snapshots/macos\(major)", isDirectory: true)
    }

    enum Verdict: Equatable {
        case same
        case differs(String)
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

    static func compare(_ actual: Pixels, to reference: Pixels,
                        threshold: Int = channelThreshold, maxFraction: Double = maxChangedFraction) -> Verdict {
        guard abs(actual.width - reference.width) <= 1, abs(actual.height - reference.height) <= 1 else {
            return .differs("size \(actual.width)x\(actual.height) against \(reference.width)x\(reference.height) (2 pt per pixel)")
        }
        let width = min(actual.width, reference.width), height = min(actual.height, reference.height)
        var changed = 0
        for y in 0..<height {
            for x in 0..<width {
                let a = (y * actual.width + x) * 4, r = (y * reference.width + x) * 4
                for c in 0..<3 where abs(Int(actual.bytes[a + c]) - Int(reference.bytes[r + c])) >= threshold {
                    changed += 1
                    break
                }
            }
        }
        let fraction = Double(changed) / Double(max(1, width * height))
        guard fraction > maxFraction else { return .same }
        return .differs(String(format: "%.2f%% of the pixels changed (limit %.2f%%)", fraction * 100, maxFraction * 100))
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
        if marker("record") {
            try FileManager.default.createDirectory(at: referenceDir, withIntermediateDirectories: true)
            try (try #require(Self.png(of: actual))).write(to: reference)
            return
        }
        guard let data = try? Data(contentsOf: reference), let expected = pixels(ofPNG: data) else {
            if marker("require") || FileManager.default.fileExists(atPath: referenceDir.path) {
                Issue.record("\(name): no reference image at \(reference.path). Record it: touch \(out.path)/record, run the suite, remove the marker.")
            }
            return
        }
        if case .differs(let why) = compare(actual, to: expected) {
            Issue.record("\(name): \(why). The render is \(out.path)/\(name).png, the reference \(reference.path).")
        }
    }
}
