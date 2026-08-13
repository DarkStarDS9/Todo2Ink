import Foundation

/// One locale's cached catalogue fetch: the raw response body Bring! returned, and when it was
/// fetched.
///
/// The raw body is what's stored, not the parsed `LocaleCatalog` — `BringCatalogClient` already owns
/// a JSON decode path for `BringCatalogResponse`, so caching the bytes reuses it as-is on every read
/// (disk or network) instead of needing a second, hand-written `Codable` conformance for a type that
/// only exists to be flattened lookups. It also means a cached file can be read by eye if a locale's
/// data ever looks wrong in the field.
///
/// `body == nil` is itself the cached fact "this locale 404s" — Bring! publishes no catalogue for it
/// — which must survive the round trip exactly like a successful fetch does. Without that, `en-DE`
/// (or any other unsupported locale) would be the one case that keeps costing a wasted request every
/// launch, forever, which is exactly the waste this cache exists to remove.
struct BringCatalogCacheEntry {
    let body: Data?
    let fetchedAt: Date
}

/// Where a locale's article catalogue is cached between launches.
///
/// A protocol for the same reason `BringCredentialStore` is one: tests substitute an in-memory fake,
/// so TTL expiry, eviction and corruption can all be driven directly instead of through the real
/// Caches directory and the wall clock.
protocol BringCatalogStore {
    func load(locale: String) -> BringCatalogCacheEntry?
    func save(_ entry: BringCatalogCacheEntry, locale: String)
    func clear()
}

/// The real store: one JSON file per locale under Caches, not Application Support — this is
/// regenerable reference data, and the OS should be free to evict any of it under disk pressure. One
/// file per locale rather than a shared index means an eviction (or a single corrupted file) costs
/// one extra fetch for that locale, never the whole cache.
final class DiskBringCatalogStore: BringCatalogStore {
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    private static func defaultDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            // No sandbox has ever failed to hand back a Caches URL in practice, but a nil here must
            // still degrade to "no disk cache" rather than crash — `tmp` is at least on-device and
            // gets the memory-only behaviour this whole type already has to tolerate anyway.
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("BringCatalog", isDirectory: true)
    }

    private struct StoredEntry: Codable {
        let body: Data?
        let fetchedAt: Date
    }

    private func url(for locale: String) -> URL {
        // Locale strings are Bring!'s own (`de-DE`, `en-US`, …), never user input, but this is disk
        // state built from a network response — sanitizing the one character that could escape the
        // directory costs nothing.
        let safe = locale.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safe).json")
    }

    /// A missing file, an unreadable one, or one that no longer decodes are all plain cache misses —
    /// this type's whole contract is that a catalogue problem costs an odd item name, never a failed
    /// sync, and that has to hold for the disk cache too.
    func load(locale: String) -> BringCatalogCacheEntry? {
        guard let data = try? Data(contentsOf: url(for: locale)),
              let stored = try? JSONDecoder().decode(StoredEntry.self, from: data)
        else { return nil }
        return BringCatalogCacheEntry(body: stored.body, fetchedAt: stored.fetchedAt)
    }

    /// Best-effort: a full disk or an unwritable directory should cost a cache write, not a sync.
    /// `BringCatalogClient` already has the parsed result in memory for this process, so a failed
    /// write only means the next launch re-fetches — no different from the file having been evicted.
    func save(_ entry: BringCatalogCacheEntry, locale: String) {
        guard let data = try? JSONEncoder().encode(StoredEntry(body: entry.body, fetchedAt: entry.fetchedAt))
        else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: locale), options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
