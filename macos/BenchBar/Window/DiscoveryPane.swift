import SwiftUI

struct DiscoveryPane: View {
    @Bindable var discovery: BenchDiscovery
    @Bindable var router: WindowRouter
    @State private var adoption: AdoptionRun?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Find your benches").font(.title2.bold())
                Text("Choose a project folder. BenchBar searches inside it for existing Frappe benches.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Image(systemName: "folder")
                Text(discovery.folder.isEmpty ? "No folder selected" : discovery.folder)
                    .font(.callout).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Button("Choose Folder…", action: chooseFolder)
                    .disabled(discovery.isScanning || discovery.isAdding)
                if !discovery.folder.isEmpty {
                    Button("Scan Again") { discovery.scan(folder: discovery.folder) }
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
                ContentUnavailableView("No benches found", systemImage: "folder.badge.questionmark",
                    description: Text("Choose a folder containing a bench or its parent projects. Hidden folders, dependencies, tests and symlinks are skipped."))
            } else if !discovery.results.isEmpty {
                HStack {
                    Text("\(discovery.results.count) benches found").font(.headline)
                    Spacer()
                    Button("Select All") { discovery.selected = discovery.availablePaths }
                        .disabled(discovery.availablePaths.isEmpty || discovery.isAdding)
                    Button("Clear Selection") { discovery.selected = [] }
                        .disabled(discovery.selected.isEmpty || discovery.isAdding)
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
                        .buttonStyle(.borderedProminent)
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
        .padding(24)
        .task {
            if router.scanRequested { router.scanRequested = false; chooseFolder() }
        }
        .onChange(of: router.scanRequested) { _, requested in
            if requested { router.scanRequested = false; chooseFolder() }
        }
        .sheet(item: $adoption) { run in AdoptionSheet(run: run) { adoption = nil } }
    }

    private func chooseFolder() {
        guard !discovery.isScanning, !discovery.isAdding,
              let path = Workspace.chooseScanFolder(previous: discovery.folder) else { return }
        discovery.scan(folder: path)
    }

    private func resultRow(_ result: BenchSummary) -> some View {
        let known = discovery.store.benches.first { $0.path == result.path }
        return HStack(alignment: .top, spacing: 12) {
            Toggle(isOn: Binding(
                get: { discovery.selected.contains(result.path) },
                set: { if $0 { discovery.selected.insert(result.path) } else { discovery.selected.remove(result.path) } }
            )) { Text("Select \(result.name) at \(result.path)") }
                .toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel("Select \(result.name) at \(result.path)")
                .disabled(known != nil || discovery.isAdding)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.name).font(.headline)
                Text(result.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(result.site) · Port \(String(result.ports.web))").font(.caption).foregroundStyle(.secondary)
                if let known {
                    Label(known.needsService ? "Added · Management needs setup" : "Managed by BenchBar",
                          systemImage: known.needsService ? "wrench" : "checkmark.circle")
                        .font(.caption)
                }
            }
            Spacer(minLength: 8)
            if let known {
                if known.needsService {
                    Button("Set Up Management…") {
                        let run = AdoptionRun(bench: known, store: discovery.store)
                        adoption = run
                        Task { await run.loadPlan() }
                    }
                    .disabled(discovery.store.busyBench != nil || discovery.isAdding)
                } else {
                    Button("Open") { router.show(bench: result.path) }
                }
            }
        }
        .padding(.vertical, 12)
    }
}

private struct AdoptionSheet: View {
    let run: AdoptionRun
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up management for \(run.bench.name)").font(.headline)
            Text(run.bench.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            switch run.phase {
            case .planning:
                ProgressView("Checking the bench and preparing the plan…")
            case .running:
                ProgressView("Setting up BenchBar management…")
            case .failed(let error):
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
            case .finished:
                Label("Management is set up. Start the bench when you are ready.", systemImage: "checkmark.circle")
            case .review:
                Text("Review the service changes below. Existing apps and databases are preserved. Stop any previous manager's automatic startup before continuing.")
                    .font(.callout)
            }
            if !run.output.isEmpty {
                ScrollView([.horizontal, .vertical]) {
                    Text(run.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 260)
            }
            Text("If a hosts entry needs your password, setup reports the Terminal command to complete it.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(run.phase == .review ? "Cancel" : "Done", action: close)
                    .disabled(run.phase == .running || run.phase == .planning)
                if run.phase == .review {
                    Button("Set Up Management") { Task { await run.run() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20).frame(width: 660)
        .interactiveDismissDisabled(run.phase == .running || run.phase == .planning)
    }
}
