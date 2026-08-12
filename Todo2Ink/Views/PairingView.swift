import SwiftUI

/// Pairing/connection status — same role as Snap2Ink's connection UI, reused via the shared
/// `DisplayTransport`/`TransportState` seam rather than reimplemented.
struct PairingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            statusText
            // Only shown when tapping it would actually do something: `.connect()` starts a scan
            // from idle/disconnected/failed states, or re-acquires the screen from `.backgrounded`.
            // While a connection attempt or pairing prompt is already in flight, or once the link is
            // `.ready`, a second tap has nothing to add and just reads as "why is this still here?".
            if showsConnectButton {
                Button("Connect") { model.connect() }
                    .buttonStyle(.borderedProminent)
            }
            if model.transportState == .ready {
                syncStatusView
            }
        }
        .padding()
        .task { model.connect() }
    }

    private var showsConnectButton: Bool {
        switch model.transportState {
        case .idle, .disconnected, .failed, .pairingRefused, .backgrounded:
            return true
        case .scanning, .connecting, .awaitingPairingConfirmation, .ready:
            return false
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch model.transportState {
        case .idle:
            Text("Not connected")
        case .scanning:
            Text("Scanning…")
        case .connecting:
            Text("Connecting…")
        case .awaitingPairingConfirmation:
            Text("Confirm pairing on the reader")
        case .pairingRefused:
            Text("Pairing was refused")
        case .ready:
            Text("Connected")
        case .backgrounded:
            Text("Screen lost — reconnecting")
        case .disconnected:
            Text("Disconnected")
        case .failed(let message):
            Text("Error: \(message)")
        }
    }

    @ViewBuilder
    private var syncStatusView: some View {
        HStack(spacing: 8) {
            switch model.syncStatus {
            case .idle:
                Text("Not synced yet").foregroundStyle(.secondary)
            case .syncing:
                ProgressView().controlSize(.small)
                Text("Syncing…").foregroundStyle(.secondary)
            case .succeeded(let at):
                Text("Synced \(at.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.secondary)
            case .failed(let at, let message):
                Text("Sync failed \(at.formatted(date: .omitted, time: .shortened)): \(message)")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("Sync Now") { model.syncNow() }
                .disabled(model.syncStatus == .syncing)
        }
        .font(.footnote)
    }
}
