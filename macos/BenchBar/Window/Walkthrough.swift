import SwiftUI

/// The four step walkthrough: what the menu bar runner, the popover, the
/// window and the Terminal helpers are for. Pure, so the steps and the rule
/// for showing it on its own once are unit tests.
nonisolated struct WalkthroughModel: Equatable, Sendable {
    enum Step: Int, CaseIterable, Sendable {
        case runner, popover, window, terminal

        var title: String {
            switch self {
            case .runner: "The runner is your bench"
            case .popover: "The popover starts, stops and opens it"
            case .window: "The window holds everything else"
            case .terminal: "Terminal and coding agents"
            }
        }

        var line: String {
            switch self {
            case .runner: "The character in the menu bar shows the state of your benches: asleep when stopped, running when up, stumbling when one crashes."
            case .popover: "Click the runner for Start, Stop, Restart and Open Site. They have shortcuts while the popover is open."
            case .window: "Every bench's sites, apps and health are in the BenchBar window. Repair shows its plan before it changes anything."
            case .terminal: "The same commands work in Terminal, and coding agents can use benchbar too."
            }
        }
    }

    static let steps = Step.allCases
    private(set) var index = 0

    var step: Step { Self.steps[index] }
    var isFirst: Bool { index == 0 }
    var isLast: Bool { index == Self.steps.count - 1 }
    var progress: String { "\(index + 1) of \(Self.steps.count)" }
    var primaryTitle: String { isLast ? "Done" : "Next" }

    /// Return: the next step, and true when the last one was already shown.
    mutating func next() -> Bool {
        if isLast { return true }
        index += 1
        return false
    }

    mutating func back() { if index > 0 { index -= 1 } }

    /// It opens by itself once: when the window shows a bench for the first
    /// time and the person has not seen it. Never from the wizard's page.
    static func shouldShowOnItsOwn(seen: Bool, benchCount: Int, onWizard: Bool) -> Bool {
        !seen && benchCount >= 1 && !onWizard
    }
}

struct WalkthroughSheet: View {
    @State private var model: WalkthroughModel
    let close: () -> Void

    init(start index: Int = 0, close: @escaping () -> Void) {
        var model = WalkthroughModel()
        for _ in 0..<index { _ = model.next() }
        _model = State(initialValue: model)
        self.close = close
    }

    var body: some View {
        SheetScaffold(model.step.title, explanation: model.step.line) {
            visual
            Text(model.progress).font(.caption).foregroundStyle(.secondary)
        } leading: {
            Button("Back") { model.back() }.disabled(model.isFirst)
        } actions: {
            CancelButton(title: "Skip", action: close)
            Button(model.primaryTitle) { if model.next() { close() } }
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private var visual: some View {
        switch model.step {
        case .runner: RunnerTour()
        case .popover:
            HStack(spacing: WindowMetrics.spacing) {
                ForEach([BenchShortcut.start, .stop, .openSite], id: \.self) { shortcut in
                    VStack(spacing: WindowMetrics.lineSpacing) {
                        Text(shortcut.display).font(.title3.monospaced())
                        Text(shortcut.action).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(WindowMetrics.bannerPadding)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: WindowMetrics.cornerRadius))
                }
            }
        case .window:
            VStack(alignment: .leading, spacing: WindowMetrics.rowSpacing) {
                Label("Sites: add, open, back up", systemImage: "globe")
                Label("Apps: add and update after reading the changelog", systemImage: "square.stack.3d.up")
                Label("Health: doctor's checks, and Repair with its plan first", systemImage: "stethoscope")
            }
            .font(.callout)
        case .terminal:
            VStack(alignment: .leading, spacing: WindowMetrics.rowSpacing) {
                Text("benchup, benchdown and benchlogs start, stop and follow a bench.").font(.callout)
                CopyableCommand(command: "benchup", copyLabel: "Copy benchup")
                CopyableCommand(command: "benchdown", copyLabel: "Copy benchdown")
                CopyableCommand(command: "benchlogs", copyLabel: "Copy benchlogs")
                Text("For Claude Code and other agents:").font(.callout).foregroundStyle(.secondary)
                CopyableCommand(command: MCPSnippet.claude, copyLabel: "Copy the command that adds benchbar mcp")
            }
        }
    }
}

/// The first step's picture: the runner asleep, running and stumbling. It
/// cycles; with Reduce Motion the three poses stand side by side.
struct RunnerTour: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    static let states: [BenchState] = [.stopped, .running, .crashed]
    static let words = ["Stopped", "Running", "Crashed"]

    var body: some View {
        let runner = Runner.builtIn(Runner.defaultID)
        Group {
            if reduceMotion {
                HStack {
                    ForEach(Array(Self.states.enumerated()), id: \.offset) { i, state in
                        VStack(spacing: WindowMetrics.lineSpacing) {
                            RunnerPreview(runner: runner, state: state, scale: 3).frame(height: Runner.pointHeight * 3)
                            Text(Self.words[i]).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            } else {
                VStack(spacing: WindowMetrics.lineSpacing) {
                    RunnerPreview(runner: runner, state: Self.states[index], scale: 3).frame(height: Runner.pointHeight * 3)
                    Text(Self.words[index]).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2.5))
                        index = (index + 1) % Self.states.count
                    }
                }
            }
        }
        .padding(.vertical, WindowMetrics.spacing)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: WindowMetrics.cornerRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The runner asleep when the bench is stopped, running when it is up, stumbling when it crashed")
    }
}
