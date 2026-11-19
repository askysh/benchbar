import SwiftUI

/// Updates and adds that stopped part way, from `status --json`. The CLI keeps the record and the
/// steps left. Resume opens the same reviewed sheet as the normal change (Update, or Add App), which
/// plans only the steps that are left; Drop the Record runs `app update NAME --discard-pending`,
/// which runs none of them. The app decides nothing else here.
struct PendingOperationsSection: View {
    let operations: [PendingOperation]
    let busy: Bool
    let resume: (PendingOperation) -> Void
    let discard: (PendingOperation) -> Void

    var body: some View {
        Section {
            ForEach(operations) { operation in
                HStack(alignment: .firstTextBaseline, spacing: WindowMetrics.rowSpacing) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing + 1) {
                        Text(operation.title).font(.body.weight(.medium))
                        if !operation.detail.isEmpty {
                            Text(operation.detail).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: WindowMetrics.rowSpacing)
                    Button("Resume…") { resume(operation) }
                        .disabled(busy)
                        .help("Shows the steps that are left before anything runs")
                    Button("Drop the Record…") { discard(operation) }
                        .disabled(busy)
                        .help("Forgets the steps that are left. None of them run.")
                }
            }
        } header: {
            Text("Unfinished changes")
        } footer: {
            Text("A change that stopped part way keeps its steps. Resume runs only those; dropping the record leaves the app as it is now.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

nonisolated enum PendingText {
    /// The confirmation of Drop the Record.
    static func discardMessage(_ operation: PendingOperation) -> String {
        let left = operation.steps.count
        let steps = left == 1 ? "its 1 step" : "its \(left) steps"
        return "BenchBar forgets \(steps) and nothing runs now. \(operation.app) stays where it is, so the bench may be half updated: run the update again later to finish it."
    }
}
