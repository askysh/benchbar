import SwiftUI

/// What ran on this Mac and changed something (`benchbar history --json`): who started it and how it ended.
/// Read only: the list is the CLI's own record, and nothing here runs anything again.
struct HistoryPane: View {
    let workbench: Workbench

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(symbol: "clock.arrow.circlepath", tint: .teal, title: "History",
                       subtitle: "Every run that changed something on this Mac, newest first: who started it and how it ended.") {
                Button("Refresh") { Task { await workbench.loadHistory() } }
                    .disabled(workbench.loadingHistory)
            }
            if let error = workbench.historyError {
                PaneBanner(symbol: "exclamationmark.triangle.fill", tint: .orange, title: String(localized: "The history could not be read"), detail: error)
                    .padding(.horizontal, WindowMetrics.paneInset).padding(.top, 6)
            }
            if workbench.history.isEmpty && workbench.historyError == nil {
                if workbench.loadingHistory {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyStateBlock(symbol: "clock", title: "Nothing has run yet",
                                    line: "A start, a backup, an app change or a restore shows here once it has run.", actions: [], disabled: false)
                        .padding(WindowMetrics.paneInset)
                    Spacer()
                }
            } else {
                List(workbench.history) { entry in HistoryRow(entry: entry) }
            }
        }
        .task { await workbench.loadHistory() }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: WindowMetrics.rowSpacing) {
            Image(systemName: entry.exit == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(entry.exit == 0 ? Color.green : Color.red)
                .accessibilityLabel(HistoryText.result(entry))
            VStack(alignment: .leading, spacing: 2) {
                Text(HistoryText.title(entry)).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text("\(HistoryText.who(entry)), \(HistoryText.result(entry))").font(.caption).foregroundStyle(.secondary)
                if let changes = HistoryText.changes(entry) {
                    Text(changes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let bench = entry.bench {
                    Text(URL(fileURLWithPath: bench).lastPathComponent).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: WindowMetrics.rowSpacing)
            if let start = entry.startedAt {
                Text(start.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            if let log = entry.log {
                Button("Show Log") { Workspace.reveal([log]) }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
