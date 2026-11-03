import AppKit
import SwiftUI

/// The bench's Sharing tab: one primary button per state, the room code
/// card, the checks, the copy, the people in the room and recent activity.
struct SharingTab: View {
    let bench: BenchModel
    let share: ShareStore
    @State private var hours = 4
    @State private var setupOpen = false
    @State private var showActivity = false

    private var site: String { bench.summary.site }

    var body: some View {
        Form {
            if let error = share.lastError {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            if let status = share.status {
                if status.needsNewerCLI {
                    Section {
                        Text(SharePresentation.newerCLI)
                        Button("Update") { NSWorkspace.shared.open(BenchBarLinks.docs) }
                    }
                } else {
                    primarySection(status)
                    if status.isOn { roomSection(status) }
                    noticesSection(status)
                    checksSection(status)
                    if let copy = status.copy { copySection(copy, status: status) }
                    if status.isOn { peopleSection(status) ; activitySection }
                }
            } else {
                Section { ProgressView().controlSize(.small) }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: WindowMetrics.groupedFormMaxWidth)
        .frame(maxWidth: .infinity)
        .onAppear { share.tabVisible = true }
        .onDisappear { share.tabVisible = false }
        .sheet(isPresented: $setupOpen) {
            ShareSetupSheet(share: share, site: site, refresh: share.status?.copy != nil) { setupOpen = false }
        }
    }

    // MARK: sections

    @ViewBuilder
    private func primarySection(_ status: ShareStatus) -> some View {
        Section {
            Text(SharePresentation.liveUpdates).foregroundStyle(.secondary)
            HStack {
                if status.isOn {
                    Text(SharePresentation.indicator(status))
                    Spacer()
                    Menu("Extend") {
                        ForEach(SharePresentation.extendOptions(canExtendS: status.canExtendS), id: \.minutes) { option in
                            Button(option.label) { Task { await share.extend(minutes: option.minutes) } }
                        }
                    }
                    .fixedSize()
                    .disabled(SharePresentation.extendOptions(canExtendS: status.canExtendS).isEmpty)
                } else if case .start = SharePrimary.from(status) {
                    Picker("For", selection: $hours) {
                        ForEach(SharePresentation.durations, id: \.self) { Text("\($0) h").tag($0) }
                    }
                    .fixedSize()
                    Spacer()
                } else {
                    Spacer()
                }
                primaryButton(status)
            }
            if status.isOn { Text(SharePresentation.awake).font(.caption).foregroundStyle(.secondary) }
            if let busy = share.busy { Label(busy, systemImage: "hourglass").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder
    private func primaryButton(_ status: ShareStatus) -> some View {
        let primary = SharePrimary.from(status)
        Button(primary.title) { Task { await act(primary, status: status) } }
            .buttonStyle(.borderedProminent)
            .disabled(share.busy != nil || primary == .start(enabled: false))
    }

    private func act(_ primary: SharePrimary, status: ShareStatus) async {
        switch primary {
        case .setUp: setupOpen = true
        case .turnOnProtection: await turnOnProtection()
        case .start:
            guard ShareConfirm.ask("Start sharing \(site) on this network?",
                                   detail: "People on this Wi-Fi who have the room code can join a copy of \(site) until you stop.",
                                   button: "Start sharing") else { return }
            await share.start(hours: hours, label: nil)
            await share.loadCode()
        case .stop:
            guard ShareConfirm.ask(SharePresentation.stopConfirm(online: status.devicesOnline), button: "Stop") else { return }
            await share.stop()
        case .updateCLI: NSWorkspace.shared.open(BenchBarLinks.docs)
        }
    }

    private func turnOnProtection() async {
        guard ShareConfirm.ask("Turn on network protection?",
                               detail: "macOS asks for your password in its own dialog. The rules keep the bench's ports closed to other Macs while sharing.",
                               button: "Continue") else { return }
        await share.installNetworkProtection()
    }

    @ViewBuilder
    private func roomSection(_ status: ShareStatus) -> some View {
        Section("Room code") {
            HStack(alignment: .firstTextBaseline) {
                Text(share.code?.spaced ?? "••• •••")
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .textSelection(.disabled)
                    .accessibilityLabel("Room code")
                Spacer()
                Button("Copy") { if let code = share.code { ShareClipboard.copy(code.code) } }
                    .disabled(share.code == nil)
                Button("New code") { Task { await share.loadCode(new: true) } }
                Button(status.locked == true ? "Unlock" : "Lock room") {
                    Task { await share.setLocked(!(status.locked ?? false)) }
                }
            }
            Text(SharePresentation.codeNote).foregroundStyle(.secondary)
            Text(SharePresentation.codeProves).font(.caption).foregroundStyle(.secondary)
        }
        .task(id: status.isOn) { if share.code == nil { await share.loadCode() } }
    }

    @ViewBuilder
    private func noticesSection(_ status: ShareStatus) -> some View {
        let lock = SharePresentation.lockLine(status)
        if lock != nil || status.joinTrouble || status.wipeFailed > 0 || status.degraded != nil || status.error != nil {
            Section {
                if let lock { Label(lock, systemImage: "lock.fill").foregroundStyle(status.lockReason == .budget ? .orange : .secondary) }
                if status.joinTrouble { Label(SharePresentation.joinTrouble, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if status.wipeFailed > 0 { Label(SharePresentation.wipeOwed, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if let degraded = status.degraded { Label(degraded, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if let error = status.error { Label(error, systemImage: "xmark.octagon").foregroundStyle(.red) }
            }
        }
    }

    @ViewBuilder
    private func checksSection(_ status: ShareStatus) -> some View {
        Section("Checks") {
            HStack {
                Text(SharePresentation.protectionText(status.lanGuard))
                Spacer()
                if status.lanGuard != .installed {
                    Button("Turn on network protection") { Task { await turnOnProtection() } }
                }
            }
            ForEach(status.preflight?.checks ?? []) { check in
                HStack {
                    Image(systemName: check.status == .ok ? "checkmark.circle.fill" : check.status == .fail ? "xmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(check.status == .ok ? .green : check.status == .fail ? .red : .orange)
                    Text(SharePresentation.checkTitle(check))
                    Spacer()
                    if check.status != .ok, let label = SharePresentation.fixLabel(check.fixAction) {
                        Button(label) { Task { await fix(check.fixAction) } }
                    }
                }
            }
        }
    }

    private func fix(_ action: ShareFixAction) async {
        switch action {
        case .none: break
        case .installNetworkProtection: await turnOnProtection()
        case .allowNodeFirewall:
            guard ShareConfirm.ask("Allow sharing through the firewall?",
                                   detail: "macOS asks for your password in its own dialog.", button: "Allow") else { return }
            await share.allowNodeThroughFirewall()
        case .openLocalNetworkSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") { NSWorkspace.shared.open(url) }
        case .updateCLI: NSWorkspace.shared.open(BenchBarLinks.docs)
        case .rerunSetup, .refreshCopy: setupOpen = true
        case .restartSharing:
            await share.stop()
            await share.start(hours: hours, label: nil)
        }
    }

    @ViewBuilder
    private func copySection(_ copy: ShareCopy, status: ShareStatus) -> some View {
        Section("The copy") {
            Text(SharePresentation.copyLine(copy))
            if copy.drifted { Label(SharePresentation.driftWarning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            HStack {
                Button("Refresh copy…") {
                    if ShareConfirm.ask("Refresh the copy?", detail: SharePresentation.refreshConfirm, button: "Refresh") { setupOpen = true }
                }
                .disabled(status.isOn)
                if status.isOn {
                    Menu("Open copy as…") {
                        ForEach(status.allowedUsers, id: \.self) { user in
                            Button(user) {
                                guard ShareConfirm.ask("Open the copy as \(user)?", detail: "BenchBar signs in to the copy in your browser.", button: "Open") else { return }
                                Task { await share.openAs(user) }
                            }
                        }
                    }
                    .fixedSize()
                }
            }
        }
    }

    @ViewBuilder
    private func peopleSection(_ status: ShareStatus) -> some View {
        Section(SharePresentation.peopleTitle) {
            if share.people.isEmpty { Text("Nobody has joined yet.").foregroundStyle(.secondary) }
            ForEach(SharePresentation.sorted(share.people)) { person in
                HStack {
                    Circle().fill(person.online ? Color.green : Color.secondary).frame(width: 8, height: 8)
                    VStack(alignment: .leading) {
                        Text(SharePresentation.personLine(person))
                        Text(person.seatFullName ?? "No seat yet").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let targets = SharePresentation.moveTargets(for: person, people: share.people, known: share.knownSeats)
                    Menu("Move to") {
                        ForEach(targets, id: \.id) { seat in
                            Button(seat.name) { Task { await share.assign(person, seat: seat.id) } }
                        }
                    }
                    .fixedSize()
                    .disabled(targets.isEmpty || share.busy != nil)
                    .help(targets.isEmpty ? "No free seat this room has shown yet." : "Signs them out of their seat and into the one you pick.")
                    Button("Remove") { Task { await remove(person) } }
                }
            }
        }
    }

    private func remove(_ person: SharePerson) async {
        switch ShareConfirm.removeChoice(SharePresentation.removeConfirm(person, site: site)) {
        case .cancel: return
        case .remove: await share.remove(person, newCode: false)
        case .removeAndNewCode: await share.remove(person, newCode: true)
        }
    }

    private var activitySection: some View {
        Section {
            let names = Dictionary(share.people.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            ForEach(Array(share.log.suffix(showActivity ? 50 : 5).enumerated()), id: \.offset) { _, entry in
                Text(SharePresentation.activityLine(entry, names: names)).font(.callout)
            }
            Toggle("Show the last 50", isOn: $showActivity)
            Text(SharePresentation.activityNote).font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Activity")
        }
        .task(id: share.people.count) { await share.loadLog() }
    }
}

/// The app's own alerts before a room action (U3: risky calls follow one).
enum ShareConfirm {
    static func ask(_ message: String, detail: String = "", button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    enum RemoveChoice { case cancel, remove, removeAndNewCode }

    /// J14: a fresh identity can rejoin with the old code, so Remove offers a new code too.
    static func removeChoice(_ message: String) -> RemoveChoice {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "They cannot rejoin from this Mac. Someone who knows the code could join again from another identity; Remove and change code stops that."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Remove and change code")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .remove
        case .alertSecondButtonReturn: return .removeAndNewCode
        default: return .cancel
        }
    }
}

/// The only way the code reaches the pasteboard: an explicit Copy click,
/// marked concealed and transient so clipboard history tools skip it.
enum ShareClipboard {
    static func copy(_ code: String) {
        let board = NSPasteboard.general
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(code, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        board.writeObjects([item])
    }
}

/// Set up sharing: the site, the people (seats), the source, the data acknowledgement.
struct ShareSetupSheet: View {
    let share: ShareStore
    let site: String
    let refresh: Bool
    let close: () -> Void
    @State private var form: ShareSetupForm
    @State private var plan: ShareSetupPlan?
    @State private var step: String?
    @State private var running = false

    init(share: ShareStore, site: String, refresh: Bool, close: @escaping () -> Void) {
        self.share = share
        self.site = site
        self.refresh = refresh
        self.close = close
        _form = State(initialValue: ShareSetupForm(site: site))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(refresh ? "Refresh the shared copy" : "Set up sharing").font(.title2.bold())
            Text("Site: \(site)").foregroundStyle(.secondary)
            Picker("Source", selection: $form.backupNow) {
                Text(ShareSetupForm.sourceLabel(backupNow: true, estMinutes: plan?.estMinutes, backupAgeS: nil)).tag(true)
                Text(ShareSetupForm.sourceLabel(backupNow: false, estMinutes: nil, backupAgeS: plan?.sourceAgeS)).tag(false)
            }
            .pickerStyle(.radioGroup)
            Text("People (one seat each)").font(.headline)
            List(share.users.filter(\.selectable)) { user in
                Toggle(isOn: Binding(get: { form.picked.contains(user.name) },
                                     set: { if $0 { form.picked.insert(user.name) } else { form.picked.remove(user.name) } })) {
                    HStack {
                        Text(user.fullName)
                        ForEach(user.roles.prefix(4), id: \.self) { role in
                            let capable = user.codeCapableRoles.contains(role)
                            Text(capable ? "\(role) · \(SharePresentation.removedInCopy)" : role)
                                .font(.caption).padding(.horizontal, 5)
                                .background(capable ? Color.orange.opacity(0.25) : Color.secondary.opacity(0.15), in: Capsule())
                        }
                    }
                }
            }
            .frame(minHeight: 160)
            Toggle(SharePresentation.acknowledgement, isOn: $form.acknowledged)
            if let plan {
                Text(plan.dataClasses.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                Text(ShareSetupForm.needs(plan.sizeGB)).foregroundStyle(form.shortOnDisk ? .red : .secondary)
            }
            if let step { Label(ShareSetupSheet.stepText(step), systemImage: "hourglass") }
            HStack {
                Spacer()
                Button("Cancel", action: close).disabled(running)
                Button(refresh ? "Refresh copy" : "Set up sharing") { Task { await run() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!form.canRun || running)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
        .task { await share.loadUsers(site: site) }
        .task(id: form.picked) {
            guard !form.picked.isEmpty else { return }
            plan = await share.setupPlan(form.request(refresh: refresh))
            form.neededGB = plan?.sizeGB
            form.freeGB = ShareSetupSheet.freeGB()
        }
    }

    static func stepText(_ step: String) -> String {
        switch step {
        case "backup": "Backing up…"
        case "share_site": "Making the copy…"
        case "harden", "baseline": "Locking it down…"
        default: "Working…"
        }
    }

    static func freeGB() -> Double? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let bytes = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage else { return nil }
        return Double(bytes) / 1_073_741_824
    }

    private func run() async {
        running = true
        let ok = await share.setup(form.request(refresh: refresh)) { name in
            Task { @MainActor in step = name }
        }
        running = false
        if ok {
            ShareNotices.post(title: "Shared copy ready", body: "\(site) can now be shared on your network.", bench: share.bench)
            close()
        }
    }
}
