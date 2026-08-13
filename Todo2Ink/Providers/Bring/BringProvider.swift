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
    private let defaults: UserDefaults

    private(set) var authState: ProviderAuthState = .notConfigured

    /// What the last fetch saw, keyed by the `ProviderItem.id` this provider hands out.
    ///
    /// The write path needs an item's `spec` and `uuid` to send a change, and neither survives the
    /// round trip through `ProviderItem` (which is deliberately just id/text/checked). Rebuilding
    /// them by re-fetching on every check-off would be a request per tick of a checkbox, so the read
    /// path leaves them here instead.
    private var itemsByProviderItemId: [String: (listUuid: String, item: BringItem)] = [:]

    var options: BringOptions {
        didSet { options.save(to: defaults) }
    }

    init(
        auth: BringAuthClient = BringAuthClient(),
        lists: BringListsClient? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.auth = auth
        self.lists = lists ?? BringListsClient(auth: auth)
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

            var items: [ProviderItem] = []
            var seen = Set<String>()

            for item in contents.purchase {
                guard seen.insert(item.itemId).inserted else { continue }
                items.append(providerItem(for: item, inList: listUuid, checked: false, cache: &cache))
            }

            if options.showsRecentlyPurchased {
                for item in contents.recently.prefix(options.recentlyPurchasedLimit) {
                    guard seen.insert(item.itemId).inserted else { continue }
                    items.append(providerItem(for: item, inList: listUuid, checked: true, cache: &cache))
                }
            }

            result[listUuid] = items
        }

        authState = .authorized
        // Replaced wholesale rather than merged: an entry for an item that no longer exists would
        // only ever produce a change Bring! rejects.
        itemsByProviderItemId = cache
        return result
    }

    func setCompleted(_ completed: Bool, forItemId itemId: String) async throws {
        guard let entry = itemsByProviderItemId[itemId] else {
            // The item was minted before the last fetch dropped it — the no-op
            // `TodoProvider.setCompleted` documents, not an error.
            return
        }
        do {
            try await lists.setPurchased(completed, item: entry.item, inList: entry.listUuid)
        } catch {
            try recordAndRethrow(error)
        }
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
        cache: inout [String: (listUuid: String, item: BringItem)]
    ) -> ProviderItem {
        let id = "\(listUuid)/\(item.itemId)"
        cache[id] = (listUuid, item)
        // The note is part of what the user wrote down ("Milk 2l"), so it belongs on the line the
        // reader shows rather than being dropped for being a separate field on the wire.
        let text = item.specification.isEmpty ? item.itemId : "\(item.itemId) (\(item.specification))"
        return ProviderItem(id: id, text: text, checked: checked)
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
