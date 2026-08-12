import CompanionKit
import EventKit
import Foundation

/// What `syncNow()` is doing, for the UI to show — see `PairingView`'s sync readout.
enum SyncStatus: Equatable {
    case idle
    case syncing
    case succeeded(at: Date)
    case failed(at: Date, message: String)
}

/// Drives the pull → merge → push loop between Reminders and the reader.
///
/// The loop, per `docs/companion-todo-list-design.md` §7 in the firmware repo and CompanionKit's own
/// doc comments:
///
/// 1. On `.ready` (screen acquired): build a `TodoDocument` from the user's selected Reminders
///    lists via `ReminderMapping`, and `client.pushTodoDocument(_:)`.
/// 2. On `onListStateAvailable` (fires as soon as `HELLO_OK`, before the screen is held — see
///    `CompanionEvent.listStateAvailable`'s doc comment): remember that a pull is owed; do not pull
///    yet.
/// 3. Once the screen is held: `client.pullListState()` for the accumulated `TodoDeviations`, then
///    `document.mergingDeviceDeviations(_:newRevision:)` to fold them into a new document revision.
/// 4. Write each changed item's completion back to Reminders via `RemindersService.setCompleted`,
///    resolving each deviation's `itemId` back to a reminder through `ReminderMapping`.
/// 5. `client.pushTodoDocument(_:)` the merged document at the new revision, which also clears the
///    device's diff.
///
/// Kept as its own type, not folded into `CompanionKitTransport`, because it is sync policy
/// (Reminders <-> TodoDocument), not link plumbing — the same separation `Snap2Ink`'s
/// `PrintStudioModel` keeps from its own transport.
@MainActor
final class TodoSyncEngine {
    private let transport: DisplayTransport
    private let reminders: RemindersService
    private let mapping = ReminderMapping()

    /// Mirrors `DisplayTransport.onStateChange`'s shape — `AppModel` observes this the same way it
    /// observes transport state, so the UI can show "Syncing…"/"Synced 2:45 PM"/an error inline.
    var onStatusChange: ((SyncStatus) -> Void)?

    init(transport: DisplayTransport, reminders: RemindersService) {
        self.transport = transport
        self.reminders = reminders
    }

    /// Which Reminders lists to sync — set by `ListPickerView`, persisted by the caller.
    var selectedListIds: [String] = []

    /// The document revision last pushed. Starts at 0, matching a device that has never seen this
    /// peer's document — a push always replaces the whole document regardless of revision, so this
    /// resetting on relaunch is harmless (see `docs/companion-todo-list-design.md` §6/§7).
    private var currentRevision: UInt32 = 0

    /// Set by `AppModel` when `CompanionEvent.listStateAvailable` fires. Per §7, that can arrive
    /// before the screen is held — this only remembers a pull is owed, `syncNow()` decides when to
    /// act on it.
    private var pullOwed = false

    func markPullOwed() {
        pullOwed = true
    }

    func syncNow() async {
        guard let client = transport.client, transport.state == .ready else { return }

        let lists = reminders.fetchLists().filter { selectedListIds.contains($0.id) }
        guard !lists.isEmpty else { return }

        onStatusChange?(.syncing)

        let allReminders = await reminders.fetchReminders(in: lists.map(\.id))
        let remindersByListId = Dictionary(grouping: allReminders) { $0.calendar.calendarIdentifier }

        do {
            var document = TodoDocumentBuilder.build(
                lists: lists,
                remindersByListId: remindersByListId,
                mapping: mapping,
                revision: currentRevision
            )

            if pullOwed {
                let deviations = try await client.pullListState()
                document = try document.mergingDeviceDeviations(
                    deviations,
                    newRevision: currentRevision + 1,
                    evenIfRevisionMismatched: true
                )
                for (itemId, checked) in deviations.checkedByItemId {
                    guard let reminderId = mapping.reminderId(forItemId: itemId) else { continue }
                    try? reminders.setCompleted(checked, forReminderId: reminderId)
                }
                pullOwed = false
            }

            try await client.pushTodoDocument(document)
            currentRevision = document.revision
            onStatusChange?(.succeeded(at: Date()))
        } catch {
            DebugLog.shared.log("Todo sync failed: \(error)")
            onStatusChange?(.failed(at: Date(), message: "\(error)"))
        }
    }
}
