import Foundation

/// The one piece of app state — mirrors the role `PrintStudioModel` plays in Snap2Ink.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var transportState: TransportState = .idle
    @Published var lists: [ReminderList] = []
    @Published var selectedListIds: Set<String> = []

    private let transport: DisplayTransport
    private let reminders: RemindersService
    private let syncEngine: TodoSyncEngine

    init(transport: DisplayTransport, reminders: RemindersService) {
        self.transport = transport
        self.reminders = reminders
        self.syncEngine = TodoSyncEngine(transport: transport, reminders: reminders)

        transport.onStateChange = { [weak self] state in
            self?.transportState = state
            if state == .ready {
                self?.syncNowInBackground()
            }
        }
        transport.onListStateAvailable = { [weak self] revision, count in
            DebugLog.shared.log("list state available: revision \(revision), \(count) deviations")
            self?.syncEngine.markPullOwed()
        }
    }

    func connect() {
        transport.connect()
    }

    func disconnectForBackground() {
        transport.disconnect()
    }

    /// Requests Reminders access if needed, then loads the picker's list of calendars. Safe to call
    /// repeatedly (e.g. from `ListPickerView`'s `.task`) — `requestAccess()` just reports existing
    /// access on every call after the first.
    func loadLists() async {
        guard (try? await reminders.requestAccess()) == true else {
            lists = []
            return
        }
        lists = reminders.fetchLists()
    }

    func toggleListSelection(_ id: String) {
        if selectedListIds.contains(id) {
            selectedListIds.remove(id)
        } else {
            selectedListIds.insert(id)
        }
        syncEngine.selectedListIds = Array(selectedListIds)
        if transportState == .ready {
            syncNowInBackground()
        }
    }

    private func syncNowInBackground() {
        Task { [syncEngine] in
            await syncEngine.syncNow()
        }
    }
}
