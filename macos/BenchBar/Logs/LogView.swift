import AppKit
import SwiftUI

/// The log window's content: a toolbar row and the text.
struct LogView: View {
    @Bindable var model: LogViewModel
    let openInTerminal: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 10).padding(.vertical, 7)
            Divider()
            LogTextView(model: model)
        }
        .frame(minWidth: 620, minHeight: 360)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Process", selection: $model.query.process) {
                Text("All processes").tag(String?.none)
                ForEach(LogQuery.processes, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden()
            .frame(width: 150)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $model.query.search)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 120)
                    .onSubmit { model.step(forward: true) }
                Text(model.searchSummary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button { model.step(forward: false) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).keyboardShortcut("g", modifiers: [.command, .shift]).help("Previous match (⇧⌘G)")
                Button { model.step(forward: true) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).keyboardShortcut("g", modifiers: .command).help("Next match (⌘G)")
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            Spacer()
            Toggle("Previous log", isOn: $model.showPrevious)
                .toggleStyle(.checkbox)
                .help("logs/bench.previous.log: the end of the log before the last start")
            Toggle("Follow", isOn: $model.follow)
                .toggleStyle(.checkbox)
                .help("Stick to the newest line; scrolling up turns it off")
            Button("Clear") { model.clear() }.help("Empty the view; the file is not touched")
            Button("Open in Terminal", action: openInTerminal)
        }
        .controlSize(.small)
    }
}

/// An NSTextView: fast for thousands of lines, and select and copy work.
struct LogTextView: NSViewRepresentable {
    let model: LogViewModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.usesFindBar = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 6, height: 6)
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.attach(scroll: scroll, text: text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // reading these registers the view for their changes
        _ = model.changes
        _ = model.appended.count
        _ = model.follow
        context.coordinator.sync()
    }

    final class Coordinator: NSObject {
        let model: LogViewModel
        private weak var scroll: NSScrollView?
        private weak var text: NSTextView?
        private var drawnChanges = -1
        /// Set while the view scrolls itself, so that is not taken as the user scrolling up.
        private var scrollingProgrammatically = false

        init(model: LogViewModel) { self.model = model }

        func attach(scroll: NSScrollView, text: NSTextView) {
            self.scroll = scroll
            self.text = text
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                                   name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }

        /// Smart scroll: at the bottom, follow; scrolled up, stop following.
        @objc private func boundsChanged() {
            guard !scrollingProgrammatically else { return }
            let atBottom = isAtBottom
            if model.follow != atBottom { model.follow = atBottom }
        }

        private var isAtBottom: Bool {
            guard let scroll, let doc = scroll.documentView else { return true }
            return scroll.contentView.bounds.maxY >= doc.bounds.maxY - 24
        }

        func sync() {
            guard let text, let storage = text.textStorage else { return }
            if drawnChanges != model.changes {
                storage.setAttributedString(Self.render(model.visible, matches: Set(model.matches), current: model.currentMatchID))
                drawnChanges = model.changes
                model.consumeAppended()
            } else if !model.appended.isEmpty {
                let matches = Set(model.query.matches(in: model.appended))
                storage.append(Self.render(model.appended, matches: matches, current: nil))
                model.consumeAppended()
            }
            if let id = model.currentMatchID, let range = Self.range(of: id, in: model.visible, storage: storage) {
                scrolling { text.scrollRangeToVisible(range) }
            } else if model.follow {
                scrolling { text.scrollToEndOfDocument(nil) }
            }
        }

        private func scrolling(_ work: () -> Void) {
            scrollingProgrammatically = true
            work()
            scrollingProgrammatically = false
        }

        static func render(_ lines: [LogLine], matches: Set<Int>, current: Int?) -> NSAttributedString {
            let out = NSMutableAttributedString()
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            for line in lines {
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: line.isError ? NSColor.systemRed : NSColor.labelColor]
                if line.id == current {
                    attributes[.backgroundColor] = NSColor.systemOrange.withAlphaComponent(0.45)
                } else if matches.contains(line.id) {
                    attributes[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.3)
                }
                out.append(NSAttributedString(string: line.text + "\n", attributes: attributes))
            }
            return out
        }

        /// Where line `id` sits in the text (lines are drawn one per row, in order).
        static func range(of id: Int, in lines: [LogLine], storage: NSTextStorage) -> NSRange? {
            var location = 0
            for line in lines {
                let length = (line.text as NSString).length + 1
                if line.id == id { return NSRange(location: location, length: max(0, length - 1)) }
                location += length
            }
            return nil
        }
    }
}
