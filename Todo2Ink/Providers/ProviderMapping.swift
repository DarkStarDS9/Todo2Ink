import Foundation

/// Owns the persisted "provider's own id → wire `UInt16`" tables that let `itemId` and `listId` stay
/// stable across syncs, even though the device treats both as fully opaque
/// (`docs/companion-todo-list-design.md` §2 in the firmware repo).
///
/// Ids are assigned incrementally and never reused, per `CLAUDE.md`'s "Data model notes". 65536 ids
/// is not a real ceiling for a task list; this is bookkeeping, not a capacity problem.
///
/// **Keys are namespaced by provider, and that is the whole point of this type existing** rather
/// than the `ReminderMapping` it replaces. The wire's id space is shared by every provider, so
/// nothing may assume two backends' native id formats can't collide — EventKit identifiers and
/// Bring UUIDs are different enough that a collision is vanishingly unlikely *by luck*, and relying
/// on luck is exactly what a third provider would eventually break. The counters stay global
/// (a single `nextItemId` across all providers) because the wire only requires ids be unique, not
/// that they be organised per provider.
final class ProviderMapping {
    private struct Storage: Codable {
        var itemIdByKey: [String: UInt16] = [:]
        var nextItemId: UInt16 = 1
        var listIdByKey: [String: UInt16] = [:]
        var nextListId: UInt16 = 1
    }

    /// A composite `"<providerId>/<nativeId>"` key. Split at the *first* separator, never the last:
    /// provider ids are our own slugs and contain no `/`, but a backend's native id might.
    private static func key(_ provider: ProviderId, _ nativeId: String) -> String {
        "\(provider.rawValue)/\(nativeId)"
    }

    private static func split(_ key: String) -> (provider: ProviderId, nativeId: String)? {
        guard let slash = key.firstIndex(of: "/") else { return nil }
        return (
            ProviderId(rawValue: String(key[key.startIndex..<slash])),
            String(key[key.index(after: slash)...])
        )
    }

    private let defaults: UserDefaults

    /// Deliberately *not* `"ReminderMapping.v1"`. Old entries are un-namespaced and there is no way
    /// to tell by inspection which provider they belong to, so the upgrade is a clean reset: the old
    /// table is orphaned and every item is minted a fresh id on the next sync.
    ///
    /// That is safe, not merely tolerable, because `itemId` is phone-owned and opaque — the device
    /// keeps no notion of an item's identity beyond the document it is currently holding, and a
    /// push replaces that document wholesale. `currentRevision` already resets to 0 on every
    /// relaunch for the same reason.
    private let storageKey = "ProviderMapping.v1"

    private var storage: Storage
    private var nativeItemIdByItemId: [UInt16: (provider: ProviderId, nativeId: String)] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(Storage.self, from: data) {
            storage = decoded
        } else {
            storage = Storage()
        }
        for (key, itemId) in storage.itemIdByKey {
            nativeItemIdByItemId[itemId] = Self.split(key)
        }
    }

    /// The stable `itemId` for one provider's item, minting one on first sight. `nil` only if the
    /// `UInt16` space is exhausted — practically unreachable for a task list.
    func itemId(forProvider provider: ProviderId, nativeId: String) -> UInt16? {
        let key = Self.key(provider, nativeId)
        if let existing = storage.itemIdByKey[key] { return existing }
        guard storage.nextItemId != 0 else { return nil }
        let minted = storage.nextItemId
        storage.itemIdByKey[key] = minted
        nativeItemIdByItemId[minted] = (provider, nativeId)
        storage.nextItemId &+= 1
        persist()
        return minted
    }

    /// Which provider's item a device-reported `itemId` is, or `nil` if this table has never seen it
    /// (e.g. the item was deleted since the id was minted — the normal, non-error shape
    /// `TodoDocument.mergingDeviceDeviations` already expects).
    ///
    /// Returning the provider alongside the native id is what makes write-back routing a single
    /// dictionary lookup instead of asking every provider in turn "is this one yours?".
    func nativeItemId(forItemId itemId: UInt16) -> (provider: ProviderId, nativeId: String)? {
        nativeItemIdByItemId[itemId]
    }

    /// The stable `listId` for one provider's list, minting one on first sight.
    func listId(forProvider provider: ProviderId, nativeId: String) -> UInt16 {
        let key = Self.key(provider, nativeId)
        if let existing = storage.listIdByKey[key] { return existing }
        let minted = storage.nextListId
        storage.listIdByKey[key] = minted
        storage.nextListId &+= 1
        persist()
        return minted
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
