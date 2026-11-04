import SwiftUI

/// "Rooms nearby (N open)", which opens On your network. Shown only after the pane's Local
/// Network explanation, so the popover never brings up the macOS prompt.
struct NearbyRoomsPopoverRow: View {
    let guest: GuestRoomStore
    let open: () -> Void
    @AppStorage(NetworkPanePresentation.explainedKey) private var explained = false

    var body: some View {
        if explained {
            Button(NetworkPanePresentation.popoverNearby(open: guest.openNearbyCount), systemImage: "wifi", action: open)
                .buttonStyle(.borderless)
        }
    }
}

/// One row per bench that is sharing: "Sharing on your network · n online ·
/// time left", with Stop. Absent when nothing is shared.
struct SharePopoverRows: View {
    let center: ShareCenter

    /// The popover offers "Share with people nearby" while the bench has no share set up or running.
    @MainActor static func offersSetup(center: ShareCenter, bench: String) -> Bool {
        guard center.showsTab(for: bench) else { return false }
        guard let status = center.store(for: bench)?.status else { return true }
        return status.state != .on && status.state != .starting && status.copy == nil
    }

    var body: some View {
        ForEach(center.sharingStores, id: \.bench) { share in
            if let status = share.status {
                HStack(spacing: 8) {
                    Circle().fill(HostAmbient.icon([status]) == .attention ? Color.orange : Color.accentColor)
                        .frame(width: 7, height: 7)
                    Text(SharePresentation.indicator(status)).font(.callout).lineLimit(1)
                    Spacer()
                    Button(share.inviteCopied ? "Copied" : SharePresentation.copyInvite) {
                        Task { await share.copyInvite(write: ShareClipboard.copy) }
                    }
                    .help(share.inviteCopied ? SharePresentation.inviteCopied : SharePresentation.copyInviteHelp)
                    .controlSize(.small)
                    .disabled(share.busy != nil)
                    Button("Stop") {
                        guard ShareConfirm.ask(SharePresentation.stopConfirm(online: status.devicesOnline), button: "Stop") else { return }
                        Task { await share.stop() }
                    }
                    .controlSize(.small)
                    .disabled(share.busy != nil)
                }
                if let error = share.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
        }
    }
}
