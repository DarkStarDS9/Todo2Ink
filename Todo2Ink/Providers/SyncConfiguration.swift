import Foundation

/// What syncs, and in what order — the single thing `TodoSyncEngine` walks to assemble a document.
///
/// The reader has only one level of structure: a flat run of lists. So the two orderings here,
/// providers and each provider's selected lists, compose into exactly what the user sees on the
/// device — `providers[0]`'s lists first in their own order, then `providers[1]`'s, and so on. That
/// flattening is the whole reason both orderings are user-editable; see `flattened(using:)`.
struct SyncConfiguration: Codable, Equatable {
    struct ProviderEntry: Codable, Equatable {
        let providerId: ProviderId

        /// A disabled provider contributes nothing to the document but keeps its list selection and
        /// ordering, so toggling it back on doesn't cost the user their setup.
        var enabled: Bool

        /// Selected lists only, in reader order. A list the user hasn't picked simply isn't here —
        /// "never all lists by default" (`CLAUDE.md`) generalized from Reminders to every provider.
        var selectedListIds: [String]
    }

    var providers: [ProviderEntry]

    static let empty = SyncConfiguration(providers: [])

    subscript(providerId: ProviderId) -> ProviderEntry? {
        get { providers.first { $0.providerId == providerId } }
        set {
            guard let newValue else {
                providers.removeAll { $0.providerId == providerId }
                return
            }
            if let index = providers.firstIndex(where: { $0.providerId == providerId }) {
                providers[index] = newValue
            } else {
                providers.append(newValue)
            }
        }
    }

    /// Adds an entry for any provider not yet known, preserving the order of those that are.
    ///
    /// Newly-registered providers land at the end, disabled and empty: a provider appearing because
    /// the user updated the app should never start syncing on its own, and never reshuffle an order
    /// the user chose.
    mutating func register(_ providerIds: [ProviderId]) {
        for id in providerIds where self[id] == nil {
            providers.append(ProviderEntry(providerId: id, enabled: false, selectedListIds: []))
        }
    }

    /// The flat, ordered `(provider, listId)` run the device will show.
    ///
    /// Only enabled providers contribute. Selections are *not* pruned here against what each
    /// provider currently has — that reconciliation happens at sync time against a live
    /// `fetchLists()`, so a list that is merely temporarily unreachable keeps its place in the order
    /// rather than being silently dropped from the user's configuration.
    func flattened() -> [(provider: ProviderId, listId: String)] {
        providers
            .filter(\.enabled)
            .flatMap { entry in entry.selectedListIds.map { (entry.providerId, $0) } }
    }
}
