import SwiftUI

/// Who holds a lease on the bench or on one of its sites, and until when (`lease list --json`). Shown only while
/// there is one. BenchBar never takes, renews or releases a lease: an agent holds it, and BenchBar waits for it
/// like every other benchbar command. Only a person's "Break Lease" on a refused change goes ahead (LeaseBreakRow).
struct LeaseSection: View {
    let workbench: Workbench
    let bench: BenchModel

    var body: some View {
        let leases = workbench.leases[bench.path] ?? []
        if !leases.isEmpty {
            Section {
                ForEach(leases) { lease in
                    Label(LeaseText.line(lease), systemImage: "lock.fill")
                        .font(.callout)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Leases")
            } footer: {
                Text("While a lease stands, restart, stop, app changes, site drop and restore, and the lockfile wait for the holder. Starting and reading are never stopped.")
            }
        }
    }
}

nonisolated extension CLIClient.Action {
    /// The button's word, for the alert that asks before a lease is broken.
    var title: String {
        switch self {
        case .up: "Start"
        case .down: "Stop"
        case .restart: "Restart"
        }
    }
}
