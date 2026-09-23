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
final class DirectoryWatcher {
    let target: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var watchingTarget = false
    private var debounce: DispatchWorkItem?

    init(target: URL, onChange: @escaping () -> Void) {
        self.target = target
        self.onChange = onChange
    }

    deinit {
        source?.cancel()
    }

    var isWatchingTarget: Bool { watchingTarget }

    func start() {
        stop()
        if watch(target) {
            watchingTarget = true
        } else if watch(target.deletingLastPathComponent()) {
            watchingTarget = false
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        debounce?.cancel()
    }

    private func watch(_ folder: URL) -> Bool {
        // O_EVTONLY: open only to get events, so the folder can still be
        // deleted or unmounted while we hold it
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return false }
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
        let targetExists = FileManager.default.fileExists(atPath: target.path)
        if watchingTarget != targetExists {
            // the folder appeared, or was deleted: watch the right one
            start()
        }
        // several events arrive for one mv; report once
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
    }
}
