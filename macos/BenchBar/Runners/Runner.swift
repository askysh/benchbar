import CoreGraphics
import Foundation

/// A character for the menu bar: a few frames per pose, all the same size.
///
/// Frames are @2x bitmaps, 36 px tall for the 18 pt menu bar slot. A
/// template runner is drawn in black; only its alpha counts, and the
/// animator tints it with the menu bar's text color, like a template
/// NSImage. A non template runner keeps its own colors.
nonisolated struct Runner: Sendable, Identifiable {
    static let pointHeight: CGFloat = 18
    static let scale: CGFloat = 2
    static let pixelHeight = Int(pointHeight * scale)

    let id: String
    let name: String
    let author: String
    let isTemplate: Bool
    /// Width in points (the frame's pixel width divided by the scale).
    let pointWidth: CGFloat
    let frames: [RunnerPose: [CGImage]]

    var size: CGSize { CGSize(width: pointWidth, height: Self.pointHeight) }

    /// The frames for a pose. A pose the runner does not have falls back to
    /// `running`, the one pose every runner must have.
    func frames(for pose: RunnerPose) -> [CGImage] {
        if let own = frames[pose], !own.isEmpty { return own }
        return frames[.running] ?? []
    }
}

extension Runner {
    /// The runners that ship with the app, drawn in code.
    nonisolated static let builtIns: [Runner] = [BenchRunnerArt.make(), CupRunnerArt.make()]

    nonisolated static let defaultID = "bench"

    /// A built in runner by id, or the default one.
    nonisolated static func builtIn(_ id: String) -> Runner {
        builtIns.first { $0.id == id } ?? builtIns[0]
    }
}
