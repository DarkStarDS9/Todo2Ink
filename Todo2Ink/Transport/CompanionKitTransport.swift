import CompanionKit
import Foundation

/// The real transport: `DisplayTransport` implemented over CompanionKit's `CompanionClient`.
///
/// Thin on purpose. CompanionKit owns the handshake, token persistence, asset digests, session
/// filtering and framing; this type owns only the translation into the vocabulary the rest of the
/// app already speaks, and one policy decision the library leaves to the app — which discovered
/// device to connect to.
@MainActor
final class CompanionKitTransport: DisplayTransport {

    private(set) var state: TransportState = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((TransportState) -> Void)?
    var onListStateAvailable: ((UInt32, UInt16) -> Void)?

    private let underlyingClient: CompanionClient
    var client: CompanionClient? { underlyingClient }
    private var eventTask: Task<Void, Never>?

    init(client: CompanionClient) {
        self.underlyingClient = client
    }

    convenience init() {
        self.init(
            client: CompanionClient(
                identity: Todo2InkPeer.identity(),
                assets: Todo2InkAssetProvider(),
                log: { DebugLog.shared.log($0) }
            )
        )
    }

    func connect() {
        // `client.events` is a single-consumer AsyncStream meant to be iterated exactly once for
        // the client's whole lifetime — see Snap2Ink's `CompanionKitTransport` for the background/
        // foreground cycle this guards against. Started once, ever, never cancelled.
        if eventTask == nil {
            eventTask = Task { [weak self] in
                guard let self else { return }
                for await event in self.underlyingClient.events {
                    self.handle(event)
                }
            }
        }

        switch state {
        case .idle, .disconnected:
            DebugLog.shared.log("connect() from \(state) — scanning")
            state = .scanning
            underlyingClient.startScanning()
        default:
            DebugLog.shared.log("connect() from \(state) — re-acquiring screen")
            underlyingClient.acquireScreen()
        }
    }

    func disconnect() {
        DebugLog.shared.log("disconnect() from \(state)")
        underlyingClient.disconnect()
        state = .disconnected
    }

    // MARK: - Events

    private func handle(_ event: CompanionEvent) {
        DebugLog.shared.log("event: \(event), state was \(state)")
        switch event {
        case .bluetoothStateChanged(let isAvailable):
            if isAvailable {
                state = .scanning
                underlyingClient.startScanning()
            } else {
                state = .failed("Bluetooth is off.")
            }

        case .discovered(let device):
            // Policy the library deliberately leaves to the app: connect to the first companion
            // display found. A device picker is future work if a user ever pairs to more than one.
            state = .connecting
            underlyingClient.stopScanning()
            underlyingClient.connect(device)

        case .connected:
            break

        case .pairingPending:
            state = .awaitingPairingConfirmation

        case .pairingDenied(let reason):
            state = .pairingRefused(reason)

        case .gainedScreen:
            state = .ready

        case .sessionEstablished:
            // Nothing to do: the client is constructed with `acquireScreenOnConnect` left at its
            // default, so the handshake ends by asking for the screen on its own.
            break

        case .stateChanged:
            // A coarser view of transitions this type already reports individually
            // (`.gainedScreen`/`.lostScreen`/`.sessionEstablished`).
            break

        case .lostScreen(let reason):
            state = .backgrounded(reason)

        case .acquireDenied:
            state = .failed("The reader refused the screen.")

        case .listStateAvailable(let revision, let count):
            onListStateAvailable?(revision, count)

        case .disconnected:
            state = .disconnected

        case .failure(let error):
            state = .failed("\(error)")

        case .assetSynced, .renderStatus, .imageChunkAck, .fieldSeqGap, .buttonEvent:
            // Not relevant to Todo2Ink today — it pushes no image/title/body content and binds no
            // buttons (see `Todo2InkPeer.uiDeclaration`).
            break
        }
    }

    // MARK: - Diagnostics

    var diagnostics: [DiagnosticEntry] {
        guard let capabilities = underlyingClient.deviceCapabilities else {
            return [DiagnosticEntry(label: "Device", value: "not connected")]
        }

        return [
            DiagnosticEntry(label: "Protocol version", value: "\(capabilities.protocolVersion)"),
            DiagnosticEntry(label: "Device id", value: capabilities.deviceIdHex),
            DiagnosticEntry(
                label: "Screen pixels",
                value: "\(capabilities.screenPixelWidth) × \(capabilities.screenPixelHeight)"
            ),
            DiagnosticEntry(label: "Holds screen", value: underlyingClient.hasScreen ? "yes" : "no"),
        ]
    }
}
