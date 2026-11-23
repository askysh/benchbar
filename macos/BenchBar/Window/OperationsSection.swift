import SwiftUI

/// The bench's background operations (`op list --running`): every run that changes things has an op id, and a run started by a
/// terminal, an agent or the tray shows here while it goes on, with its step and progress. A run that was seen going on and has
/// ended since says how (`op status`). Read only: BenchBar cannot stop a run it did not start, and never offers to. Shown only while
/// there is something to show; the Overview reads it while it is on screen and the window is open.
struct OperationsSection: View {
    let workbench: Workbench
    let bench: BenchModel

    var body: some View {
        let running = workbench.runningOps[bench.path] ?? []
        let ended = workbench.endedOps[bench.path] ?? []
        if !running.isEmpty || !ended.isEmpty {
            Section {
                ForEach(running) { op in
                    HStack(alignment: .firstTextBaseline, spacing: WindowMetrics.rowSpacing) {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        Text(OpText.line(op, now: .now)).font(.callout).textSelection(.enabled)
                    }
                }
                ForEach(ended) { op in
                    Label(OpText.ended(op), systemImage: op.state == "done" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(op.state == "done" ? Color.secondary : Color.orange)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Running now")
            } footer: {
                Text("Runs that change things, from a terminal, an agent or the app. BenchBar only lists them. `benchbar op status` follows one.")
            }
        }
    }
}
