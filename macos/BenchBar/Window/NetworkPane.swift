import AppKit
import SwiftUI

/// "On your network": rooms this Mac joined, rooms nearby, and the join sheet.
/// Browsing runs only while the pane is visible, after the app's own explanation.
struct NetworkPane: View {
    @Bindable var store: GuestRoomStore
    var openSharing: () -> Void = {}
    @AppStorage("shareGuestExplained") private var explained = false

    var body: some View {
        Form {
            if !explained {
                Section {
                    Text(NetworkPanePresentation.explanation)
                    Button("Continue") {
                        explained = true
                        store.startBrowsing()
                    }
                }
            }
            if store.localNetworkDenied {
                Section {
                    Label(NetworkPanePresentation.localNetworkOff, systemImage: "wifi.exclamationmark")
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            if !store.saved.isEmpty {
                Section(NetworkPanePresentation.joinedSection) {
                    ForEach(store.saved) { room in
                        JoinedRoomRow(store: store, room: room)
                    }
                }
            }
            if explained {
                Section(NetworkPanePresentation.nearbySection) {
                    if store.nearby.isEmpty {
                        Text(NetworkPanePresentation.emptyText).foregroundStyle(.secondary)
                    }
                    ForEach(store.nearby) { room in
                        HStack {
                            Text(NetworkPanePresentation.nearbyRow(room))
                            Spacer()
                            Button("Join") { store.beginJoin(room) }
                                .disabled(room.display.needsUpdate)
                                .help(NetworkPanePresentation.joinDisabledReason(room) ?? "")
                        }
                    }
                }
            }
            Section {
                HStack {
                    Text(NetworkPanePresentation.shareYourOwn).foregroundStyle(.secondary)
                    Spacer()
                    Button("Sharing…", action: openSharing)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if explained { store.startBrowsing() }
            store.startHealthLoop()
        }
        .onDisappear { store.stopBrowsing() }
        .sheet(isPresented: Binding(get: { store.join != .none }, set: { if !$0 { store.cancelJoin() } })) {
            JoinSheet(store: store)
        }
    }
}

private struct JoinedRoomRow: View {
    let store: GuestRoomStore
    let room: SavedRoom

    var body: some View {
        let health = store.health[room.id] ?? .unknown
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(room.room) · \(room.host) · \(room.site)").font(.headline)
                Spacer()
                Button("Open") { Task { await store.open(room) } }
                    .disabled(!NetworkPanePresentation.canOpen(health))
                if NetworkPanePresentation.canOpen(health) {
                    Button("Change Seat") { Task { await store.chooseSeat(room) } }
                }
                Button(health == .identityChanged ? "Remove and Join Again" : "Forget") { Task { await store.forget(room) } }
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(NetworkPanePresentation.health(health, host: room.host, now: context.date))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct JoinSheet: View {
    @Bindable var store: GuestRoomStore
    /// The typed code lives only here and is cleared as it is sent (J12).
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(20)
        .frame(width: 380)
    }

    @ViewBuilder private var content: some View {
        switch store.join {
        case .none:
            EmptyView()
        case .enteringCode(let room):
            Text(NetworkPanePresentation.codePrompt(room)).font(.headline)
            TextField("Your name", text: $store.guestName)
            TextField("482 913", text: $code)
                .font(.system(.title2, design: .monospaced))
                .onSubmit { send(room) }
            buttons(primary: "Join", enabled: RoomCode.normalize(code) != nil) { send(room) }
        case .joining(let room):
            HStack {
                ProgressView().controlSize(.small)
                Text(NetworkPanePresentation.joining(room))
            }
        case .refused(let room, let refusal):
            Text(NetworkPanePresentation.refusal(refusal, host: room.display.label)).fixedSize(horizontal: false, vertical: true)
            buttons(primary: "Try Again", enabled: true) { store.join = .enteringCode(room) }
        case .pickingSeat(let room, let seats):
            seatPicker(room, seats, error: nil)
        case .seatRefused(let room, let seats, let error):
            seatPicker(room, seats, error: NetworkPanePresentation.seatRefusal(error, host: room.host))
        }
    }

    @ViewBuilder private func seatPicker(_ room: SavedRoom, _ seats: [RoomSeat], error: String?) -> some View {
        Text(NetworkPanePresentation.seatTitle).font(.headline)
        if let error { Text(error).foregroundStyle(.red) }
        ForEach(seats) { seat in
            let row = NetworkPanePresentation.seatRow(seat)
            Button {
                Task { await store.pick(seat: seat, in: room, seats: seats) }
            } label: {
                HStack {
                    Text(row.title)
                    Spacer()
                    Text(row.detail).foregroundStyle(.secondary)
                }
            }
            .disabled(seat.taken_by != nil)
        }
        HStack {
            Spacer()
            Button("Later") { store.join = .none }
        }
    }

    private func buttons(primary: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button("Cancel") { store.cancelJoin() }.keyboardShortcut(.cancelAction)
            Button(primary, action: action).keyboardShortcut(.defaultAction).disabled(!enabled)
        }
    }

    private func send(_ room: DiscoveredRoom) {
        let typed = code
        code = ""
        Task { await store.submit(code: typed, for: room) }
    }
}
