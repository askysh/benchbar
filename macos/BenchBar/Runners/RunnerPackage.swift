import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// manifest.json of a custom runner. docs/runners.md is the reference.
///
///     {
///       "name": "Blob",
///       "author": "Your Name",
///       "template": true,
///       "states": { "running": ["run1.png", "run2.png"], "sleeping": ["zzz.png"] },
///       "frame_order": "ping_pong"
///     }
nonisolated struct RunnerManifest: Codable, Equatable, Sendable {
    enum FrameOrder: String, Codable, Sendable {
        /// 1 2 3, 1 2 3
        case forward
        /// 1 2 3 2, 1 2 3 2: a back and forth loop from fewer frames
        case pingPong = "ping_pong"
    }

    var name: String
    var author: String?
    var template: Bool
    var states: [String: [String]]
    var frameOrder: FrameOrder?

    enum CodingKeys: String, CodingKey {
        case name, author, template, states
        case frameOrder = "frame_order"
    }
}

/// Why a runner was rejected, in words for the Settings window.
nonisolated enum RunnerError: Error, Equatable, Sendable, LocalizedError {
    case missingManifest
    case badManifest(String)
    case unknownState(String)
    case noRunningFrames
    case emptyState(String)
    case tooManyFrames(state: String, count: Int)
    case badFileName(String)
    case missingFile(String)
    case notPNG(String)
    case badSize(file: String, width: Int, height: Int)
    case mixedSizes(file: String)
    case tooLarge(bytes: Int)
    case badArchive(String)
    case reservedID(String)

    var errorDescription: String? {
        switch self {
        case .missingManifest: "There is no manifest.json in the runner folder."
        case .badManifest(let detail): "manifest.json could not be read: \(detail)."
        case .unknownState(let state): "\"\(state)\" is not a state. Use sleeping, starting, running, crashed, alert or unknown."
        case .noRunningFrames: "The running state is required: every other state falls back to it."
        case .emptyState(let state): "The \(state) state lists no frames. Leave it out instead."
        case .tooManyFrames(let state, let count): "The \(state) state has \(count) frames; the limit is \(RunnerLoader.maxFrames)."
        case .badFileName(let name): "\"\(name)\" is not an allowed frame name: use a plain .png file name, no folders."
        case .missingFile(let name): "\(name) is listed in manifest.json but is not in the folder."
        case .notPNG(let name): "\(name) is not a PNG image."
        case .badSize(let file, let width, let height):
            "\(file) is \(width) x \(height) px; frames must be \(RunnerLoader.pixelHeight) px tall and \(RunnerLoader.widthRange.lowerBound) to \(RunnerLoader.widthRange.upperBound) px wide."
        case .mixedSizes(let file): "\(file) is not the same size as the other frames."
        case .tooLarge(let bytes): "The runner is \(bytes / 1024) KB; the limit is \(RunnerLoader.maxBytes / 1024 / 1024) MB."
        case .badArchive(let detail): "The zip file could not be used: \(detail)."
        case .reservedID(let id): "\"\(id)\" is the name of a built in runner. Rename the folder."
        }
    }
}

/// Loads and validates a runner folder. Strict on purpose: a runner comes
/// from someone else, and the menu bar is no place for surprises.
nonisolated enum RunnerLoader {
    static let pixelHeight = Runner.pixelHeight
    static let widthRange = 10...100
    static let maxFrames = 30
    static let maxBytes = 2 * 1024 * 1024
    static let manifestName = "manifest.json"

    static func load(folder: URL, id: String) throws(RunnerError) -> Runner {
        let manifest = try readManifest(in: folder)
        _ = try frameFiles(manifest)
        try checkTotalSize(folder)

        var frames: [RunnerPose: [CGImage]] = [:]
        var size: (Int, Int)?
        for (key, names) in manifest.states {
            guard let pose = RunnerPose(rawValue: key) else { throw .unknownState(key) }
            var images: [CGImage] = []
            for name in names {
                let image = try loadPNG(folder.appendingPathComponent(name), name: name)
                if let size, size != (image.width, image.height) { throw .mixedSizes(file: name) }
                size = (image.width, image.height)
                images.append(image)
            }
            frames[pose] = order(images, manifest.frameOrder ?? .forward)
        }
        let width = CGFloat(size?.0 ?? pixelHeight) / Runner.scale
        return Runner(id: id, name: manifest.name, author: manifest.author ?? "", isTemplate: manifest.template,
                      pointWidth: width, frames: frames)
    }

    static func readManifest(in folder: URL) throws(RunnerError) -> RunnerManifest {
        let url = folder.appendingPathComponent(manifestName)
        guard let data = try? Data(contentsOf: url) else { throw .missingManifest }
        guard data.count <= 64 * 1024 else { throw .badManifest("it is larger than 64 KB") }
        let manifest: RunnerManifest
        do {
            manifest = try JSONDecoder().decode(RunnerManifest.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) {
            throw .badManifest("\"\(key.stringValue)\" is missing")
        } catch let DecodingError.typeMismatch(_, context) {
            throw .badManifest("\"\(context.codingPath.map(\.stringValue).joined(separator: "."))\" has the wrong type")
        } catch let DecodingError.dataCorrupted(context) {
            throw .badManifest(context.codingPath.isEmpty ? "it is not valid JSON" : context.debugDescription)
        } catch {
            throw .badManifest("it is not valid JSON")
        }
        let name = manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { throw .badManifest("\"name\" must be 1 to 40 characters") }
        return manifest
    }

    /// Every frame file the manifest names, after checking the states and names.
    static func frameFiles(_ manifest: RunnerManifest) throws(RunnerError) -> Set<String> {
        for key in manifest.states.keys where RunnerPose(rawValue: key) == nil {
            throw .unknownState(key)
        }
        guard let running = manifest.states[RunnerPose.running.rawValue], !running.isEmpty else {
            throw .noRunningFrames
        }
        var files: Set<String> = []
        for pose in RunnerPose.allCases {
            guard let names = manifest.states[pose.rawValue] else { continue }
            if names.isEmpty { throw .emptyState(pose.rawValue) }
            if names.count > maxFrames { throw .tooManyFrames(state: pose.rawValue, count: names.count) }
            for name in names {
                guard isSafeFileName(name) else { throw .badFileName(name) }
                files.insert(name)
            }
        }
        return files
    }

    /// A plain file name ending in .png: no folders, no "..", not hidden,
    /// no control characters.
    static func isSafeFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 100,
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.hasPrefix("."), name.lowercased().hasSuffix(".png"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return false }
        return true
    }

    static func checkTotalSize(_ folder: URL) throws(RunnerError) {
        var total = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        if let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) {
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
            }
        }
        if total > maxBytes { throw .tooLarge(bytes: total) }
    }

    static func loadPNG(_ url: URL, name: String) throws(RunnerError) -> CGImage {
        // a symlink could point anywhere on disk: only plain files count
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else { throw .missingFile(name) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?, type == UTType.png.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw .notPNG(name) }
        guard image.height == pixelHeight, widthRange.contains(image.width) else {
            throw .badSize(file: name, width: image.width, height: image.height)
        }
        return image
    }

    static func order(_ images: [CGImage], _ order: RunnerManifest.FrameOrder) -> [CGImage] {
        guard order == .pingPong, images.count > 2 else { return images }
        return images + images.dropFirst().dropLast().reversed()
    }
}
