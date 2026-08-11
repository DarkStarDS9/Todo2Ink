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
/// **Stub.** This is the seam `TodoSyncEngine` will call into once the sync loop is implemented —
/// see `Todo2Ink/Sync/TodoSyncEngine.swift` and `CLAUDE.md`'s "Data model notes" for the itemId
/// mapping this will need to own. Nothing here talks to CompanionKit; that separation is
/// deliberate, so the Reminders half can be unit-tested (with a fake/in-memory `EKEventStore`
/// substitute, or against a real store on a Simulator/device where EventKit works) with no BLE
/// involved at all.
@MainActor
final class RemindersService {
    private let store = EKEventStore()

    /// Requests (or reports existing) access to Reminders. Must be called, and must succeed, before
    /// any other method here is meaningful.
    func requestAccess() async throws -> Bool {
        // TODO: EKEventStore.requestFullAccessToReminders(completion:) via a checked continuation,
        // or the async variant once the minimum iOS version guarantees it's available.
        false
    }

    /// Every Reminders list, for the picker view.
    func fetchLists() -> [ReminderList] {
        // TODO: store.calendars(for: .reminder).map { ReminderList(id: $0.calendarIdentifier, title: $0.title) }
        []
    }

    /// Every reminder in the given lists, incomplete and complete alike — the sync engine decides
    /// what to do with `isCompleted`, this just reads.
    func fetchReminders(in listIds: [String]) async -> [EKReminder] {
        // TODO: store.predicateForReminders(in: calendars) + store.fetchReminders(matching:)
        []
    }

    /// Writes a completion state back to Reminders for the given reminder identifier
    /// (`EKReminder.calendarItemIdentifier`). Used by the sync engine after merging a device-side
    /// deviation.
    func setCompleted(_ completed: Bool, forReminderId reminderId: String) throws {
        // TODO: fetch by calendarItemIdentifier, set isCompleted, store.save(_:commit:)
    }
}
