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

    /// Same runner and same frames: a re-imported runner keeps its id but
    /// brings new images.
    func isSame(as other: Runner) -> Bool {
        id == other.id && frames(for: .running).first === other.frames(for: .running).first
    }

    /// The frames for a pose. A pose the runner does not have falls back to
    /// `running`, the one pose every runner must have.
    func frames(for pose: RunnerPose) -> [CGImage] {
        if let own = frames[pose], !own.isEmpty { return own }
        return frames[.running] ?? []
    }
}

extension Runner {
    /// Pixels per point `RunnerCanvas.render` draws at: the menu bar's 2, or
    /// the preview's own size times the screen's backing scale, while
    /// `builtIn(_:renderedAt:)` makes a runner. Read only inside that lock.
    nonisolated(unsafe) static var renderScale: CGFloat = Runner.scale
    private nonisolated static let renderLock = NSLock()

    /// A built in runner drawn at `pixelsPerPoint` instead of 2: the preview
    /// draws it at its own size, so it is sharp rather than the menu bar's
    /// 36 px frames enlarged. Nil for a runner that is not a built in.
    nonisolated static func builtIn(_ id: String, renderedAt pixelsPerPoint: CGFloat) -> Runner? {
        guard builtIns.contains(where: { $0.id == id }) else { return nil }
        renderLock.lock()
        defer { renderLock.unlock() }
        renderScale = pixelsPerPoint
        defer { renderScale = Runner.scale }
        return makeBuiltIns().first { $0.id == id }
    }

    /// The runners that ship with the app, drawn in code.
    nonisolated static let builtIns: [Runner] = makeBuiltIns()

    /// Draws every built in at the current `renderScale`.
    nonisolated static func makeBuiltIns() -> [Runner] { [BenchRunnerArt.make(), CupRunnerArt.make()] }

    nonisolated static let defaultID = "bench"

    /// A built in runner by id, or the default one.
    nonisolated static func builtIn(_ id: String) -> Runner {
        builtIns.first { $0.id == id } ?? builtIns[0]
    }
}
