import SwiftUI

struct DiscoveryPane: View {
    @Bindable var discovery: BenchDiscovery
    @Bindable var router: WindowRouter
    @State private var setup: PortSetupRun?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(symbol: "folder.badge.plus", tint: .teal, title: "Find Benches",
                       subtitle: "BenchBar searches a project folder for existing Frappe benches.") {
                // the main action until there are results; then Set Up Selected is
                Button("Choose Folder…", action: chooseFolder)
                    .primaryAction(discovery.results.isEmpty)
                    .disabled(discovery.isScanning || discovery.isAdding)
            }
            content
                .padding(WindowMetrics.paneInset)
        }
        .task {
            if router.scanRequested { router.scanRequested = false; chooseFolder() }
        }
        .onChange(of: router.scanRequested) { _, requested in
            if requested { router.scanRequested = false; chooseFolder() }
        }
        .sheet(item: $setup) { run in PortSetupSheet(run: run) { setup = nil } }
    }

    /// Every selectable bench is selected: the selection button deselects.
    private var allSelected: Bool {
        !discovery.selectablePaths.isEmpty && discovery.selectablePaths.isSubset(of: discovery.selected)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.spacing) {
            HStack(spacing: WindowMetrics.rowSpacing) {
                Image(systemName: "folder").accessibilityHidden(true)
                Text(discovery.folder.isEmpty ? "No folder selected" : discovery.folder)
                    .font(.callout).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                if !discovery.folder.isEmpty {
                    Button { discovery.scan(folder: discovery.folder) } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Scan Again")
                        .help("Scan this folder again")
                        .disabled(discovery.isScanning || discovery.isAdding)
                }
            }
            if discovery.isScanning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Searching folders…")
                    Spacer()
                    Button("Cancel Scan") { discovery.cancelScan() }
                }
            }
            if let error = discovery.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
            }
            if let message = discovery.message {
                Text(message).foregroundStyle(.secondary).accessibilityLabel(message)
            }
            if !discovery.warnings.isEmpty {
                DisclosureGroup("\(discovery.warnings.count) scan warning(s)") {
                    ForEach(discovery.warnings, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                }
            }
            if discovery.hasScanned && discovery.results.isEmpty {
                ContentUnavailableView {
                    Label("No benches found", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("Choose a folder containing a bench or its parent projects. Hidden folders, dependencies, tests and symlinks are skipped.")
                } actions: {
                    Button("Choose Another Folder…", action: chooseFolder)
                }
            } else if !discovery.results.isEmpty {
                HStack {
                    Text("\(discovery.results.count) benches found").font(.headline)
                    Spacer()
                    if allSelected {
                        Button("Deselect All") { discovery.selected = [] }
                            .disabled(discovery.selected.isEmpty || discovery.isAdding)
                    } else {
                        Button("Select All") { discovery.selected = discovery.selectablePaths }
                            .disabled(discovery.selectablePaths.isEmpty || discovery.isAdding)
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(discovery.results) { result in
                            resultRow(result)
                            Divider()
                        }
                    }
                }
                HStack {
                    Text("\(discovery.selected.count) selected").foregroundStyle(.secondary)
                    Spacer()
                    if discovery.isAdding { ProgressView().controlSize(.small) }
                    Button("Add Selected") { Task { await discovery.addSelected() } }
                        .disabled(discovery.selected.intersection(discovery.availablePaths).isEmpty || discovery.isAdding || discovery.store.busyBench != nil)
                    Button("Set Up Selected…") {
                        preview(discovery.results.filter { discovery.selected.contains($0.path) })
                    }
                    .primaryAction()
                    .disabled(discovery.selected.isEmpty || discovery.isAdding || discovery.store.busyBench != nil)
                }
            } else if !discovery.isScanning {
                ContentUnavailableView("Your benches, in one place", systemImage: "folder.badge.plus",
                    description: Text("Start with a folder such as Developer. Review the results, then add the benches you want to manage."))
            }
            Spacer(minLength: 0)
            Text("Scanning only reads folders. Add Selected remembers your benches; Set Up Management previews the service changes before you apply them.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func preview(_ summaries: [BenchSummary]) {
        let run = PortSetupRun(summaries: summaries, store: discovery.store)
        setup = run
        Task { await run.loadPlan() }
    }

    private func chooseFolder() {
        guard !discovery.isScanning, !discovery.isAdding,
              let path = Workspace.chooseScanFolder(previous: discovery.folder) else { return }
        discovery.scan(folder: path)
    }

    private func resultRow(_ result: BenchSummary) -> some View {
        let known = discovery.store.benches.first { $0.path == result.path }
        return HStack(alignment: .top, spacing: WindowMetrics.spacing) {
            Toggle(isOn: Binding(
                get: { discovery.selected.contains(result.path) },
                set: { if $0 { discovery.selected.insert(result.path) } else { discovery.selected.remove(result.path) } }
            )) { Text("Select \(result.name) at \(result.path)") }
                .toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel("Select \(result.name) at \(result.path)")
                .disabled(discovery.isAdding)
            VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing + 2) {
                Text(result.name).font(.headline)
                Text(result.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(result.site) · Port \(String(result.ports.web))").font(.caption).foregroundStyle(.secondary)
                if discovery.hasPortConflict(result) {
                    Label("Port conflict · Review during setup", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let known {
                    Label(known.needsService ? "Added · Management needs setup" : "Managed by BenchBar",
                          systemImage: known.needsService ? "wrench" : "checkmark.circle")
                        .font(.caption)
                }
            }
            Spacer(minLength: WindowMetrics.rowSpacing)
            if let known {
                if known.needsService {
                    Button("Set Up Management…") {
                        preview([known.summary])
                    }
                    .disabled(discovery.store.busyBench != nil || discovery.isAdding)
                } else {
                    Button("Open") { router.show(bench: result.path) }
                }
            }
        }
        .padding(.vertical, WindowMetrics.spacing)
    }
}
