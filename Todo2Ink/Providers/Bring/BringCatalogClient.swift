import Foundation

/// Turns Bring!'s canonical article names into what the user actually sees: a display name and,
/// where the catalogue has one, the section it defaults into.
///
/// Bring! keys every item by a canonical name in its base locale (`de-CH`) and displays a localized
/// one — the reason a list showing "Chips" comes back over the wire as `"Pommes Chips"`. The
/// catalogue is the same file per locale, served unauthenticated from `web.getbring.com`, a few
/// hundred entries grouped into ~13 sections.
///
/// **Only display text and section grouping are localized/derived here.** `BringItem.itemId` stays
/// canonical everywhere else — it is what identifies the item in a write, and what `ProviderItem.id`
/// is built from. Localizing an id would break check-off write-back for exactly the items whose
/// names differ, which is the subset this type exists for.
///
/// Every lookup degrades gracefully rather than failing: a missing catalogue, an unsupported locale
/// or an unreachable `web.getbring.com` should cost the user a slightly odd item name or a flat
/// (ungrouped) list, never a failed sync.
actor BringCatalogClient {
    private let http: BringHTTP
    private let auth: BringAuthClient
    private let store: BringCatalogStore
    private let now: () -> Date

    /// Bring!'s own base locale. Its catalogue's item *names* are the identity mapping (a name
    /// equals its own canonical id), but its section assignments are not derivable any other way, so
    /// it is fetched like any other locale — see `articles(for:inList:)`.
    private static let baseLocale = "de-CH"

    /// The catalogue is static reference data (a few hundred entries, ~13 sections) that changes on
    /// the order of yearly, not the interval a re-fetch actually needs — a week is short enough that
    /// a genuine change reaches users promptly, and long enough that this cache is doing its job on
    /// every ordinary day. Not user-configurable: a knob measured in days for data that changes
    /// yearly is a setting nobody could set correctly.
    private static let catalogTTL: TimeInterval = 7 * 24 * 60 * 60

    /// `listArticleLanguage` and `listSectionOrder`, per list — kept process-lifetime only, never on
    /// disk, unlike the catalogue below. They change whenever the user reorders sections or changes a
    /// list's language in Bring! itself, and a stale `sectionOrderByListUuid` would leave the reader
    /// ordering things the way the user used to have them, silently, until the next relaunch happened
    /// to notice. They're also cheap — one request, read once per process — so there's nothing to
    /// gain by persisting them and a correctness bug to risk.
    private var localeByListUuid: [String: String] = [:]
    /// The raw `listSectionOrder` value per list, still a string — its exact shape is unconfirmed,
    /// so parsing is deferred to `sectionOrder(forList:)`.
    private var sectionOrderByListUuid: [String: String] = [:]
    private var userLocale: String?
    private var settingsLoaded = false
    private var hasLoggedUnparseableSectionOrder = false

    /// Catalogues are cached in memory for the process lifetime, keyed by locale, on top of the disk
    /// cache `store` backs (see `catalog(for:)`) — re-fetching or re-decoding one per sync would be
    /// pure waste. A locale with no catalogue (a 404) caches to `.empty`, so it costs one request per
    /// TTL window, not one per sync.
    private var catalogByLocale: [String: LocaleCatalog] = [:]

    init(
        http: BringHTTP = BringHTTP(),
        auth: BringAuthClient,
        store: BringCatalogStore = DiskBringCatalogStore(),
        now: @escaping () -> Date = Date.init
    ) {
        self.http = http
        self.auth = auth
        self.store = store
        self.now = now
    }

    /// Wipes every cached catalogue, in memory and on disk, and the settings state alongside them —
    /// the user-facing "Refresh Bring Data" escape hatch. Resetting `settingsLoaded` too means the
    /// next sync genuinely re-reads `listArticleLanguage` and `listSectionOrder` rather than only the
    /// catalogue half of what this type caches.
    func clearCache() {
        catalogByLocale = [:]
        store.clear()
        settingsLoaded = false
        localeByListUuid = [:]
        sectionOrderByListUuid = [:]
        userLocale = nil
    }

    /// A resolved article: what the user sees, and — when the catalogue has an answer — the section
    /// it belongs in. `displayName` defaults to the canonical name and `section` to `nil` when the
    /// catalogue has nothing to say.
    ///
    /// `section` is the canonical `sectionId`, not a localized name — the same string
    /// `sectionOrder(forList:)` orders by, and stable across every locale, which is what lets a
    /// section fall back across locales without a translation step. It is an identity, not something
    /// to show: `sectionLabels(forList:)` is what turns it into the heading the user reads.
    struct BringArticle: Equatable {
        let displayName: String
        let section: String?
    }

    /// Display name and section for a list's canonical item names, keyed by the canonical name.
    func articles(for canonicalNames: [String], inList listUuid: String) async -> [String: BringArticle] {
        guard !canonicalNames.isEmpty else { return [:] }

        let locale = await self.locale(forList: listUuid)
        let primary = await catalog(for: locale)
        let base = locale == Self.baseLocale ? primary : await catalog(for: Self.baseLocale)

        var result: [String: BringArticle] = [:]
        for name in canonicalNames {
            let displayName = primary.displayNameByItem[name] ?? name
            // `sectionId` is canonical and locale-independent, so falling back to the base
            // catalogue's assignment is still a *correct* section even when the list's own locale has
            // no catalogue — a user with an unsupported locale gets a grouped list with canonical
            // names rather than a flat one.
            let section = primary.sectionIdByItem[name] ?? base.sectionIdByItem[name]
            result[name] = BringArticle(displayName: displayName, section: section)
        }
        return result
    }

    /// Canonical section ids for a list, in the order the device should show them.
    ///
    /// Sourced from the list's own `listSectionOrder` setting when present and parseable, and from
    /// the catalogue's own section order otherwise — which is also what an unsectioned catalogue
    /// (an empty list here) degrades to.
    func sectionOrder(forList listUuid: String) async -> [String] {
        await loadSettingsIfNeeded()

        if let raw = sectionOrderByListUuid[listUuid], let parsed = parseSectionOrder(raw) {
            return parsed
        }

        let locale = await self.locale(forList: listUuid)
        let primary = await catalog(for: locale)
        if !primary.sectionOrder.isEmpty { return primary.sectionOrder }
        guard locale != Self.baseLocale else { return [] }
        return await catalog(for: Self.baseLocale).sectionOrder
    }

    /// Where an item the catalogue has never heard of belongs — Bring!'s own "own articles" section.
    ///
    /// It isn't a catalogue section and has no fixed id, but it is in `listSectionOrder` (a real
    /// account's ends `…, "Baumarkt & Garten", "Eigene Artikel"`), so it is recoverable as the entry
    /// the catalogue doesn't account for. Taking it from the user's own settings rather than
    /// hardcoding a string means it arrives already in their language and already in the position
    /// they put it.
    ///
    /// Nil when a list's order came from the catalogue rather than the settings: then every entry is
    /// a catalogue section by construction, and there is nothing to infer.
    func ownArticlesSection(forList listUuid: String) async -> String? {
        let order = await sectionOrder(forList: listUuid)
        let locale = await self.locale(forList: listUuid)
        var known = Set(await catalog(for: locale).sectionOrder)
        if known.isEmpty { known = Set(await catalog(for: Self.baseLocale).sectionOrder) }
        guard !known.isEmpty else { return nil }
        return order.first { !known.contains($0) }
    }

    /// What to *print* above each section, keyed by the canonical `sectionId` that
    /// `sectionOrder(forList:)` and `BringArticle.section` speak in.
    ///
    /// A section id is only ever an identity; showing it would head a German list with Swiss German
    /// ("Früchte & Gemüse" where the user's own Bring! says "Obst & Gemüse"). An id the catalogue has
    /// no name for is simply absent, and the caller shows the id — the same degradation an item with
    /// no catalogue entry already gets.
    func sectionLabels(forList listUuid: String) async -> [String: String] {
        let locale = await self.locale(forList: listUuid)
        return await catalog(for: locale).sectionNameById
    }

    /// The header Bring!'s own app puts above its "recently bought" list — nowhere in the API or the
    /// article catalogue, since it isn't an article or a section Bring! lets the user reorder, just
    /// fixed chrome in Bring!'s UI. Hardcoded here per language rather than derived, and keyed by the
    /// list's own locale the same way `sectionLabels(forList:)` is, so a German list reads "Zuletzt
    /// verwendet" regardless of what language the phone itself is in.
    func recentlyLabel(forList listUuid: String) async -> String {
        let locale = await self.locale(forList: listUuid)
        let language = locale.split(separator: "-", maxSplits: 1).first.map(String.init) ?? locale
        return Self.recentlyLabelByLanguage[language] ?? Self.recentlyLabelByLanguage["en"]!
    }

    /// One entry per language Bring! supports (not per region — this phrase doesn't vary within a
    /// language across `BRING_SUPPORTED_LOCALES`' regions, e.g. `de-AT`/`de-CH`/`de-DE`). Verified
    /// against a real German account; the rest are our own translations of that same phrase, not
    /// pulled from Bring! itself, since Bring! exposes no string resource for it.
    private static let recentlyLabelByLanguage: [String: String] = [
        "de": "Zuletzt verwendet",
        "en": "Recently used",
        "fr": "Utilisés récemment",
        "it": "Usati di recente",
        "es": "Usados recientemente",
        "pt": "Usados recentemente",
        "nl": "Onlangs gebruikt",
        "pl": "Ostatnio używane",
        "sv": "Nyligen använda",
        "nb": "Nylig brukt",
        "tr": "Son kullanılanlar",
        "hu": "Nemrég használt",
        "ru": "Недавно использованные",
    ]

    /// Parses `listSectionOrder`'s string value. A real account confirmed it is a plain JSON array
    /// of section ids; the object form is kept as a second guess because nothing about this field is
    /// documented and one account is one observation. An unparseable value logs its shape once —
    /// keys only, so the line stays useful without depending on whose account it came from.
    private func parseSectionOrder(_ raw: String) -> [String]? {
        let data = Data(raw.utf8)
        if let ids = try? JSONDecoder().decode([String].self, from: data) {
            return ids
        }
        struct SectionEntry: Decodable { let sectionId: String }
        if let entries = try? JSONDecoder().decode([SectionEntry].self, from: data) {
            return entries.map(\.sectionId)
        }

        if !hasLoggedUnparseableSectionOrder {
            hasLoggedUnparseableSectionOrder = true
            DebugLog.shared.log("bring: listSectionOrder unparseable; shape: \(BringHTTP.shape(of: data))")
        }
        return nil
    }

    // MARK: - Locale

    /// The locale a given list's articles are named in: the list's own setting if it has one, the
    /// account's otherwise, and Bring!'s base locale as the last resort — which means no
    /// translation at all, the safe direction to fail in.
    private func locale(forList listUuid: String) async -> String {
        await loadSettingsIfNeeded()
        return localeByListUuid[listUuid] ?? userLocale ?? Self.baseLocale
    }

    private func loadSettingsIfNeeded() async {
        guard !settingsLoaded else { return }
        // Set first: a failure here must not make every later sync retry two requests that are
        // already known not to work. A wrong-but-canonical name is cheaper than that.
        settingsLoaded = true

        guard let session = try? await auth.validSession() else { return }

        if let settings = try? await http.send(
            http.request(path: "bringusersettings/\(session.userUuid)", session: session),
            decoding: BringUserSettingsResponse.self
        ) {
            for list in settings.userlistsettings ?? [] {
                for entry in list.usersettings {
                    switch entry.key {
                    case "listArticleLanguage":
                        localeByListUuid[list.listUuid] = entry.value
                    case "listSectionOrder":
                        sectionOrderByListUuid[list.listUuid] = entry.value
                    default:
                        break
                    }
                }
            }
        }

        userLocale = Self.deviceLocale
    }

    /// The fallback when a list carries no article language of its own.
    ///
    /// Reading the account's own locale would be better, but `GET bringusers/{uuid}` answers 405 and
    /// the right call isn't known — so this uses the phone's language and region, which is the same
    /// guess `X-BRING-COUNTRY` already makes on every request. A locale Bring! doesn't publish a
    /// catalogue for simply 404s and leaves the canonical names in place, so a wrong guess is cheap.
    private static var deviceLocale: String? {
        guard let language = Locale.current.language.languageCode?.identifier,
              let region = Locale.current.region?.identifier
        else { return nil }
        return "\(language)-\(region)"
    }

    // MARK: - Catalogue

    /// One locale's catalogue, flattened into the lookups `articles(for:inList:)`,
    /// `sectionOrder(forList:)` and `sectionLabels(forList:)` need.
    private struct LocaleCatalog {
        let displayNameByItem: [String: String]
        let sectionIdByItem: [String: String]
        /// Localized section names, keyed by canonical `sectionId` — the same canonical/localized
        /// split the items themselves have, and the reason a de-DE list heads its first section
        /// "Obst & Gemüse" while every locale agrees its id is "Früchte & Gemüse".
        let sectionNameById: [String: String]
        /// Canonical section ids, in the order the catalogue lists them.
        let sectionOrder: [String]

        static let empty = LocaleCatalog(
            displayNameByItem: [:], sectionIdByItem: [:], sectionNameById: [:], sectionOrder: []
        )

        init(
            displayNameByItem: [String: String],
            sectionIdByItem: [String: String],
            sectionNameById: [String: String],
            sectionOrder: [String]
        ) {
            self.displayNameByItem = displayNameByItem
            self.sectionIdByItem = sectionIdByItem
            self.sectionNameById = sectionNameById
            self.sectionOrder = sectionOrder
        }

        init(_ response: BringCatalogResponse) {
            var displayNames: [String: String] = [:]
            var sectionByItem: [String: String] = [:]
            var sectionNames: [String: String] = [:]
            var order: [String] = []
            for section in response.catalog.sections {
                order.append(section.sectionId)
                sectionNames[section.sectionId] = section.name
                for item in section.items {
                    displayNames[item.itemId] = item.name
                    sectionByItem[item.itemId] = section.sectionId
                }
            }
            self.init(
                displayNameByItem: displayNames,
                sectionIdByItem: sectionByItem,
                sectionNameById: sectionNames,
                sectionOrder: order
            )
        }
    }

    /// Lookup order: memory, then disk (if within `catalogTTL`), then network — and a successful
    /// network fetch writes through to both, so the next process launch finds it on disk and this
    /// process never re-decodes it.
    private func catalog(for locale: String) async -> LocaleCatalog {
        if let cached = catalogByLocale[locale] { return cached }

        if let entry = store.load(locale: locale), !isExpired(entry.fetchedAt),
           let fromDisk = parsed(from: entry.body) {
            catalogByLocale[locale] = fromDisk
            return fromDisk
        }

        return await fetchAndCache(locale)
    }

    private func isExpired(_ fetchedAt: Date) -> Bool {
        now().timeIntervalSince(fetchedAt) >= Self.catalogTTL
    }

    /// `nil` body is the cached "this locale 404s" fact and decodes straight to `.empty` — it is not
    /// a failure to recover from, unlike a body that fails to decode, which means the cache entry
    /// itself is corrupt (a partial write, a format change) and must be treated as a miss so the
    /// caller re-fetches rather than getting stuck on bad data for a whole TTL window.
    private func parsed(from body: Data?) -> LocaleCatalog? {
        guard let body else { return .empty }
        guard let response = try? JSONDecoder().decode(BringCatalogResponse.self, from: body) else {
            return nil
        }
        return LocaleCatalog(response)
    }

    private func fetchAndCache(_ locale: String) async -> LocaleCatalog {
        guard let url = URL(string: "https://web.getbring.com/locale/catalog.\(locale).json") else {
            catalogByLocale[locale] = .empty
            return .empty
        }
        do {
            // Deliberately not `http.request(...)`: this is a static file on a different host, not
            // an API call, and it takes none of the API's headers or the user's bearer token.
            let data = try await http.send(URLRequest(url: url))
            let response = try JSONDecoder().decode(BringCatalogResponse.self, from: data)
            let parsed = LocaleCatalog(response)
            catalogByLocale[locale] = parsed
            store.save(BringCatalogCacheEntry(body: data, fetchedAt: now()), locale: locale)
            return parsed
        } catch {
            DebugLog.shared.log("bring: no article catalogue for \(locale); using canonical names")
            catalogByLocale[locale] = .empty
            // A confirmed 404 is exactly as cacheable as a successful body — see
            // `BringCatalogCacheEntry`'s doc comment for why `nil` here is the whole point of this
            // TTL, not a degraded case of it.
            store.save(BringCatalogCacheEntry(body: nil, fetchedAt: now()), locale: locale)
            return .empty
        }
    }
}
