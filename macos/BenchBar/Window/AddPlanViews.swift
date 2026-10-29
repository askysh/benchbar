import SwiftUI

// The plan an Add App or Add Site sheet shows before anything runs: what
// is cloned, built and installed (the numbered steps), then what the change
// touches, and what it leaves alone.

/// Numbered steps in a box: the name, the command it runs and what else it does.
struct PlanStepList: View {
    struct Row: Identifiable {
        var name: String
        var command: String?
        var note: String?
        var id: String { name }
    }

    let rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.spacing) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: WindowMetrics.rowSpacing) {
                    Text("\(index + 1).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(minWidth: 18, alignment: .trailing)
                    VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing) {
                        Text(row.name).font(.callout.weight(.medium))
                        if let command = row.command {
                            Text(command).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(command)
                        }
                        if let note = row.note, !note.isEmpty {
                            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(WindowMetrics.bannerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: WindowMetrics.cornerRadius))
    }
}

/// "Touches", "Restart", "Left alone": a label and its words.
struct PlanFacts: View {
    let facts: [(label: String, text: String)]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: WindowMetrics.spacing, verticalSpacing: 4) {
            ForEach(facts, id: \.label) { fact in
                GridRow {
                    Text(fact.label).font(.callout).foregroundStyle(.secondary)
                    Text(fact.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct AppAddPlanView: View {
    let plan: AppAddPlan

    private var headline: String {
        var parts = ["from \(plan.repo)"]
        if let branch = plan.branch {
            parts.append("branch \(branch)" + (plan.branchSourceText.map { " (\($0))" } ?? ""))
        }
        if let commit = plan.commit { parts.append("commit \(commit.prefix(7))") }
        return parts.joined(separator: ", ")
    }

    /// Only the notes that say something the step's name does not: the
    /// database change of an install and the repair of a half done clone.
    private var rows: [PlanStepList.Row] {
        plan.steps.map { step in
            PlanStepList.Row(name: step.name, command: step.command,
                             note: ["install", "requirements_python"].contains(step.kind) ? step.note : nil)
        }
    }

    private var facts: [(label: String, text: String)] {
        var out: [(label: String, text: String)] = []
        if !plan.touches.isEmpty { out.append(("Touches", plan.touches.joined(separator: ", "))) }
        let targets = plan.sites.map { $0.installed ? "\($0.name) (already has it)" : $0.name }
        out.append(("Sites", targets.isEmpty ? "No site: the app is only added to the bench." : targets.joined(separator: ", ")))
        out.append(("Restart", plan.restarts ? "Restarts the bench, only if it is running." : "No restart."))
        out.append(("Left alone", "/etc/hosts and the default site. Other apps and sites are not changed."))
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.spacing) {
            VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing) {
                Text(plan.app).font(.headline)
                Text(headline).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            if !plan.errors.isEmpty {
                SheetOutcome(symbol: "xmark.octagon.fill", tint: .red, title: "This plan cannot run",
                             detail: plan.errors.joined(separator: "\n"))
            }
            if let reason = plan.reason {
                SheetNote(reason, tint: .orange)
            }
            if let error = plan.sitesError, !error.isEmpty {
                SheetNote("The sites' app lists could not be read, so every chosen site is shown as not having the app: \(error)", tint: .orange)
            }
            if plan.canApply && !plan.changes {
                SheetOutcome(symbol: "checkmark.circle.fill", tint: .green, title: "Nothing to do",
                             detail: "\(plan.app) is already in the bench\(plan.sites.isEmpty ? "" : " and on the chosen site").")
            }
            // a plan that cannot run shows why, not the steps it will not take
            if plan.canApply {
                PlanFacts(facts: facts)
                if !plan.steps.isEmpty {
                    Text("In order:").font(.callout)
                    PlanStepList(rows: rows)
                }
            }
        }
    }
}

struct SiteAddPlanView: View {
    let plan: SiteAddPlan

    /// The hosts step needs sudo, which a process without a terminal cannot
    /// ask for: the CLI skips it there, so the row says Add Site does not run it.
    private var rows: [PlanStepList.Row] {
        plan.steps.map { step in
            PlanStepList.Row(name: step.name, command: step.command,
                             note: step.kind == "hosts" ? "Add Site does not run this step." : nil)
        }
    }

    private var facts: [(label: String, text: String)] {
        var out: [(label: String, text: String)] = []
        if !plan.touchesText.isEmpty { out.append(("Touches", plan.touchesText.joined(separator: ", "))) }
        out.append(("Hosts line", plan.hostsEntry
                    ? "127.0.0.1 \(plan.site) is already in /etc/hosts."
                    : "Needs your Mac's password, which BenchBar never asks for, so it is not added here. The Sites tab's Add Hosts Lines shows the command for Terminal."))
        out.append(("Password", "The Administrator password you typed goes to the benchbar process only."))
        out.append(("Left alone", plan.keptDefaultSite.map { "The default site stays \($0). Other sites and apps are not changed." }
                    ?? "Other sites and apps are not changed."))
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.spacing) {
            Text(plan.site).font(.headline)
            if !plan.changes {
                SheetOutcome(symbol: "checkmark.circle.fill", tint: .green, title: "Nothing to do",
                             detail: "\(plan.site) is already on the bench\(plan.hostsEntry ? " and in /etc/hosts" : "").")
            }
            PlanFacts(facts: facts)
            if !plan.steps.isEmpty {
                Text("In order:").font(.callout)
                PlanStepList(rows: rows)
            }
        }
    }
}
