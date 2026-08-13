import SwiftUI

/// One pinned line at the top saying what the reader is doing, and — once the link is up — when the
/// lists last reached it. Same role and shape as Snap2Ink's status bar, reused via the shared
/// `DisplayTransport`/`TransportState` seam rather than reimplemented.
///
/// It is a single row on purpose. Two of its states — "confirm on your reader" and "screen lost" —
/// are things the user must act on somewhere other than this phone, and those are what earn the
/// permanent space; everything else collapses into a dot and a few words so the list below keeps
/// the screen.
struct LinkStatusBar: View {
    @ObservedObject var model: AppModel

    @State private var showsLabelEditor = false
    @State private var showsDebugLog = false
    @State private var labelDraft = ""

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(message)
                .font(.footnote)
                .foregroundStyle(messageIsError ? Color.red : .secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            // The primary action (connect/sync) sits closer to the text it explains; renaming is
            // secondary and stays outermost, by the edge of the thumb's reach. The gap between the
            // two is a fixed amount, not the HStack's shared spacing, so an errant tap can't
            // clip both.
            trailingAction
            renameButton
                .padding(.leading, 18)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        // Contains the whole bar, including the gaps, so the gesture is findable without hunting
        // for the text.
        .contentShape(.rect)
        // Long-press for the debug log, in every build configuration, and renaming moved to the
        // button above to make room for it — same arrangement as Snap2Ink. The gesture goes to the
        // log rather than to the rename because renaming is a thing you do once and can hunt for,
        // whereas the log is needed at the moment something has already gone wrong.
        .onLongPressGesture { showsDebugLog = true }
        .sheet(isPresented: $showsDebugLog) {
            DebugLogView()
        }
        // Distinguishes this install of Todo2Ink from another one paired to the same reader — e.g.
        // two people sharing one reader — in the device's tile picker. Only takes effect on the
        // next launch: `Todo2InkPeer.identity()` is read once when the app starts, and
        // `CompanionClient` holds it for its whole lifetime.
        .alert("Name This Phone", isPresented: $showsLabelEditor) {
            TextField("e.g. Alex's iPhone", text: $labelDraft)
            Button("Save") { Todo2InkPeer.setUserLabel(labelDraft) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shown on the reader so two people pairing the same reader can tell their lists apart. Takes effect next time you open Todo2Ink.")
        }
    }

    /// The connection state, except once the link is `.ready` — at which point "Connected" is the
    /// least interesting true thing on screen and the sync state takes the line instead. The dot
    /// still carries the connection.
    private var message: String {
        if model.transportState == .ready {
            switch model.syncStatus {
            case .idle: return "Connected — not synced yet"
            case .syncing: return "Syncing…"
            case .succeeded(let at):
                return "Synced \(at.formatted(date: .omitted, time: .shortened))"
            case .failed(_, let reason): return "Sync failed: \(reason)"
            }
        }
        switch model.transportState {
        case .idle: return "Not connected"
        case .scanning: return "Scanning…"
        case .connecting: return "Connecting…"
        case .awaitingPairingConfirmation: return "Confirm pairing on the reader"
        case .pairingRefused: return "Pairing was refused"
        case .ready: return "Connected"
        case .backgrounded: return "Screen lost — reconnecting"
        case .disconnected: return "Disconnected"
        case .failed(let message): return "Error: \(message)"
        }
    }

    private var messageIsError: Bool {
        if model.transportState == .ready, case .failed = model.syncStatus { return true }
        switch model.transportState {
        case .failed, .pairingRefused: return true
        default: return false
        }
    }

    private var tint: Color {
        switch model.transportState {
        case .ready: return .green
        case .awaitingPairingConfirmation: return .yellow
        case .pairingRefused, .failed, .disconnected, .backgrounded: return .red
        case .idle, .scanning, .connecting: return .gray
        }
    }

    private var renameButton: some View {
        Button {
            labelDraft = Todo2InkPeer.userLabel()
            showsLabelEditor = true
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.footnote)
                .padding(8)
                .contentShape(.rect)
        }
        .accessibilityLabel("Name This Phone")
    }

    /// At most one button, because the bar only ever has one useful next move: connect when there
    /// is no link, sync when there is. While a scan or pairing prompt is in flight there is nothing
    /// to offer — a second "Connect" tap reads as "why is this still here?".
    @ViewBuilder
    private var trailingAction: some View {
        switch model.transportState {
        case .idle, .disconnected, .failed, .pairingRefused, .backgrounded:
            Button("Connect") { model.connect() }
                .font(.footnote.weight(.medium))
        case .ready:
            if model.syncStatus == .syncing {
                ProgressView().controlSize(.small)
            } else {
                Button("Sync Now") { model.syncNow() }
                    .font(.footnote.weight(.medium))
            }
        case .scanning, .connecting, .awaitingPairingConfirmation:
            ProgressView().controlSize(.small)
        }
    }
}
