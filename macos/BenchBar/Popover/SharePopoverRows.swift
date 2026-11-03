import SwiftUI

/// One row per bench that is sharing: "Sharing on your network · n online ·
/// time left", with Stop. Absent when nothing is shared.
struct SharePopoverRows: View {
    let center: ShareCenter

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
            }
        }
    }
}
