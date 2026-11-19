import AppKit
import Foundation
import Testing
@testable import BenchBar

/// The comparison behind the snapshot references: it must pass the noise two
/// Macs produce and fail a real layout or colour change.
@Suite("Snapshot comparison")
struct SnapshotCompareTests {
    func image(width: Int = 100, height: Int = 60, fill: UInt8 = 240, _ draw: (inout [UInt8], Int) -> Void = { _, _ in }) -> SnapshotCompare.Pixels {
        var bytes = [UInt8](repeating: fill, count: width * height * 4)
        for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
        draw(&bytes, width)
        return .init(width: width, height: height, bytes: bytes)
    }

    func block(_ x: Range<Int>, _ y: Range<Int>, _ value: UInt8) -> (inout [UInt8], Int) -> Void {
        { bytes, width in
            for yy in y { for xx in x { for c in 0..<3 { bytes[(yy * width + xx) * 4 + c] = value } } }
        }
    }

    @Test func identicalImagesAreTheSame() {
        #expect(SnapshotCompare.compare(image(), to: image()) == .same)
    }

    @Test func smallNoiseIsIgnored() {
        // every pixel off by 10 of 255: a different anti aliasing, not a different view
        #expect(SnapshotCompare.compare(image(fill: 250), to: image(fill: 240)) == .same)
        // a few stray pixels
        #expect(SnapshotCompare.compare(image(block(0..<3, 0..<3, 0)), to: image()) == .same)
    }

    /// The black selection bar of issue #43: a block of the window drawn dark.
    @Test func aChangedBlockFails() {
        let actual = image(block(10..<90, 20..<30, 0))
        guard case .differs(let why) = SnapshotCompare.compare(actual, to: image()) else {
            Issue.record("a black bar passed as the same image")
            return
        }
        #expect(why.contains("pixels changed"))
    }

    @Test func aDifferentSizeFails() {
        guard case .differs(let why) = SnapshotCompare.compare(image(height: 80), to: image()) else {
            Issue.record("a taller render passed")
            return
        }
        #expect(why.contains("size"))
        // one pixel of rounding is not a layout change
        #expect(SnapshotCompare.compare(image(height: 61), to: image()) == .same)
    }

    @Test func aReferenceRoundTripsThroughPNG() throws {
        let original = image(block(10..<50, 10..<40, 20))
        let data = try #require(SnapshotCompare.png(of: original))
        let back = try #require(SnapshotCompare.pixels(ofPNG: data))
        #expect(back.width == original.width && back.height == original.height)
        #expect(SnapshotCompare.compare(back, to: original) == .same)
    }

    @Test func normalizingUsesTwoPointsPerPixel() throws {
        let data = try #require(SnapshotCompare.png(of: image(width: 450, height: 310)))
        let rep = try #require(NSBitmapImageRep(data: data)?.cgImage)
        // a 900 x 620 pt window rendered at 2x is 1800 x 1240 pixels; here a 450 x 310 image stands for 900 x 620 pt
        let pixels = SnapshotCompare.normalize(rep, pointsWide: 900, pointsHigh: 620)
        #expect(pixels.width == 450 && pixels.height == 310)
    }
}
