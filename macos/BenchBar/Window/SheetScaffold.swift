import SwiftUI

// The pieces every sheet of the BenchBar window is built from, and the
// sizes the window uses. The rules (macos/DECISIONS.md, "0.7: one way to
// build a sheet"):
//
//   - one scaffold: a title, one line on what the sheet does, the content
//     (scrolling past a maximum height), then the footer
//   - the footer: a secondary action on the left when there is one, then
//     Cancel to the left of the one primary action on the right
//   - Return is the primary action, Esc is Cancel; a destructive action is
//     never the default button and is confirmed in the sheet first
//   - one state layout for reading a plan, the review, the run, the result
//     and a failure (SheetPhase), so every sheet looks the same at each step

/// Spacing, sizes and corner radius for the window and its sheets.
nonisolated enum WindowMetrics {
    /// Left and right inset of pane chrome (headers, tabs, banners).
    static let paneInset: CGFloat = 20
    /// Around a sheet's title, content and footer.
    static let sheetPadding: CGFloat = 20
    /// Between the blocks of a sheet or a banner.
    static let spacing: CGFloat = 12
    /// Between the controls of a row, and an icon and its text.
    static let rowSpacing: CGFloat = 8
    /// Between a title and the line under it.
    static let lineSpacing: CGFloat = 2
    /// Banners and boxed text.
    static let cornerRadius: CGFloat = 8
    /// Inside a banner.
    static let bannerPadding: CGFloat = 10
    /// A sheet's content scrolls past this height; title and footer stay.
    static let sheetMaxContentHeight: CGFloat = 520

    /// Two sheet widths: forms and plans, and the wider plans with tables.
    enum SheetWidth: CGFloat, Sendable {
        case regular = 520
        case wide = 640
    }
}

/// Where a sheet is: reading its plan, showing it, running it, done, or
/// failed. The scaffold draws every state but `.ready` the same way in every
/// sheet; the content draws the plan or the form.
nonisolated enum SheetPhase: Equatable, Sendable {
    /// Reading the plan: a progress line with what is being read.
    case loading(String)
    /// The form, the plan, the confirmation.
    case ready
    /// The change runs: a progress line in the footer, the sheet cannot be dismissed.
    case running(String)
    /// The outcome on top of the content.
    case done(SheetResult)
    /// What went wrong, on top of the content.
    case failed(String, title: String? = nil)

    var isRunning: Bool { if case .running = self { true } else { false } }
    var isLoading: Bool { if case .loading = self { true } else { false } }
    var isBusy: Bool { isRunning || isLoading }
}

/// The outcome of a sheet's change.
nonisolated struct SheetResult: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case success, warning }
    var kind: Kind = .success
    var title: String
    var detail: String?

    static func success(_ title: String, _ detail: String? = nil) -> SheetResult {
        SheetResult(kind: .success, title: title, detail: detail)
    }

    static func warning(_ title: String, _ detail: String? = nil) -> SheetResult {
        SheetResult(kind: .warning, title: title, detail: detail)
    }
}

/// A sheet: title, one line of explanation, content, footer.
struct SheetScaffold<Content: View, Leading: View, Actions: View>: View {
    let title: String
    let explanation: String?
    var phase: SheetPhase = .ready
    var width: WindowMetrics.SheetWidth = .regular
    @ViewBuilder var content: Content
    @ViewBuilder var leading: Leading
    @ViewBuilder var actions: Actions

    @State private var contentHeight: CGFloat = 0

    init(_ title: String, explanation: String? = nil, phase: SheetPhase = .ready, width: WindowMetrics.SheetWidth = .regular,
         @ViewBuilder content: () -> Content, @ViewBuilder leading: () -> Leading, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.explanation = explanation
        self.phase = phase
        self.width = width
        self.content = content()
        self.leading = leading()
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding([.horizontal, .top], WindowMetrics.sheetPadding)
                .padding(.bottom, WindowMetrics.spacing)
            ScrollView {
                VStack(alignment: .leading, spacing: WindowMetrics.spacing) {
                    SheetStatus(phase: phase)
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, WindowMetrics.sheetPadding)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, WindowMetrics.sheetMaxContentHeight))
            footer
                .padding(WindowMetrics.sheetPadding)
        }
        .frame(width: width.rawValue)
        .interactiveDismissDisabled(phase.isRunning)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing + 2) {
            Text(title).font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let explanation {
                Text(explanation).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var footer: some View {
        HStack(spacing: WindowMetrics.rowSpacing) {
            if case .running(let text) = phase {
                ProgressView().controlSize(.small)
                Text(text).foregroundStyle(.secondary).lineLimit(1)
            }
            leading
            Spacer(minLength: WindowMetrics.rowSpacing)
            actions
        }
    }
}

extension SheetScaffold where Leading == EmptyView {
    init(_ title: String, explanation: String? = nil, phase: SheetPhase = .ready, width: WindowMetrics.SheetWidth = .regular,
         @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.init(title, explanation: explanation, phase: phase, width: width, content: content, leading: { EmptyView() }, actions: actions)
    }
}

/// The progress line, the outcome or the failure on top of a sheet's content.
struct SheetStatus: View {
    let phase: SheetPhase

    var body: some View {
        switch phase {
        case .loading(let text):
            HStack(spacing: WindowMetrics.rowSpacing) {
                ProgressView().controlSize(.small)
                Text(text).foregroundStyle(.secondary)
            }
        case .done(let result):
            SheetOutcome(symbol: result.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                         tint: result.kind == .success ? .green : .orange, title: result.title, detail: result.detail)
        case .failed(let message, let title):
            SheetOutcome(symbol: "exclamationmark.triangle.fill", tint: .red, title: title ?? "That did not work",
                         detail: message, monospaced: message.contains("\n"))
        case .ready, .running:
            EmptyView()
        }
    }
}

/// A tinted symbol, a title and the detail underneath: the result or the
/// failure of a sheet.
struct SheetOutcome: View {
    let symbol: String
    let tint: Color
    let title: String
    var detail: String?
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: WindowMetrics.rowSpacing) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing + 2) {
                Text(title).font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(monospaced ? .caption.monospaced() : .callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(WindowMetrics.bannerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: WindowMetrics.cornerRadius))
        .accessibilityElement(children: .combine)
    }
}

/// The small print at the end of a sheet's content: what happens to
/// passwords, backups, files.
struct SheetNote: View {
    let text: String
    var tint: Color = .secondary

    init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Cancel: on the left of the primary action, Esc.
struct CancelButton: View {
    var title = "Cancel"
    let action: () -> Void

    var body: some View {
        Button(title, role: .cancel, action: action).keyboardShortcut(.cancelAction)
    }
}

/// Done or Close, when there is nothing left to confirm: Return and Esc.
struct DoneButton: View {
    var title = "Done"
    let action: () -> Void

    var body: some View {
        Button(title, action: action).keyboardShortcut(.defaultAction)
    }
}

/// A command for Terminal with a Copy button: for the steps that need the
/// Mac's password, which BenchBar never asks for.
struct CopyableCommand: View {
    let command: String
    var copyLabel = "Copy the command"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: WindowMetrics.rowSpacing) {
            Text(command).font(.callout.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: WindowMetrics.rowSpacing)
            Button("Copy") { Workspace.copy(command) }
                .accessibilityLabel(copyLabel)
                .help(command)
        }
    }
}

/// The trailing "…" menu of a pane, a section or a row: the actions used
/// less often, so they stay one click away without a button each.
struct MoreMenu<Items: View>: View {
    let help: String
    @ViewBuilder var items: Items

    init(help: String, @ViewBuilder items: () -> Items) {
        self.help = help
        self.items = items()
    }

    var body: some View {
        Menu { items } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(help)
            .help(help)
    }
}

/// A message across the top of a pane: an update, a link that did nothing,
/// the outcome of the last change. Its actions sit under the text, and the
/// close button carries a label for VoiceOver.
struct PaneBanner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var detail: String?
    var dismissHelp = "Dismiss"
    var dismiss: (() -> Void)?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: WindowMetrics.rowSpacing) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing + 2) {
                Text(title).font(.callout.weight(.medium))
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
            }
            Spacer(minLength: WindowMetrics.rowSpacing)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(dismissHelp)
                    .help(dismissHelp)
            }
        }
        .padding(WindowMetrics.bannerPadding)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: WindowMetrics.cornerRadius))
    }
}

extension PaneBanner where Actions == EmptyView {
    init(symbol: String, tint: Color, title: String, detail: String? = nil, dismissHelp: String = "Dismiss", dismiss: (() -> Void)? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, detail: detail, dismissHelp: dismissHelp, dismiss: dismiss) { EmptyView() }
    }
}

extension View {
    /// `primaryAction()` only when `on`: a pane whose main action changes
    /// with the state keeps one prominent button at a time.
    @ViewBuilder func primaryAction(_ on: Bool) -> some View {
        if on { primaryAction() } else { self }
    }
}
