import Foundation

/// Follows a log file the way `tail -F` does: the last part of the file
/// first, then every byte appended, and it survives rotation.
///
/// The runner rotates by truncating `bench.log` (`: >`), and a tool may
/// replace the file with `mv`. A file watcher alone goes quiet after a
/// replacement, so there are two: one on the open file (appends,
/// truncation, rename, delete) and a `DirectoryWatcher` on its folder
/// (the file coming back). Every event ends in `readNew()`, which compares
/// the file's inode and size with what it has read so far.
///
/// Only whole lines are decoded: bytes after the last newline wait for the
/// next read, so a UTF-8 character is never cut in half.
final class LogTailer {
    let url: URL
    /// How much of an existing file is shown at first (the rest is skipped).
    let initialBytes: Int
    private let onLines: (String) -> Void
    private let onReset: () -> Void

    private var handle: FileHandle?
    private var inode: UInt64 = 0
    private var offset: UInt64 = 0
    private var pending = Data()
    private var fileSource: DispatchSourceFileSystemObject?
    private var folderWatcher: DirectoryWatcher?

    init(url: URL, initialBytes: Int = 256 * 1024, onLines: @escaping (String) -> Void, onReset: @escaping () -> Void) {
        self.url = url
        self.initialBytes = initialBytes
        self.onLines = onLines
        self.onReset = onReset
    }

    deinit {
        fileSource?.cancel()
        try? handle?.close()
    }

    func start() {
        open(fromEnd: true)
        let watcher = DirectoryWatcher(target: url.deletingLastPathComponent()) { [weak self] in self?.readNew() }
        watcher.start()
        folderWatcher = watcher
    }

    func stop() {
        fileSource?.cancel()
        fileSource = nil
        folderWatcher?.stop()
        folderWatcher = nil
        try? handle?.close()
        handle = nil
    }

    /// Reads what was appended; reopens from the start after a truncation
    /// or a replacement. Safe to call any time (tests call it directly).
    func readNew() {
        guard let now = Self.stat(url) else {
            // gone for now (rotated with mv, not back yet): wait for the folder
            closeFile()
            return
        }
        if handle == nil || now.inode != inode || now.size < offset {
            if handle != nil { onReset() }
            open(fromEnd: false)
            return
        }
        readToEnd()
    }

    // MARK: -

    private func open(fromEnd: Bool) {
        closeFile()
        guard let info = Self.stat(url), let handle = try? FileHandle(forReadingFrom: url) else { return }
        self.handle = handle
        inode = info.inode
        pending = Data()
        offset = 0
        if fromEnd, info.size > UInt64(initialBytes) {
            offset = info.size - UInt64(initialBytes)
            try? handle.seek(toOffset: offset)
            // start at a line boundary: drop the first, partial line
            if let first = try? handle.read(upToCount: min(initialBytes, 64 * 1024)),
               let nl = first.firstIndex(of: 0x0A) {
                offset += UInt64(nl - first.startIndex + 1)
            }
            try? handle.seek(toOffset: offset)
        }
        watchFile(handle)
        readToEnd()
    }

    private func readToEnd() {
        guard let handle else { return }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        offset += UInt64(data.count)
        pending.append(data)
        guard let lastNewline = pending.lastIndex(of: 0x0A) else { return }
        let complete = pending[pending.startIndex...lastNewline]
        pending = Data(pending[pending.index(after: lastNewline)...])
        onLines(String(decoding: complete, as: UTF8.self))
    }

    private func watchFile(_ handle: FileHandle) {
        fileSource?.cancel()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor, eventMask: [.extend, .write, .delete, .rename, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readNew() }
        }
        source.resume()
        fileSource = source
    }

    private func closeFile() {
        fileSource?.cancel()
        fileSource = nil
        try? handle?.close()
        handle = nil
    }

    nonisolated static func stat(_ url: URL) -> (inode: UInt64, size: UInt64)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber else { return nil }
        return (inode.uint64Value, size.uint64Value)
    }
}
