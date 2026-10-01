import Foundation

/// Follows a log file the way `tail -F` does: the last part of the file
/// first, then every byte appended, and it survives rotation.
///
/// The runner rotates by truncating `bench.log` (`: >`), and a tool may
/// replace the file with `mv`. A file watcher alone goes quiet after a
/// replacement, so there are two: one on the open file (appends,
/// truncation, rename, delete) and a `DirectoryWatcher` on its folder
/// (the file coming back).
///
/// A busy bench writes many times a second, so events are coalesced: the
/// first one opens a 100 ms window, and one read at its end takes all that
/// came meanwhile. That read asks the open descriptor (`fstat`) for its size;
/// the path is looked at only when the file may have been replaced or
/// removed (a delete or rename event, a change in the folder, nothing open).
/// Each event also asks the descriptor whether the file shrank below what
/// was read: a log truncated and grown past that again before the window
/// closes looks like an append by then.
///
/// Only whole lines are decoded: bytes after the last newline wait for the
/// next read, so a UTF-8 character is never cut in half.
final class LogTailer {
    /// Runs `work` on the main queue after a delay (the tests run it themselves).
    typealias Schedule = (_ delay: DispatchTimeInterval, _ work: @escaping @MainActor () -> Void) -> Void

    let url: URL
    /// How much of an existing file is shown at first (the rest is skipped).
    let initialBytes: Int
    /// How long events gather before the one read that takes them all.
    let window: DispatchTimeInterval
    private let schedule: Schedule
    private let onLines: (String) -> Void
    private let onReset: () -> Void

    private var handle: FileHandle?
    private var inode: UInt64 = 0
    private var offset: UInt64 = 0
    private var pending = Data()
    private var fileSource: DispatchSourceFileSystemObject?
    private var folderWatcher: DirectoryWatcher?
    /// A read is scheduled at the end of the window.
    private var readDue = false
    /// An event in the window may have replaced or removed the file.
    private var pathChanged = false
    /// An event in the window found the file shorter than what was read.
    private var truncated = false
    /// How often the path was looked at (the tests check that appends need none).
    private(set) var pathLookups = 0

    init(url: URL, initialBytes: Int = 256 * 1024, window: DispatchTimeInterval = .milliseconds(100),
         schedule: @escaping Schedule = LogTailer.onMainQueue,
         onLines: @escaping (String) -> Void, onReset: @escaping () -> Void) {
        self.url = url
        self.initialBytes = initialBytes
        self.window = window
        self.schedule = schedule
        self.onLines = onLines
        self.onReset = onReset
    }

    deinit {
        fileSource?.cancel()
        try? handle?.close()
    }

    func start() {
        open(fromEnd: true)
        let watcher = DirectoryWatcher(target: url.deletingLastPathComponent()) { [weak self] in self?.changed(replaced: true) }
        watcher.start()
        folderWatcher = watcher
    }

    func stop() {
        readDue = false
        pathChanged = false
        truncated = false
        fileSource?.cancel()
        fileSource = nil
        folderWatcher?.stop()
        folderWatcher = nil
        try? handle?.close()
        handle = nil
    }

    /// Something happened to the file or its folder: one read at the end of
    /// the window, for this event and every one until then. `replaced`: the
    /// file may be gone, or another one now has its name. A truncation is
    /// noted now (one `fstat`): by the window's end the file may be longer
    /// than before again.
    func changed(replaced: Bool) {
        if replaced { pathChanged = true }
        if !truncated, let handle, let now = Self.info(fd: handle.fileDescriptor), now.size < offset {
            truncated = true
        }
        guard !readDue else { return }
        readDue = true
        schedule(window) { [weak self] in self?.windowClosed() }
    }

    /// Reads what was appended; reads again from the start after a
    /// truncation, and opens the file again after a replacement. With
    /// `checkPath` false the open descriptor says it all (an append or a
    /// truncation). Safe to call any time (tests call it directly).
    func readNew(checkPath: Bool = true) {
        if checkPath || handle == nil {
            pathLookups += 1
            guard let now = Self.info(path: url.path) else {
                // gone for now (rotated with mv, not back yet): wait for the folder.
                // A truncation seen in this window still marks the end of the run.
                if truncated { onReset() }
                closeFile()
                return
            }
            if handle == nil || now.inode != inode {
                if handle != nil { onReset() }
                open(fromEnd: false)
                return
            }
        }
        guard let handle, let now = Self.info(fd: handle.fileDescriptor) else { return }
        if truncated || now.size < offset {
            // truncated in place (the runner's ": >"): the same file, from the top
            truncated = false
            onReset()
            offset = 0
            pending = Data()
        }
        readToEnd()
    }

    // MARK: -

    private func windowClosed() {
        guard readDue else { return }   // stopped meanwhile
        readDue = false
        let checkPath = pathChanged
        pathChanged = false
        readNew(checkPath: checkPath)
    }

    private func open(fromEnd: Bool) {
        closeFile()
        guard let handle = try? FileHandle(forReadingFrom: url), let info = Self.info(fd: handle.fileDescriptor) else { return }
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
            MainActor.assumeIsolated {
                guard let self, let events = self.fileSource?.data else { return }
                self.changed(replaced: !events.isDisjoint(with: [.delete, .rename]))
            }
        }
        source.resume()
        fileSource = source
    }

    private func closeFile() {
        truncated = false
        fileSource?.cancel()
        fileSource = nil
        try? handle?.close()
        handle = nil
    }

    /// The main queue, `delay` from now.
    nonisolated static func onMainQueue(after delay: DispatchTimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated(work)
        }
    }

    /// Inode and size of an open file, one `fstat`.
    nonisolated static func info(fd: Int32) -> (inode: UInt64, size: UInt64)? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        return (UInt64(info.st_ino), UInt64(max(0, info.st_size)))
    }

    /// Inode and size of what the path names now, one `stat`.
    nonisolated static func info(path: String) -> (inode: UInt64, size: UInt64)? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return (UInt64(info.st_ino), UInt64(max(0, info.st_size)))
    }
}
