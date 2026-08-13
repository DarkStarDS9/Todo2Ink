import Foundation

/// The one piece of app state — mirrors the role `PrintStudioModel` plays in Snap2Ink.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var transportState: TransportState = .idle
    @Published private(set) var syncStatus: SyncStatus = .idle

    /// What syncs and in what order. Every mutation goes through the helpers below rather than
    /// through this property directly, so persistence and re-sync stay in one place.
    @Published private(set) var configuration: SyncConfiguration {
        didSet {
            syncEngine.configuration = configuration
            persistConfiguration()
        }
    }

    /// Each provider's lists as last fetched, for the pickers to draw. Not persisted: it is a cache
    /// of someone else's truth, and a stale list title is worse than a moment's empty screen.
    @Published private(set) var listsByProvider: [ProviderId: [ProviderList]] = [:]

    /// Mirrors each provider's `authState` into something `@Published`. The providers are plain
    /// classes rather than observable objects on purpose — `TodoProvider` is a sync-layer protocol
    /// and shouldn't drag SwiftUI into it — so `AppModel` republishes on their behalf.
    @Published private(set) var authStates: [ProviderId: ProviderAuthState] = [:]

    let providers: [any TodoProvider]

    private let transport: DisplayTransport
    private let providersById: [ProviderId: any TodoProvider]
    private let syncEngine: TodoSyncEngine
    private let defaults: UserDefaults
    private static let configurationDefaultsKey = "Todo2Ink.syncConfiguration.v1"

    init(
        transport: DisplayTransport,
        providers: [any TodoProvider],
        defaults: UserDefaults = .standard
    ) {
        self.transport = transport
        self.providers = providers
        self.providersById = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.defaults = defaults
        self.syncEngine = TodoSyncEngine(transport: transport, providers: providers)

        // A provider added by an app update joins the configuration disabled and empty, at the end
        // of whatever order the user already chose — see `SyncConfiguration.register`. On a first
        // run there is no such order to respect, so `firstRunConfiguration` seeds one instead.
        var loaded = Self.loadConfiguration(from: defaults)
            ?? Self.firstRunConfiguration(providers: providers, defaults: defaults)
        loaded.register(providers.map(\.id))
        self.configuration = loaded
        self.syncEngine.configuration = loaded
        self.authStates = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.authState) })

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

    // MARK: - Providers

    func provider(_ id: ProviderId) -> (any TodoProvider)? {
        providersById[id]
    }

    /// Providers in the user's chosen order. Drives both the provider screen and the order in which
    /// their lists reach the device — those are deliberately the same order, so what the user drags
    /// is what the reader shows.
    var orderedProviders: [any TodoProvider] {
        configuration.providers.compactMap { providersById[$0.providerId] }
    }

    func isEnabled(_ id: ProviderId) -> Bool {
        configuration[id]?.enabled ?? false
    }

    /// Enabling a provider asks for its access if it doesn't have it yet — the toggle is the only
    /// place the user expresses "I want this", so it is the right place to prompt.
    func setEnabled(_ enabled: Bool, for id: ProviderId) {
        guard var entry = configuration[id] else { return }
        entry.enabled = enabled
        configuration[id] = entry
        if enabled {
            Task { await requestAccessAndLoadLists(for: id) }
        } else {
            syncNowIfReady()
        }
    }

    func moveProviders(fromOffsets source: IndexSet, toOffset destination: Int) {
        configuration.providers.move(fromOffsets: source, toOffset: destination)
        syncNowIfReady()
    }

    // MARK: - Lists

    func lists(for id: ProviderId) -> [ProviderList] {
        listsByProvider[id] ?? []
    }

    /// The lists this provider syncs, in reader order. Selections whose list has vanished from the
    /// provider are hidden from the UI but kept in the configuration — see
    /// `SyncConfiguration.flattened()` for why they aren't pruned.
    func selectedLists(for id: ProviderId) -> [ProviderList] {
        let available = Dictionary(lists(for: id).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return (configuration[id]?.selectedListIds ?? []).compactMap { available[$0] }
    }

    func availableLists(for id: ProviderId) -> [ProviderList] {
        let selected = Set(configuration[id]?.selectedListIds ?? [])
        return lists(for: id).filter { !selected.contains($0.id) }
    }

    func isSelected(_ listId: String, for id: ProviderId) -> Bool {
        configuration[id]?.selectedListIds.contains(listId) ?? false
    }

    /// Newly-selected lists append to the end rather than sorting into place — the order is the
    /// user's, and the app has no business guessing where a new list belongs in it.
    func toggleListSelection(_ listId: String, for id: ProviderId) {
        guard var entry = configuration[id] else { return }
        if let index = entry.selectedListIds.firstIndex(of: listId) {
            entry.selectedListIds.remove(at: index)
        } else {
            entry.selectedListIds.append(listId)
        }
        configuration[id] = entry
        syncNowIfReady()
    }

    func moveLists(for id: ProviderId, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard var entry = configuration[id] else { return }
        entry.selectedListIds.move(fromOffsets: source, toOffset: destination)
        configuration[id] = entry
        syncNowIfReady()
    }

    /// The flat run of lists the reader will show, top to bottom — the device has no notion of
    /// which provider a list came from, so this is the only place the two orderings are visible as
    /// the single thing the user is actually arranging.
    var readerOrder: [(provider: String, list: String)] {
        configuration.flattened().compactMap { entry in
            guard let provider = providersById[entry.provider],
                  let list = lists(for: entry.provider).first(where: { $0.id == entry.listId })
            else { return nil }
            return (provider.displayName, list.title)
        }
    }

    var exceedsListLimit: Bool {
        configuration.flattened().count > TodoDocumentBuilder.maxLists
    }

    // MARK: - Loading

    /// Requests access if needed, then refreshes the provider's lists. Safe to call repeatedly (e.g.
    /// from a view's `.task`) — providers report existing access rather than re-prompting.
    func requestAccessAndLoadLists(for id: ProviderId) async {
        guard let provider = providersById[id] else { return }
        let granted = (try? await provider.requestAccess()) ?? false
        authStates[id] = provider.authState
        guard granted else {
            listsByProvider[id] = []
            return
        }
        listsByProvider[id] = (try? await provider.fetchLists()) ?? []
        syncNowIfReady()
    }

    /// Refreshes every enabled provider's lists, for the top-level screen's `.task`.
    func loadAllLists() async {
        for entry in configuration.providers where entry.enabled {
            await requestAccessAndLoadLists(for: entry.providerId)
        }
    }

    // MARK: - Link and sync

    func connect() {
        transport.connect()
    }

    func disconnectForBackground() {
        transport.disconnect()
    }

    /// Manual sync, for the "Sync Now" button — a no-op unless the link is actually `.ready`, since
    /// that's the only state `TodoSyncEngine.syncNow()` does anything in anyway.
    func syncNow() {
        syncNowIfReady()
    }

    private func syncNowIfReady() {
        guard transportState == .ready else { return }
        syncNowInBackground()
    }

    private func syncNowInBackground() {
        Task { [syncEngine] in
            await syncEngine.syncNow()
        }
    }

    // MARK: - Persistence

    /// `nil` when nothing has ever been stored — distinct from a stored configuration in which the
    /// user has turned everything off, which must be left exactly as they left it.
    private static func loadConfiguration(from defaults: UserDefaults) -> SyncConfiguration? {
        guard let data = defaults.data(forKey: configurationDefaultsKey),
              let decoded = try? JSONDecoder().decode(SyncConfiguration.self, from: data)
        else { return nil }
        return decoded
    }

    /// Key written by the single-provider versions of this app, before `SyncConfiguration` existed.
    private static let legacySelectedListIdsKey = "Todo2Ink.selectedListIds"

    /// What a brand-new install starts from.
    ///
    /// The first provider is enabled, so a first run still walks straight into the Reminders
    /// permission prompt and a list to pick from rather than an "Off" row the user has to discover
    /// they must switch on. Providers that arrive *later*, via an app update, deliberately do not
    /// get this treatment — `SyncConfiguration.register` leaves those off.
    ///
    /// An install upgrading from before `SyncConfiguration` existed carries its Reminders selection
    /// across. The old key stored a `Set`, so there is no original order to preserve; sorting is
    /// only for a deterministic starting point the user can then drag into the order they want.
    private static func firstRunConfiguration(
        providers: [any TodoProvider],
        defaults: UserDefaults
    ) -> SyncConfiguration {
        let legacyListIds = (defaults.stringArray(forKey: legacySelectedListIdsKey) ?? []).sorted()
        var configuration = SyncConfiguration.empty
        if let first = providers.first {
            configuration.providers = [
                .init(
                    providerId: first.id,
                    enabled: true,
                    selectedListIds: first.id == .reminders ? legacyListIds : []
                )
            ]
        }
        return configuration
    }

    private func persistConfiguration() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: Self.configurationDefaultsKey)
    }
}
