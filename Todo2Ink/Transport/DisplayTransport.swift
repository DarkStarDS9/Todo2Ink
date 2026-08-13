import CompanionKit
import Foundation

/// One labelled fact about the link, for an in-app diagnostics readout.
///
/// Strings rather than typed fields on purpose: this exists to be *displayed*, nothing branches on
/// it, and a transport should be able to report whatever it knows without the seam growing a
/// property per capability byte.
struct DiagnosticEntry: Equatable, Identifiable {
    let label: String
    let value: String

    var id: String { label }
}

/// Everything the UI needs to know about the link, as one value.
///
/// Modelled as a single enum rather than a bag of booleans because these states are genuinely
/// exclusive and the UI is a state machine: "awaiting pairing" and "ready" want completely
/// different screens, and any combination of them is meaningless.
enum TransportState: Equatable {
    case idle
    case scanning
    case connecting
    /// HELLO sent, device is showing its confirmation prompt. The user has to walk over and press a
    /// button — the UI says so rather than spinning.
    case awaitingPairingConfirmation
    case pairingRefused(HelloDeniedReason)
    /// Connected, enrolled, and holding the foreground session. Ready to sync.
    case ready
    case backgrounded(BackgroundReason)
    case disconnected
    case failed(String)
}

/// The seam between the app and the Companion Display Protocol.
///
/// Nothing above this line knows about CoreBluetooth, GATT characteristics, or the session
/// handshake — that is `CompanionKitTransport`'s business. `client` is the sync loop's own narrow
/// seam, `TodoSyncClient`, rather than a `CompanionClient`: CompanionKit still owns the pagination
/// and the wire codec, but the two calls that decide whether a check-off survives need to be fakeable
/// from a test.
@MainActor
protocol DisplayTransport: AnyObject {
    var state: TransportState { get }
    var onStateChange: ((TransportState) -> Void)? { get set }
    /// Fires whenever the device reports it has a check-off diff waiting — the signal to schedule a
    /// pull, not to issue one immediately (`docs/companion-todo-list-design.md` §7 in the firmware
    /// repo covers why this is safe even mid-sync).
    var onListStateAvailable: ((_ revision: UInt32, _ count: UInt16) -> Void)? { get set }

    /// What the device has told us about itself, for the diagnostics readout.
    var diagnostics: [DiagnosticEntry] { get }

    /// The underlying client, once connected — `nil` before a device has been discovered.
    var client: (any TodoSyncClient)? { get }

    func connect()
    func disconnect()
}
