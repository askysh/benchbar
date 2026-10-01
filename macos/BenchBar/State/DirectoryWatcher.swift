import Foundation

/// Calls `onChange` when a file in a folder is created, renamed or deleted.
///
/// We watch the folder `logs/.benchbar`, not `state.json`: the runner
/// replaces the file with `mv`, and a watcher on the old file would go
/// quiet after the first replacement. A folder watcher sees every rename.
///
/// If the folder does not exist yet (the bench never ran under the new
/// runner), we watch its parent until it appears. The app never creates
/// folders inside a bench.
///
/// A cleanup tool can delete the folder and its parent under us: the fd then
/// names a deleted folder and hears nothing more. `needsRestart` says so, and
/// the store starts the watcher again when it next reads the bench's files.
final class DirectoryWatcher {
    let target: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var watchingTarget = false
    /// The folder the fd was opened on and its inode then: a folder deleted
    /// and made again under the same path is a new one the fd does not see.
    private var watched: (url: URL, inode: ino_t)?
    private var debounce: DispatchWorkItem?

    init(target: URL, onChange: @escaping () -> Void) {
        self.target = target
        self.onChange = onChange
    }

    deinit {
        source?.cancel()
    }

    var isWatchingTarget: Bool { watchingTarget }

    /// Not watching what it should: nothing at all (both folders were missing
    /// at the last start), a folder that is gone, or the parent while the
    /// target exists again. Two stat calls at most.
    var needsRestart: Bool {
        guard source != nil, let watched else { return true }
        var info = stat()
        guard stat(watched.url.path, &info) == 0, info.st_ino == watched.inode else { return true }
        return !watchingTarget && FileManager.default.fileExists(atPath: target.path)
    }

    func start() {
        stop()
        watchingTarget = watch(target)
        if !watchingTarget {
            // the parent may be gone too: then nothing is watched, and
            // needsRestart stays true
            _ = watch(target.deletingLastPathComponent())
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        watched = nil
        debounce?.cancel()
    }

    private func watch(_ folder: URL) -> Bool {
        // O_EVTONLY: open only to get events, so the folder can still be
        // deleted or unmounted while we hold it
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        var info = stat()
        guard fstat(fd, &info) == 0 else { close(fd); return false }
        watched = (folder, info.st_ino)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.fired() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        return true
    }

    private func fired() {
        if needsRestart {
            // the folder appeared, or it (or its parent) was deleted: watch
            // the right one, or nothing until the store tries again
            start()
        }
        // several events arrive for one mv; report once
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
    }
}
