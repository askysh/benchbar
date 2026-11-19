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
        HStack(alignment: .center, spacing: WindowMetrics.spacing) {
            SymbolTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: WindowMetrics.spacing)
            trailing
        }
        .padding(.horizontal, WindowMetrics.paneInset).padding(.top, 16).padding(.bottom, 6)
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

private nonisolated struct DrawsGlassKey: EnvironmentKey {
    static let defaultValue = true
}

nonisolated extension EnvironmentValues {
    /// Off in the snapshot tests: an offscreen render (cacheDisplay) cannot
    /// draw Liquid Glass, so a glass button would show as bare text.
    var drawsGlass: Bool {
        get { self[DrawsGlassKey.self] }
        set { self[DrawsGlassKey.self] = newValue }
    }
}

private nonisolated struct RendersOffscreenKey: EnvironmentKey {
    static let defaultValue = false
}

nonisolated extension EnvironmentValues {
    /// On in the snapshot tests, which draw the view with `cacheDisplay` in a
    /// window that is on no screen. Only the parts that a sidebar's vibrancy or
    /// the macOS 27 tab picker leave white or blank there look different; the
    /// app itself never sets it. See macos/DECISIONS.md.
    var rendersOffscreen: Bool {
        get { self[RendersOffscreenKey.self] }
        set { self[RendersOffscreenKey.self] = newValue }
    }
}

private nonisolated struct PinnedNowKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

nonisolated extension EnvironmentValues {
    /// A fixed "now" for the text that counts time (uptime, "Backed up 3
    /// hours ago"). Set only by the snapshot tests, so two renders of the
    /// same view draw the same text; nil in the app, which uses the clock.
    var pinnedNow: Date? {
        get { self[PinnedNowKey.self] }
        set { self[PinnedNowKey.self] = newValue }
    }
}

/// Flattens a small status mark to an image when drawn offscreen, so its
/// colour survives a sidebar that draws it as white.
private struct OffscreenSafe: ViewModifier {
    @Environment(\.rendersOffscreen) private var offscreen

    func body(content: Content) -> some View {
        if offscreen { content.drawingGroup() } else { content }
    }
}

/// The style behind `primaryAction()`.
private struct PrimaryActionStyle: ViewModifier {
    @Environment(\.drawsGlass) private var drawsGlass

    func body(content: Content) -> some View {
        if #available(macOS 26, *), drawsGlass {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

extension View {
    /// The main action of a pane: a prominent glass button on macOS 26 and
    /// later, a prominent bordered one before.
    func primaryAction() -> some View {
        modifier(PrimaryActionStyle())
    }

    /// A status mark that survives an offscreen render (see `rendersOffscreen`).
    func offscreenSafe() -> some View { modifier(OffscreenSafe()) }

    /// A row of page tabs: the macOS 27 tab picker, segmented before.
    func pageTabs() -> some View { modifier(PageTabs()) }
}

/// The picker style of `pageTabs()`: segmented when drawn offscreen, where the
/// macOS 27 tab picker draws its selected tab as a blank pill. The compiler
/// check keeps the build working with Xcode 26 (the CI runners), whose SDK has
/// no .tabs; #available alone is a run time check.
private struct PageTabs: ViewModifier {
    @Environment(\.rendersOffscreen) private var offscreen

    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.4)
        if #available(macOS 27, *), !offscreen {
            content.pickerStyle(.tabs)
        } else {
            content.pickerStyle(.segmented)
        }
        #else
        content.pickerStyle(.segmented)
        #endif
    }
}

/// Start, stop, restart, open and show for one bench, in the sidebar: the
/// same rules as the popover's buttons (`BenchStore.controls(for:)`).
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
