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
        }
        transport.onListStateAvailable = { [weak self] revision, count in
            DebugLog.shared.log("list state available: revision \(revision), \(count) deviations")
            // TODO: schedule a pull once TodoSyncEngine's loop is implemented.
        }
    }

    func connect() {
        transport.connect()
    }

    func disconnectForBackground() {
        transport.disconnect()
    }

    func loadLists() {
        lists = reminders.fetchLists()
    }

    func toggleListSelection(_ id: String) {
        if selectedListIds.contains(id) {
            selectedListIds.remove(id)
        } else {
            selectedListIds.insert(id)
        }
        syncEngine.selectedListIds = Array(selectedListIds)
    }
}
