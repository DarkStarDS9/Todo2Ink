import SwiftUI

/// Pairing/connection status — same role as Snap2Ink's connection UI, reused via the shared
/// `DisplayTransport`/`TransportState` seam rather than reimplemented.
struct PairingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            statusText
            Button("Connect") { model.connect() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .task { model.connect() }
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
}
