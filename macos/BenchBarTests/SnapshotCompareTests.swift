import AppKit
import Foundation
import SwiftUI
import Testing
@testable import BenchBar

/// A view whose height is set from outside, for the settle test: it changes
/// between two layout passes, the way a sheet's content does on a later turn
/// of the run loop.
private final class GrowingHeight: ObservableObject {
    @Published var points: CGFloat = 40
}

private struct GrowingView: View {
    @ObservedObject var height: GrowingHeight
    var body: some View { Color.clear.frame(width: 100, height: height.points) }
}

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
        // a few stray pixels, far apart, and a 2 by 2 speck
        let stray = image { bytes, width in
            for (x, y) in [(5, 5), (40, 12), (70, 40), (20, 50), (90, 8)] { block(x..<x + 1, y..<y + 1, 0)(&bytes, width) }
            block(60..<62, 20..<22, 0)(&bytes, width)
        }
        #expect(SnapshotCompare.compare(stray, to: image()) == .same)
    }

    /// A status dot at 2 pt per pixel: a disc of 12 pixels (4 by 4 without its corners).
    func dot(at x: Int, _ y: Int, _ value: UInt8) -> (inout [UInt8], Int) -> Void {
        { bytes, width in
            for yy in y..<y + 4 {
                for xx in x..<x + 4 where !([x, x + 3].contains(xx) && [y, y + 3].contains(yy)) {
                    for c in 0..<3 { bytes[(yy * width + xx) * 4 + c] = value }
                }
            }
        }
    }

    /// The case the global limit cannot see: 12 changed pixels are 0.2% of a
    /// 100 by 60 image and 0.01% of a window, so only the local rule fails it.
    @Test func aWrongStatusDotFails() {
        let green = image(dot(at: 30, 20, 60))
        let red = image(dot(at: 30, 20, 200))
        guard case .differs(let why) = SnapshotCompare.compare(red, to: green) else {
            Issue.record("a red dot passed for a green one")
            return
        }
        #expect(why.contains("8 by 8 window"))
        // the same dot across the line of an aligned 8 pixel tile is found too
        guard case .differs = SnapshotCompare.compare(image(dot(at: 6, 6, 200)), to: image(dot(at: 6, 6, 60))) else {
            Issue.record("a dot on a tile border passed")
            return
        }
    }

    @Test func aBlankLabelFails() {
        // a 60 by 6 pixel label of text strokes (every other column) drawn blank
        let label = image { bytes, width in
            for x in stride(from: 10, to: 70, by: 2) { block(x..<x + 1, 20..<26, 30)(&bytes, width) }
        }
        guard case .differs = SnapshotCompare.compare(image(), to: label) else {
            Issue.record("a blank label passed")
            return
        }
    }

    @Test func fiveChangedPixelsInOneWindowPassAndSixFail() {
        func speck(_ n: Int) -> SnapshotCompare.Pixels {
            image { bytes, width in for x in 0..<n { block(x..<x + 1, 0..<1, 0)(&bytes, width) } }
        }
        #expect(SnapshotCompare.compare(speck(5), to: image()) == .same)
        #expect(SnapshotCompare.compare(speck(6), to: image()) != .same)
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

    @Test func settleTakesTheSizeTwoPassesAgreeOn() {
        // the sheet of profile-import-light (run 45798391475): 3 points short on the first pass
        var passes = [CGSize(width: 640, height: 623), CGSize(width: 640, height: 626), CGSize(width: 640, height: 626)]
        var waits = 0
        let settled = SnapshotCompare.settle(measure: { passes.removeFirst() }, wait: { waits += 1 })
        #expect(settled == .size(CGSize(width: 640, height: 626)))
        #expect(waits == 2)
    }

    @Test func settleStopsWhenTheFirstTwoPassesAgree() {
        var waits = 0
        let settled = SnapshotCompare.settle(measure: { CGSize(width: 320, height: 200) }, wait: { waits += 1 })
        #expect(settled == .size(CGSize(width: 320, height: 200)))
        #expect(waits == 1)
    }

    @Test func aLayoutThatNeverSettlesIsNamed() {
        var tall: CGFloat = 100
        var waits = 0
        let settled = SnapshotCompare.settle(passes: 3, measure: {
            tall += 1.5
            return CGSize(width: 320, height: tall)
        }, wait: { waits += 1 })
        #expect(settled == .unsettled("the layout did not settle: 320 x 101.5 then 320 x 103 then 320 x 104.5"))
        #expect(waits == 2)
    }

    @Test func settleFollowsAViewThatGrowsBetweenPasses() {
        let height = GrowingHeight()
        let hosting = NSHostingView(rootView: GrowingView(height: height))
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        var waits = 0
        let settled = SnapshotCompare.settle(measure: {
            hosting.layoutSubtreeIfNeeded()
            return hosting.fittingSize
        }, wait: {
            waits += 1
            // the change lands after the first pass, as a sheet's measured content does
            if waits == 1 { height.points = 80 }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        })
        guard case .size(let fitted) = settled else {
            Issue.record("the view did not settle: \(settled)")
            return
        }
        #expect(abs(fitted.height - 80) < 0.5 && abs(fitted.width - 100) < 0.5)
        #expect(waits == 2)
    }

    @Test func lightAndDarkOfOneViewHaveOneSize() {
        let short = CGSize(width: 640, height: 623), full = CGSize(width: 640, height: 626)
        #expect(SnapshotCompare.sizeMismatch(of: "profile-import", [("light", full), ("dark", full)]) == nil)
        #expect(SnapshotCompare.sizeMismatch(of: "profile-import", [("light", full)]) == nil)
        let why = SnapshotCompare.sizeMismatch(of: "profile-import", [("light", short), ("dark", full)])
        #expect(why == "profile-import: the light render is 640 x 623 and the dark render is 640 x 626. One of them was taken before its layout settled.")
    }

    @Test func normalizingUsesTwoPointsPerPixel() throws {
        let data = try #require(SnapshotCompare.png(of: image(width: 450, height: 310)))
        let rep = try #require(NSBitmapImageRep(data: data)?.cgImage)
        // a 900 x 620 pt window rendered at 2x is 1800 x 1240 pixels; here a 450 x 310 image stands for 900 x 620 pt
        let pixels = SnapshotCompare.normalize(rep, pointsWide: 900, pointsHigh: 620)
        #expect(pixels.width == 450 && pixels.height == 310)
    }
}
