import SwiftUI

/// The title block at the top of every pane, in the style of System
/// Settings: a tinted symbol tile, the pane's name and one line on what it
/// is for, with an optional action on the right.
struct PaneHeader<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SymbolTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(symbol: String, tint: Color, title: String, subtitle: String) {
        self.init(symbol: symbol, tint: tint, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A white symbol on a tinted rounded square, like the icons in System Settings.
struct SymbolTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension View {
    /// The main action of a pane: a prominent glass button on macOS 26 and
    /// later, a prominent bordered one before.
    @ViewBuilder func primaryAction() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// A row of page tabs: the macOS 27 tab picker, segmented before.
    @ViewBuilder func pageTabs() -> some View {
        if #available(macOS 27, *) {
            pickerStyle(.tabs)
        } else {
            pickerStyle(.segmented)
        }
    }
}

/// Start, stop, restart, open and show for one bench: the same rules as
/// the popover's buttons, for the sidebar's context menu and the page.
extension BenchStore {
    func controls(for bench: BenchModel) -> BenchControls {
        var cliReady = false
        if case .ready = cli { cliReady = true }
        return .make(state: bench.state, reason: bench.machine.stopReason, pending: bench.pending,
                     needsService: bench.needsService, cliReady: cliReady,
                     otherWork: bench.isChangingScheduler || bench.activity != nil || waitsForOtherBench(bench))
    }
}

struct BenchContextMenu: View {
    let store: BenchStore
    let bench: BenchModel

    var body: some View {
        let controls = store.controls(for: bench)
        Button("Start", systemImage: "play.fill") { Task { await store.perform(.up, on: bench) } }
            .disabled(!controls.canStart)
        Button("Stop", systemImage: "stop.fill") { Task { await store.perform(.down, on: bench) } }
            .disabled(!controls.canStop)
        Button("Restart", systemImage: "arrow.clockwise") { Task { await store.perform(.restart, on: bench) } }
            .disabled(!controls.canRestart)
        Divider()
        Button("Open Site", systemImage: "safari") { Workspace.openSite(bench) }
        Button("Show in Finder", systemImage: "folder") { Workspace.openFolder(bench) }
        Button("Copy Path", systemImage: "doc.on.doc") { Workspace.copy(bench.path) }
    }
}
