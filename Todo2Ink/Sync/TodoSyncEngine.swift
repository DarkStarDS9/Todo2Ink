import CompanionKit
import Foundation

/// Drives the pull → merge → push loop between Reminders and the reader.
///
/// **Stub.** The shape this will take, per `docs/companion-todo-list-design.md` §7 in the firmware
/// repo and CompanionKit's own doc comments:
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

    init(transport: DisplayTransport, reminders: RemindersService) {
        self.transport = transport
        self.reminders = reminders
    }

    /// Which Reminders lists to sync — set by `ListPickerView`, persisted by the caller.
    var selectedListIds: [String] = []

    func syncNow() async {
        // TODO: implement the loop described above.
    }
}
