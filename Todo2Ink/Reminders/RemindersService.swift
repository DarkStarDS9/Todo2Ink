import EventKit
import Foundation

/// One Reminders list, as far as the picker and the sync engine need to know about it.
struct ReminderList: Identifiable, Equatable {
    /// `EKCalendar.calendarIdentifier` — stable across launches, not across a full app
    /// reinstall/re-grant of Reminders access (EventKit's own guarantee, not this app's).
    let id: String
    let title: String
}

/// EventKit access, list/reminder enumeration, and completion write-back.
///
/// This is the seam `TodoSyncEngine` calls into to drive the pull → merge → push loop — see
/// `Todo2Ink/Sync/TodoSyncEngine.swift` and `CLAUDE.md`'s "Data model notes" for the itemId
/// mapping `ReminderMapping` owns. Nothing here talks to CompanionKit; that separation is
/// deliberate, so the Reminders half can be unit-tested (with a fake/in-memory `EKEventStore`
/// substitute, or against a real store on a Simulator/device where EventKit works) with no BLE
/// involved at all.
@MainActor
final class RemindersService {
    private let store = EKEventStore()

    /// Requests (or reports existing) access to Reminders. Must be called, and must succeed, before
    /// any other method here is meaningful.
    func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToReminders()
    }

    /// Every Reminders list, for the picker view.
    func fetchLists() -> [ReminderList] {
        store.calendars(for: .reminder).map { ReminderList(id: $0.calendarIdentifier, title: $0.title) }
    }

    /// Every reminder in the given lists, incomplete and complete alike — the sync engine decides
    /// what to do with `isCompleted`, this just reads.
    func fetchReminders(in listIds: [String]) async -> [EKReminder] {
        let calendars = store.calendars(for: .reminder).filter { listIds.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForReminders(in: calendars)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    /// Writes a completion state back to Reminders for the given reminder identifier
    /// (`EKReminder.calendarItemIdentifier`). Used by the sync engine after merging a device-side
    /// deviation.
    func setCompleted(_ completed: Bool, forReminderId reminderId: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: reminderId) as? EKReminder else {
            // The reminder was deleted locally since its itemId was minted — the normal, non-error
            // shape `TodoDocument.mergingDeviceDeviations` already expects.
            return
        }
        reminder.isCompleted = completed
        try store.save(reminder, commit: true)
    }
}
