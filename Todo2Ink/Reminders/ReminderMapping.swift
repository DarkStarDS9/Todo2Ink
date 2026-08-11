import CompanionKit
import Foundation

/// Owns the persisted `EKReminder.calendarItemIdentifier -> UInt16` table that lets a flat wire
/// `itemId` stay stable across syncs, even though the device treats it as fully opaque
/// (`docs/companion-todo-list-design.md` §2 in the firmware repo).
///
/// **Stub.** IDs are assigned incrementally and never reused, per `CLAUDE.md`'s "Data model notes".
/// 65536 ids is not a real ceiling for a task list; this is bookkeeping (persist the table, e.g. in
/// `UserDefaults` or a small on-disk dictionary), not a capacity problem.
final class ReminderMapping {
    private var itemIdByReminderId: [String: UInt16] = [:]
    private var reminderIdByItemId: [UInt16: String] = [:]
    private var nextItemId: UInt16 = 1

    /// The stable `itemId` for a reminder, minting one on first sight.
    func itemId(forReminderId reminderId: String) -> UInt16? {
        // TODO: look up, or mint `nextItemId` and persist, returning nil only if the id space is
        // exhausted (practically unreachable for a task list).
        nil
    }

    /// The reminder a device-reported `itemId` corresponds to, or `nil` if this table has never
    /// seen it (e.g. the reminder was deleted locally since the id was minted — the normal,
    /// non-error shape `TodoDocument.mergingDeviceDeviations` already expects).
    func reminderId(forItemId itemId: UInt16) -> String? {
        reminderIdByItemId[itemId]
    }
}

/// Maps Reminders lists onto CompanionKit's `TodoDocument` shape.
///
/// EventKit reminders are flat — no subtasks, no sections (both are private API) — so each
/// `EKCalendar` becomes one `TodoList` with a single ungrouped `TodoGroup` (empty label, matching
/// the wire format's own "empty label = ungrouped" convention). `listId`/`groupId` need the same
/// kind of stable-id bookkeeping `ReminderMapping` gives items; left as a TODO here rather than
/// duplicating that logic before the sync engine exists to exercise it.
enum ReminderMapping_TodoDocument {
    // TODO: build(lists: [ReminderList], reminders: [String: [EKReminder]], mapping: ReminderMapping,
    //             revision: UInt32) -> TodoDocument
}
