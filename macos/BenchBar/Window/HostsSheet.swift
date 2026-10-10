import Foundation
import Observation
import SwiftUI

/// Add Hosts Lines: `benchbar site hosts --yes` for one bench, after the
/// user said yes in the sheet. The password is asked by macOS's own dialog
/// (BENCHBAR_SUDO=gui); BenchBar never sees it. A cancelled dialog leaves the
/// command to copy and run in Terminal.
@Observable
final class HostsRun: Identifiable {
    enum Phase: Equatable {
        case ready
        case running
        case added
        /// The dialog was cancelled or the step skipped: the line is not there.
        case skipped(String)
        case failed(String)
    }

    private(set) var phase: Phase = .ready
    let bench: BenchModel
    let store: BenchStore

    init(bench: BenchModel, store: BenchStore) {
        self.bench = bench
        self.store = store
    }

    /// The sites that still need a line.
    var missing: [String] { bench.siteRows.filter(\.needsHosts).map(\.name) }

    /// What to run in Terminal instead.
    var command: String { BenchText.command("site hosts", bench: bench.path) }

    var isRunning: Bool { phase == .running }

    func run() async {
        guard phase == .ready || phase.isRetryable else { return }
        phase = .running
        var outcome: HostsOutcome = .added
        let error = await store.runChange("Adding hosts lines", on: bench) { client throws(CLIError) in
            outcome = HostsOutcome.classify(try await client.siteHosts(bench: bench.path))
        }
        if let error {
            phase = .failed(error)
            return
        }
        switch outcome {
        case .added: phase = .added
        case .skipped(let line): phase = .skipped(line)
        case .failed(let message): phase = .failed(message)
        }
    }
}

private extension HostsRun.Phase {
    var isRetryable: Bool {
        switch self {
        case .skipped, .failed: true
        case .ready, .running, .added: false
        }
    }
}

extension HostsRun {
    var sheetPhase: SheetPhase {
        switch phase {
        case .ready: .ready
        case .running: .running("Waiting for macOS to ask for your password…")
        case .added: .done(.success("The hosts lines are in.", "The site names resolve to this Mac now."))
        case .skipped(let line): .done(.warning("Nothing was added", line))
        case .failed(let message): .failed(message, title: "The hosts lines were not added")
        }
    }
}

struct HostsSheet: View {
    let run: HostsRun
    let close: () -> Void

    var body: some View {
        SheetScaffold("Add Hosts Lines",
                      explanation: "Adds the site names of \(run.bench.name) to /etc/hosts, so they open in your browser.",
                      phase: run.sheetPhase) {
            if run.phase == .ready || run.phase == .running {
                VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing + 2) {
                    ForEach(run.missing, id: \.self) { name in
                        Label(name, systemImage: "globe").font(.callout)
                    }
                }
                SheetNote("macOS asks for your password in its own dialog; BenchBar never sees it. Cancel the dialog and nothing changes.")
            } else if run.phase != .added {
                Text("Or run this in Terminal:").font(.callout).foregroundStyle(.secondary)
                CopyableCommand(command: run.command, copyLabel: "Copy the command that adds the hosts lines")
            }
        } actions: {
            switch run.phase {
            case .ready:
                CancelButton(action: close)
                Button("Add Hosts Lines") { Task { await run.run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(run.missing.isEmpty || !run.store.canChange(run.bench))
            case .running:
                EmptyView()
            case .added:
                DoneButton(action: close)
            case .skipped, .failed:
                CancelButton(title: "Close", action: close)
                Button("Try Again") { Task { await run.run() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
