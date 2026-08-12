import Foundation

/// The one piece of app state — mirrors the role `PrintStudioModel` plays in Snap2Ink.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var transportState: TransportState = .idle
    @Published var lists: [ReminderList] = []
    @Published var selectedListIds: Set<String> {
        didSet { persistSelectedListIds() }
    }
    @Published private(set) var syncStatus: SyncStatus = .idle

    private let transport: DisplayTransport
    private let reminders: RemindersService
    private let syncEngine: TodoSyncEngine
    private let defaults: UserDefaults
    private static let selectedListIdsDefaultsKey = "Todo2Ink.selectedListIds"

    init(transport: DisplayTransport, reminders: RemindersService, defaults: UserDefaults = .standard) {
        self.transport = transport
        self.reminders = reminders
        self.defaults = defaults
        self.syncEngine = TodoSyncEngine(transport: transport, reminders: reminders)

        let savedIds = defaults.stringArray(forKey: Self.selectedListIdsDefaultsKey) ?? []
        self.selectedListIds = Set(savedIds)
        self.syncEngine.selectedListIds = savedIds

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
        syncEngine.onStatusChange = { [weak self] status in
            self?.syncStatus = status
        }
    }

    private func persistSelectedListIds() {
        defaults.set(Array(selectedListIds), forKey: Self.selectedListIdsDefaultsKey)
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

    /// Manual sync, for the "Sync Now" button — a no-op unless the link is actually `.ready`, since
    /// that's the only state `TodoSyncEngine.syncNow()` does anything in anyway.
    func syncNow() {
        guard transportState == .ready else { return }
        syncNowInBackground()
    }

    private func syncNowInBackground() {
        Task { [syncEngine] in
            await syncEngine.syncNow()
        }
    }
}
