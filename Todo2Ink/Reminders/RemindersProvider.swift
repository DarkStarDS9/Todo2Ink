import EventKit
import Foundation

/// Apple Reminders as a `TodoProvider`.
///
/// A thin adapter over `RemindersService` rather than a conformance on the service itself, for the
/// same reason `CompanionKitTransport` wraps `CompanionClient` instead of extending it: the service
/// stays a plain EventKit wrapper that can be unit-tested and read without knowing what a provider
/// is, and everything the abstraction demands — async-ness, an auth state, a `[String: [Item]]`
/// shape — is bolted on here where it is obviously translation and not EventKit behaviour.
@MainActor
final class RemindersProvider: TodoProvider {
    let id = ProviderId.reminders
    let displayName = "Apple Reminders"

    private let service: RemindersService
    private(set) var authState: ProviderAuthState = .notConfigured

    init(service: RemindersService) {
        self.service = service
    }

    var statusDescription: String? {
        switch authState {
        case .notConfigured: return "Tap to allow access to Reminders"
        case .authorized: return nil
        case .failed(let message): return message
        }
    }

    func requestAccess() async throws -> Bool {
        do {
            let granted = try await service.requestAccess()
            authState = granted ? .authorized : .failed("Reminders access was denied. Enable it in Settings.")
            return granted
        } catch {
            authState = .failed("\(error)")
            throw error
        }
    }

    func fetchLists() async throws -> [ProviderList] {
        service.fetchLists().map { ProviderList(id: $0.id, title: $0.title) }
    }

    func fetchItems(listIds: [String]) async throws -> [String: [ProviderItem]] {
        let reminders = await service.fetchReminders(in: listIds)
        return Dictionary(grouping: reminders) { $0.calendar.calendarIdentifier }
            .mapValues { group in
                group.map {
                    ProviderItem(
                        id: $0.calendarItemIdentifier,
                        text: $0.title ?? "",
                        checked: $0.isCompleted
                    )
                }
            }
    }

    func setCompleted(_ completed: Bool, forItemId itemId: String) async throws {
        try service.setCompleted(completed, forReminderId: itemId)
    }
}
