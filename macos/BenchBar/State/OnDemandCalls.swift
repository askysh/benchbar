import Foundation

/// What an on demand answer for a bench was asked under: the BenchBar
/// window's session and the bench's revision (`BenchStore.stamp(for:)`).
/// A page asks again when it changes.
nonisolated struct QueryStamp: Hashable, Sendable {
    var session: Int
    var revision: Int
}

/// The bookkeeping of one CLI query the BenchBar window makes on demand,
/// doctor or the app list: per bench, the stamp its answer was asked under
/// and the call under way.
///
/// The call runs in a task of its own, never in its caller's: a page's
/// `.task` is cancelled when the person switches tab or bench, and a
/// cancelled call makes swift-subprocess SIGTERM the CLI and report a
/// timeout. A call whose page went away finishes, and its answer is kept.
final class OnDemandCalls {
    private var answered: [String: QueryStamp] = [:]
    private var calls: [String: Task<Void, Never>] = [:]

    /// Asks unless the bench has an answer under the stamp (`force`: the
    /// explicit button, ask anyway). A call under way is joined, never
    /// doubled, and the stamp is read after it: an action that ended
    /// meanwhile makes its answer old, and one more call follows.
    func ask(_ path: String, force: Bool, stamp: () -> QueryStamp, _ call: @escaping @MainActor () async -> Void) async {
        var force = force
        while let running = calls[path] {
            await running.value
            // the page went away: its answer is kept, nothing more is asked
            if Task.isCancelled { return }
            force = false
        }
        let now = stamp()
        guard force || answered[path] != now else { return }
        let task = Task {
            await call()
            self.answered[path] = now
            self.calls[path] = nil
        }
        calls[path] = task
        await task.value
    }
}
