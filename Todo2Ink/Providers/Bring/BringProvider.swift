import Foundation

/// Bring! as a `TodoProvider`.
///
/// The same shape as `RemindersProvider`: a thin adapter that translates a backend's vocabulary into
/// the provider abstraction, with all the protocol-specific work behind it in `BringAuthClient` and
/// `BringListsClient`. `TodoSyncEngine` cannot tell the two providers apart, which is the point.
///
/// Bring! is unofficial and unaffiliated — see `BringModels.swift` for where the API description
/// came from. Nothing here uses Bring!'s branding beyond naming the service the user is connecting
/// to.
@MainActor
final class BringProvider: TodoProvider {
    let id = ProviderId.bring
    let displayName = "Bring!"

    private let auth: BringAuthClient
    private let lists: BringListsClient
    private let catalog: BringCatalogClient
    private let defaults: UserDefaults

    private(set) var authState: ProviderAuthState = .notConfigured

    /// What the last fetch saw, keyed by the `ProviderItem.id` this provider hands out.
    ///
    /// The write path needs an item's `spec` and `uuid` to send a change, and neither survives the
    /// round trip through `ProviderItem` (which is deliberately just id/text/checked). Rebuilding
    /// them by re-fetching on every check-off would be a request per tick of a checkbox, so the read
    /// path leaves them here instead.
    private var itemsByProviderItemId: [String: (listUuid: String, item: BringItem)] = [:]

    /// The `(listUuid, canonical itemId)` of the last successful `setCompleted(true, ...)`, kept
    /// only until the next `fetchItems` that covers that list.
    ///
    /// Purely a temporary diagnostic: we cannot explain why an item checked off from the reader
    /// doesn't move to the front of Bring!'s `recently` list the way it does in the official app, and
    /// no public client sends a timestamp that would order it. Logging where that item lands in the
    /// raw `recently` array settles empirically whether Bring! hands it back oldest-first (our
    /// `.reversed()` in `fetchItems` is right) or newest-first (it's backwards) — remove once that's
    /// answered.
    private var lastCheckOff: (listUuid: String, itemId: String)?

    var options: BringOptions {
        didSet { options.save(to: defaults) }
    }

    init(
        auth: BringAuthClient = BringAuthClient(),
        lists: BringListsClient? = nil,
        catalog: BringCatalogClient? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.auth = auth
        self.lists = lists ?? BringListsClient(auth: auth)
        self.catalog = catalog ?? BringCatalogClient(auth: auth)
        self.defaults = defaults
        self.options = BringOptions.load(from: defaults)
    }

    var statusDescription: String? {
        switch authState {
        // A statement rather than an instruction: this line appears both as the provider row's
        // subtitle *and* directly above the sign-in form, and "tap to sign in" is wrong in the
        // second place — there is nothing to tap, the fields are right there.
        case .notConfigured: return "Not signed in"
        case .authorized: return nil
        case .failed(let message): return message
        }
    }

    // MARK: - Account

    /// Signs in and, on success, leaves the provider authorized. The password goes no further than
    /// `BringAuthClient.logIn` — see `BringSession` for why it is never stored.
    func logIn(email: String, password: String) async throws {
        do {
            try await auth.logIn(email: email, password: password)
            authState = .authorized
        } catch {
            authState = .failed(Self.message(for: error))
            throw error
        }
    }

    func logOut() async {
        await auth.logOut()
        itemsByProviderItemId = [:]
        authState = .notConfigured
    }

    /// The email of the stored session, for the login screen to prefill after an expiry.
    func signedInEmail() async -> String? {
        await auth.storedEmail
    }

    /// The "Refresh Bring Data" escape hatch: wipes the cached article catalogue (disk and memory)
    /// and the process-lifetime settings alongside it, so the next sync re-reads everything from
    /// Bring! rather than serving stale section names or translations for the rest of the catalogue's
    /// TTL. Does not touch `itemsByProviderItemId` — that cache is list contents, never persisted and
    /// already refreshed by every `fetchItems`, which this button has nothing to do with.
    func clearCache() async {
        await catalog.clearCache()
    }

    // MARK: - TodoProvider

    /// Validates the stored session rather than prompting for anything — Bring! has no system
    /// permission dialog, so "requesting access" here means "check whether the login still works".
    func requestAccess() async throws -> Bool {
        do {
            _ = try await auth.validSession()
            authState = .authorized
            return true
        } catch let error as BringError where error.requiresReauthentication {
            // Not a failure to report: the user simply hasn't signed in, or needs to again.
            authState = .notConfigured
            return false
        } catch {
            authState = .failed(Self.message(for: error))
            return false
        }
    }

    func fetchLists() async throws -> [ProviderList] {
        do {
            let fetched = try await lists.lists()
            authState = .authorized
            return fetched.map { ProviderList(id: $0.listUuid, title: $0.name) }
        } catch {
            try recordAndRethrow(error)
        }
    }

    func fetchItems(listIds: [String]) async throws -> [String: [ProviderItem]] {
        var result: [String: [ProviderItem]] = [:]
        var cache: [String: (listUuid: String, item: BringItem)] = [:]

        for listUuid in listIds {
            let contents: BringListContentResponse
            do {
                contents = try await lists.contents(ofList: listUuid)
            } catch BringError.http(let status) where status == 404 {
                // A list the user removed from Bring! since they selected it. Absent from the
                // result is exactly what `TodoProvider.fetchItems` documents for this case.
                continue
            } catch {
                try recordAndRethrow(error)
            }

            // Resolved for the whole list at once: the catalogue is per locale, not per item, and
            // one lookup pass keeps the item loop below free of any awaiting.
            let articles = await catalog.articles(
                for: (contents.purchase + contents.recently).map(\.itemId),
                inList: listUuid
            )
            let userSectionByItemId = await userSectionIds(ofList: listUuid)

            logCheckOffPositionIfPending(listUuid: listUuid, recently: contents.recently)

            var items: [ProviderItem] = []
            var seen = Set<String>()

            // Grouped by section before appending, following the list's own section order — Bring!'s
            // own item order is preserved within a section, and purchase items the catalogue has no
            // section for come after every sectioned one rather than being dropped or interleaved.
            let sectionOrder = await catalog.sectionOrder(forList: listUuid)
            // Sections travel as canonical ids and are shown as localized names; `label(_:)` below is
            // the one place that crosses over, so ordering and grouping never have to.
            let sectionLabels = await catalog.sectionLabels(forList: listUuid)
            func label(_ sectionId: String) -> String { sectionLabels[sectionId] ?? sectionId }

            // An item the catalogue has no section for is not unsectioned to Bring! — it is one of
            // the user's own articles, which Bring! files under a section of its own that
            // `listSectionOrder` names and the catalogue doesn't contain. Falling back to it keeps a
            // list of mostly hand-typed items grouped the way the user's own app groups it, instead
            // of collapsing it into one nameless run.
            let ownArticles = await catalog.ownArticlesSection(forList: listUuid)
            var purchaseBySection: [String: [BringItem]] = [:]
            var unsectionedPurchase: [BringItem] = []
            for item in contents.purchase {
                guard seen.insert(item.itemId).inserted else { continue }
                // The user's own explicit assignment wins over the catalogue's default and over the
                // own-articles fallback — see `userSectionIds(ofList:)` for where it comes from and
                // why an unknown vocabulary still degrades to a usable (if unlabeled) group rather
                // than a crash.
                let userSection = userSectionByItemId[item.itemId]
                if let section = userSection ?? articles[item.itemId]?.section ?? ownArticles {
                    purchaseBySection[section, default: []].append(item)
                } else {
                    unsectionedPurchase.append(item)
                }
            }
            for section in sectionOrder {
                for item in purchaseBySection.removeValue(forKey: section) ?? [] {
                    items.append(providerItem(
                        for: item, inList: listUuid, checked: false,
                        displayName: articles[item.itemId]?.displayName, section: label(section),
                        cache: &cache
                    ))
                }
            }
            // Any section the catalogue knows about but `sectionOrder` didn't list still needs to
            // reach the device — appended after the known order rather than silently dropped, and in
            // sorted id order so a leftover section doesn't move around between syncs the way a
            // dictionary's own iteration order would.
            for section in purchaseBySection.keys.sorted() {
                for item in purchaseBySection[section] ?? [] {
                    items.append(providerItem(
                        for: item, inList: listUuid, checked: false,
                        displayName: articles[item.itemId]?.displayName, section: label(section),
                        cache: &cache
                    ))
                }
            }
            for item in unsectionedPurchase {
                items.append(providerItem(
                    for: item, inList: listUuid, checked: false,
                    displayName: articles[item.itemId]?.displayName, section: nil, cache: &cache
                ))
            }

            if options.showsRecentlyPurchased {
                // Bring! hands "recently bought" back oldest-first, and the app itself shows it the
                // other way round. Reversing before the limit matters twice over: it decides *which*
                // items survive the cut, not just their order — taking the first N of an oldest-first
                // list keeps the least recent ones, which is the opposite of the point.
                //
                // Grouped under Bring!'s own "recently bought" header (`recentlyLabel(forList:)`)
                // rather than left unsectioned: appending it after every purchase section, regardless
                // of item order within it, is what keeps it sorting last the way Bring!'s own app
                // shows it.
                let recentlyLabel = await catalog.recentlyLabel(forList: listUuid)
                for item in contents.recently.reversed().prefix(options.recentlyPurchasedLimit) {
                    guard seen.insert(item.itemId).inserted else { continue }
                    items.append(providerItem(
                        for: item, inList: listUuid, checked: true,
                        displayName: articles[item.itemId]?.displayName, section: recentlyLabel,
                        cache: &cache
                    ))
                }
            }

            logSections(of: items, sectionOrder: sectionOrder)
            result[listUuid] = items
        }

        authState = .authorized
        // Replaced wholesale rather than merged: an entry for an item that no longer exists would
        // only ever produce a change Bring! rejects.
        itemsByProviderItemId = cache
        return result
    }

    func setCompleted(_ completed: Bool, forItemId itemId: String) async throws {
        guard let entry = try await resolve(itemId) else {
            // Genuinely gone from Bring! — the no-op `TodoProvider.setCompleted` documents. Logged
            // rather than silent, because this being indistinguishable from a bug is what made the
            // cache-miss failure below so hard to see.
            DebugLog.shared.log("bring: no item for \(itemId); check-off dropped")
            return
        }
        do {
            try await lists.setPurchased(completed, item: entry.item, inList: entry.listUuid)
            if completed {
                lastCheckOff = (listUuid: entry.listUuid, itemId: entry.item.itemId)
            }
        } catch {
            try recordAndRethrow(error)
        }
    }

    /// Finds an item's `spec` and `uuid`, fetching its list if the last read didn't leave them in
    /// the cache.
    ///
    /// That fallback is load-bearing, not belt-and-braces. `TodoSyncEngine` writes deviations back
    /// *before* it assembles the document, and the first sync of a session runs that write-back
    /// against a cache no fetch has filled yet — the pull is owed from `HELLO_OK`, which arrives
    /// before anything has read a list. Returning nil there dropped the user's check-off silently,
    /// and the next sync then rebuilt the document from a Bring! that had never heard about it and
    /// pushed the reader's own checkmark away.
    private func resolve(_ providerItemId: String) async throws -> (listUuid: String, item: BringItem)? {
        if let cached = itemsByProviderItemId[providerItemId] { return cached }

        // Same split as `providerItem(for:inList:checked:displayName:section:cache:)` mints: list
        // uuid, then the item's Bring! name, which may itself contain a slash.
        guard let slash = providerItemId.firstIndex(of: "/") else { return nil }
        let listUuid = String(providerItemId[providerItemId.startIndex..<slash])
        let name = String(providerItemId[providerItemId.index(after: slash)...])

        let contents = try await lists.contents(ofList: listUuid)
        guard let item = (contents.purchase + contents.recently).first(where: { $0.itemId == name })
        else { return nil }

        let resolved = (listUuid: listUuid, item: item)
        itemsByProviderItemId[providerItemId] = resolved
        return resolved
    }

    /// The `itemId -> userSectionId` map from `bringlists/{listUuid}/details` — the user's own
    /// explicit section assignments, which `fetchItems` prefers over the catalogue's default.
    ///
    /// The endpoint is undocumented (see `BringModels.swift`), so a failure here — a 404 because the
    /// path guess is wrong, a shape change, anything — must not fail the sync: grouping by the
    /// user's own assignment is a nicety on top of the catalogue's, not a replacement for the whole
    /// item fetch. It degrades to an empty map, which leaves every item's section exactly where the
    /// catalogue and `ownArticlesSection(forList:)` would have put it without this call.
    ///
    /// Also settles the open question of what `userSectionId`'s vocabulary actually is: logging the
    /// distinct values seen answers "canonical section id, uuid, or localized name?" from one field
    /// report, without needing to log the user's actual items.
    private func userSectionIds(ofList listUuid: String) async -> [String: String] {
        let details: [BringItemDetails]
        do {
            details = try await lists.details(ofList: listUuid)
        } catch {
            DebugLog.shared.log(
                "bring: /details failed for \(listUuid), falling back to catalogue sections: \(error)"
            )
            return [:]
        }

        var result: [String: String] = [:]
        var distinct = Set<String>()
        for entry in details {
            guard let value = entry.userSectionId, !value.isEmpty else { continue }
            result[entry.itemId] = value
            distinct.insert(value)
        }
        if !distinct.isEmpty {
            DebugLog.shared.log(
                "bring: userSectionId values: \(distinct.sorted().joined(separator: ", "))"
                    + " (\(result.count) of \(details.count) items)"
            )
        }
        return result
    }

    // MARK: - Private

    /// Composes the id the rest of the app sees. Bring! keys items by display name *within a list*,
    /// so the list uuid is what makes it unique — and it makes the write path's list lookup work
    /// even for an id that outlived the cache. Splitting at the first `/` is safe because a Bring!
    /// list uuid never contains one, while an item name may.
    private func providerItem(
        for item: BringItem,
        inList listUuid: String,
        checked: Bool,
        displayName: String?,
        section: String?,
        cache: inout [String: (listUuid: String, item: BringItem)]
    ) -> ProviderItem {
        // The *canonical* name, never the localized one: this id is what a check-off is resolved
        // through, and Bring! only recognises the canonical name in a write.
        let id = "\(listUuid)/\(item.itemId)"
        cache[id] = (listUuid, item)

        let name = displayName ?? item.itemId
        // The note is part of what the user wrote down ("Milk 2l"), so it belongs on the line the
        // reader shows rather than being dropped for being a separate field on the wire.
        let text = item.specification.isEmpty ? name : "\(name) (\(item.specification))"
        return ProviderItem(id: id, text: text, checked: checked, section: section)
    }

    /// Diagnostic only — see `lastCheckOff`'s doc comment. Logs where the item from the last
    /// check-off landed in the raw (pre-`.reversed()`) `recently` array, then clears it so it only
    /// ever logs once per check-off. Numbers only, never the item's name.
    private func logCheckOffPositionIfPending(listUuid: String, recently: [BringItem]) {
        guard let pending = lastCheckOff, pending.listUuid == listUuid else { return }
        lastCheckOff = nil
        guard let index = recently.firstIndex(where: { $0.itemId == pending.itemId }) else {
            DebugLog.shared.log("bring: last check-off is no longer in recently (\(recently.count) items)")
            return
        }
        DebugLog.shared.log(
            "bring: last check-off is at index \(index) of \(recently.count) in recently (pre-reversal)"
        )
    }

    /// What this list is about to send as groups, and how the section order it was arranged by was
    /// resolved.
    ///
    /// A temporary diagnostic, like `logCheckOffPositionIfPending` above: a reader showing one
    /// section where the user's Bring! shows several could be the catalogue resolving no section for
    /// most items, a `listSectionOrder` in a vocabulary that matches no id, or the grouping itself —
    /// and those look identical from the outside. Item names are included because the user has said
    /// this account holds nothing sensitive — which is what makes "which items got no section"
    /// answerable at a glance. That permission is theirs and not a general one, so this has to go
    /// before the app is published, together with `lastCheckOff`.
    private func logSections(of items: [ProviderItem], sectionOrder: [String]) {
        var groups: [(label: String, items: [String])] = []
        for item in items {
            let label = item.section ?? "(none)"
            if let last = groups.indices.last, groups[last].label == label {
                groups[last].items.append(item.text)
            } else {
                groups.append((label, [item.text]))
            }
        }
        let rendered = groups
            .map { "\($0.label): \($0.items.joined(separator: ", "))" }
            .joined(separator: " | ")
        DebugLog.shared.log("bring: sectionOrder(\(sectionOrder.count)) → \(rendered)")
    }

    /// Records an error as the provider's auth state and rethrows it, so a failure both stops this
    /// call and shows up on the provider row.
    private func recordAndRethrow(_ error: Error) throws -> Never {
        if let bring = error as? BringError, bring.requiresReauthentication {
            authState = .notConfigured
        } else {
            authState = .failed(Self.message(for: error))
        }
        throw error
    }

    private static func message(for error: Error) -> String {
        (error as? BringError)?.errorDescription ?? error.localizedDescription
    }
}
