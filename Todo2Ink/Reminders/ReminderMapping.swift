import CompanionKit
import EventKit
import Foundation

/// Owns the persisted `EKReminder.calendarItemIdentifier -> UInt16` table that lets a flat wire
/// `itemId` stay stable across syncs, even though the device treats it as fully opaque
/// (`docs/companion-todo-list-design.md` §2 in the firmware repo), plus the equivalent table for
/// `EKCalendar.calendarIdentifier -> UInt16` list ids `TodoList.listId` needs.
///
/// IDs are assigned incrementally and never reused, per `CLAUDE.md`'s "Data model notes". 65536 ids
/// is not a real ceiling for a task list; this is bookkeeping (persisted in `UserDefaults`), not a
/// capacity problem.
final class ReminderMapping {
    private struct Storage: Codable {
        var itemIdByReminderId: [String: UInt16] = [:]
        var nextItemId: UInt16 = 1
        var listIdByCalendarId: [String: UInt16] = [:]
        var nextListId: UInt16 = 1
    }

    private let defaults: UserDefaults
    private let storageKey = "ReminderMapping.v1"
    private var storage: Storage
    private var reminderIdByItemId: [UInt16: String] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(Storage.self, from: data) {
            storage = decoded
        } else {
            storage = Storage()
        }
        for (reminderId, itemId) in storage.itemIdByReminderId {
            reminderIdByItemId[itemId] = reminderId
        }
    }

    /// The stable `itemId` for a reminder, minting one on first sight. `nil` only if the id space
    /// (`UInt16`) is exhausted — practically unreachable for a task list.
    func itemId(forReminderId reminderId: String) -> UInt16? {
        if let existing = storage.itemIdByReminderId[reminderId] {
            return existing
        }
        guard storage.nextItemId != 0 else { return nil }
        let minted = storage.nextItemId
        storage.itemIdByReminderId[reminderId] = minted
        reminderIdByItemId[minted] = reminderId
        storage.nextItemId &+= 1
        persist()
        return minted
    }

    /// The reminder a device-reported `itemId` corresponds to, or `nil` if this table has never
    /// seen it (e.g. the reminder was deleted locally since the id was minted — the normal,
    /// non-error shape `TodoDocument.mergingDeviceDeviations` already expects).
    func reminderId(forItemId itemId: UInt16) -> String? {
        reminderIdByItemId[itemId]
    }

    /// The stable `listId` for a Reminders list, minting one on first sight.
    func listId(forCalendarId calendarId: String) -> UInt16 {
        if let existing = storage.listIdByCalendarId[calendarId] {
            return existing
        }
        let minted = storage.nextListId
        storage.listIdByCalendarId[calendarId] = minted
        storage.nextListId &+= 1
        persist()
        return minted
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

/// Maps Reminders lists onto CompanionKit's `TodoDocument` shape.
///
/// EventKit reminders are flat — no subtasks, no sections (both are private API) — so each
/// `EKCalendar` becomes one `TodoList` with a single ungrouped `TodoGroup` (empty label, matching
/// the wire format's own "empty label = ungrouped" convention). The group's `groupId` doesn't need
/// `ReminderMapping`-style stability: `TodoDeviations` key check-offs by `itemId` only, never by
/// group, so any constant works.
enum TodoDocumentBuilder {
    private static let ungroupedGroupId: UInt16 = 1

    static func build(
        lists: [ReminderList],
        remindersByListId: [String: [EKReminder]],
        mapping: ReminderMapping,
        revision: UInt32
    ) -> TodoDocument {
        let todoLists = lists.map { list -> TodoList in
            let items = (remindersByListId[list.id] ?? []).compactMap { reminder -> TodoItem? in
                guard let itemId = mapping.itemId(forReminderId: reminder.calendarItemIdentifier) else {
                    return nil
                }
                return TodoItem(itemId: itemId, text: reminder.title ?? "", checked: reminder.isCompleted)
            }
            let group = TodoGroup(groupId: ungroupedGroupId, items: items)
            return TodoList(listId: mapping.listId(forCalendarId: list.id), title: list.title, groups: [group])
        }
        return TodoDocument(revision: revision, lists: todoLists)
    }
}
