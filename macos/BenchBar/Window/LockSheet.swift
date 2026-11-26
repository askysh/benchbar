import SwiftUI

nonisolated extension LockPlan: ReviewablePlan {
    /// Something to write or apply: "unchanged" is a plan with nothing to do.
    var canRun: Bool { !unchanged && !lines.isEmpty }
}

/// Write Lock File and Apply for the team lockfile (`benchbar.toml`). The CLI prints both plans as text;
/// the sheet shows exactly that text from `--dry-run`, and only the person's click runs the command.
/// `lock apply` goes by the plan's token when the CLI gives one; without one it runs `lock apply --yes`
/// after the OK, which the CLI recomputes itself.
struct LockSheet: View {
    enum Kind: Equatable, Identifiable {
        case write, apply

        var id: Kind { self }

        var title: String { self == .write ? "Write the Lock File" : "Apply the Lock File" }
        var action: String { self == .write ? "Write Lock File" : "Apply" }
        var explanation: String {
            self == .write
                ? "Writes benchbar.toml from this bench: the apps with their branches and commits, and the sites. You see what goes into the file first; an existing file is backed up."
                : "Clones missing apps, switches branches and fast forwards the apps to the pinned commits, then builds the changed ones. No site is touched."
        }
    }

    let workbench: Workbench
    let bench: BenchModel
    let kind: Kind
    let close: () -> Void
    @State private var flow = PlanReviewFlow<LockPlan>()

    private var phase: SheetPhase {
        switch flow.stage {
        case .form:
            if let error = flow.readError { .failed(error, title: kind == .write ? String(localized: "No plan to write the lock file") : String(localized: "No plan to apply the lock file")) } else { .loading(String(localized: "Reading the lock file and the bench…")) }
        case .reading: .loading(String(localized: "Reading the lock file and the bench…"))
        case .reviewing: .ready
        case .applying: .running(kind == .write ? String(localized: "Writing the lock file…") : String(localized: "Applying the lock file to the apps…"))
        case .stale: .failed(String(localized: "Nothing was changed. Review the plan again to see what it is now."), title: String(localized: "The bench or the lock file changed since this plan was shown"))
        }
    }

    var body: some View {
        SheetScaffold(kind.title, explanation: kind.explanation, phase: phase, width: .wide) {
            if let plan = flow.plan { planView(plan) }
        } actions: {
            switch flow.stage {
            case .form, .reading:
                CancelButton(action: close)
                if flow.readError != nil { Button("Review Again") { review() }.keyboardShortcut(.defaultAction) }
            case .reviewing(let plan):
                CancelButton(action: close)
                Button(kind.action) { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!plan.canRun)
            case .applying:
                EmptyView()
            case .stale:
                CancelButton(action: close)
                Button("Review Again") { review() }.keyboardShortcut(.defaultAction)
            }
        }
        .task { review() }
    }

    @ViewBuilder private func planView(_ plan: LockPlan) -> some View {
        if plan.unchanged {
            SheetOutcome(symbol: "checkmark.seal.fill", tint: .green, title: String(localized: "Nothing to do"),
                         detail: kind == .write ? String(localized: "The file already says this.") : String(localized: "The apps already match the lock file."))
        }
        Text(plan.text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WindowMetrics.bannerPadding)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: WindowMetrics.cornerRadius))
        if kind == .apply, plan.canRun, plan.token == nil {
            SheetNote(String(localized: "This benchbar gives no plan token for the lock file, so Apply runs lock apply after your OK. It reads the lock file again then."))
        }
    }

    private func review() {
        guard flow.review() else { return }
        Task { flow.read(kind == .write ? await workbench.lockWritePlan(on: bench) : await workbench.lockApplyPlan(on: bench)) }
    }

    private func apply() {
        guard let plan = flow.apply() else { return }
        Task {
            let error = kind == .write ? await workbench.writeLock(on: bench) : await workbench.applyLock(token: plan.token, on: bench)
            // a stale token is answered here, with Review Again, not in the banner
            if flow.finish(error: error) { close() } else { workbench.result = nil }
        }
    }
}
