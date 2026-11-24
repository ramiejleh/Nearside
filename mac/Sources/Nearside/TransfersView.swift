import NearsideCore
import NearsideMac
import SwiftUI

/// The few most recent file transfers, above the history list.
struct TransfersView: View {
    let engine: SyncEngine

    var body: some View {
        VStack(spacing: 4) {
            ForEach(engine.transfers.prefix(3)) { transfer in
                TransferRow(transfer: transfer, phoneName: engine.phoneName) {
                    withAnimation(.easeOut(duration: 0.2)) { engine.dismissTransfer(transfer.id) }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }
}

private struct TransferRow: View {
    let transfer: SyncEngine.Transfer
    let phoneName: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.direction == .toPhone ? "arrow.up.doc" : "arrow.down.doc")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(transfer.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(isFailed ? .red : .secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder private var trailing: some View {
        switch transfer.status {
        case .inProgress:
            ProgressView().controlSize(.small)
        case .done(let url):
            HStack(spacing: 2) {
                if let url {
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11.5, weight: .medium))
                }
                dismissButton
            }
        case .failed:
            dismissButton
        }
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Hide")
    }

    private var tint: Color { transfer.direction == .toPhone ? .blue : .green }

    private var isFailed: Bool {
        if case .failed = transfer.status { true } else { false }
    }

    private var statusText: String {
        switch (transfer.status, transfer.direction) {
        case (.inProgress, .toPhone): "Sending to your \(phoneName)…"
        case (.inProgress, .toMac): "Receiving from your \(phoneName)…"
        case (.done, .toPhone): "Sent · in Download/Nearside on the phone"
        case (.done, .toMac): "Saved to Downloads"
        case (.failed(let message), _): message
        }
    }
}
