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
        // reading these registers the view for their changes; drawing only
        // reads the model, never writes it
        _ = model.changes
        _ = model.buffer.lines.last?.id
        _ = model.follow
        context.coordinator.sync()
    }

    final class Coordinator: NSObject {
        let model: LogViewModel
        private weak var scroll: NSScrollView?
        private weak var text: NSTextView?
        private var drawnChanges = -1
        /// The newest line looked at (drawn, or hidden by the filter).
        private var drawnThrough = -1
        /// The lines in the text, oldest first, with their length (newline
        /// included): what the buffer drops from its top leaves the text too.
        private var drawn: [(id: Int, length: Int)] = []
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
                let visible = model.visible
                storage.setAttributedString(Self.render(visible, matches: Set(model.matches), current: model.currentMatchID))
                drawn = visible.map { ($0.id, Self.length(of: $0)) }
                drawnChanges = model.changes
            } else {
                appendNewLines(to: storage)
            }
            drawnThrough = model.buffer.lines.last?.id ?? -1
            if let id = model.currentMatchID, let range = range(of: id) {
                scrolling { text.scrollRangeToVisible(range) }
            } else if model.follow {
                scrolling { text.scrollToEndOfDocument(nil) }
            }
        }

        /// The lines that came since the last sync, in one edit of the text:
        /// those the buffer dropped leave the top, the new visible ones go at
        /// the end. A busy log gets one layout pass per read, not one per line.
        /// While the person reads scrolled up the top stays: the clip view
        /// keeps its offset, so a cut there slides the text under them. The
        /// dropped lines leave with the first sync that follows again, or
        /// the next redraw.
        private func appendNewLines(to storage: NSTextStorage) {
            let first = model.buffer.lines.first?.id ?? Int.max
            var dropped = 0, cut = 0
            while model.follow, dropped < drawn.count, drawn[dropped].id < first {
                cut += drawn[dropped].length
                dropped += 1
            }
            let added = model.visible(after: drawnThrough)
            guard cut > 0 || !added.isEmpty else { return }
            storage.beginEditing()
            if cut > 0 { storage.deleteCharacters(in: NSRange(location: 0, length: cut)) }
            if !added.isEmpty {
                storage.append(Self.render(added, matches: Set(model.query.matches(in: added)), current: nil))
            }
            storage.endEditing()
            drawn.removeFirst(dropped)
            drawn += added.map { ($0.id, Self.length(of: $0)) }
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

        /// Where line `id` sits in the text: counted over the lines drawn,
        /// which can start above the buffer's first while scrolled up.
        private func range(of id: Int) -> NSRange? {
            var location = 0
            for line in drawn {
                if line.id == id { return NSRange(location: location, length: max(0, line.length - 1)) }
                location += line.length
            }
            return nil
        }

        /// A line's length in the text: UTF-16 units, its newline included.
        static func length(of line: LogLine) -> Int {
            (line.text as NSString).length + 1
        }
    }
}
