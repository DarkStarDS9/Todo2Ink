import XCTest
@testable import Todo2Ink

/// The translation layer: Bring!'s purchase/recently split becoming checked/unchecked
/// `ProviderItem`s, and a device-side check-off becoming the right batch change on the wire.
@MainActor
final class BringProviderTests: XCTestCase {
    private var store: InMemoryBringCredentialStore!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        FakeBringServer.reset()
        suiteName = "BringProviderTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = InMemoryBringCredentialStore(
            session: .fake(expiresAt: Date(timeIntervalSinceNow: 3600))
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        FakeBringServer.reset()
        super.tearDown()
    }

    private func provider(options: BringOptions = .default) -> BringProvider {
        let http = BringHTTP(urlSession: FakeBringServer.session())
        let auth = BringAuthClient(http: http, store: store, now: Date.init)
        let provider = BringProvider(
            auth: auth,
            lists: BringListsClient(http: http, auth: auth),
            defaults: defaults
        )
        provider.options = options
        return provider
    }

    private func serveFixtures() {
        FakeBringServer.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/lists") { return .ok(BringFixtures.lists) }
            if path.hasSuffix("/items") { return .ok("{}") }
            return .ok(BringFixtures.listContents)
        }
    }

    func testFetchListsMapsUuidAndName() async throws {
        serveFixtures()
        let lists = try await provider().fetchLists()
        XCTAssertEqual(lists.map(\.id), ["list-a", "list-b"])
        XCTAssertEqual(lists.map(\.title), ["Einkauf", "Baumarkt"])
    }

    /// Bring! has no "completed" flag — an item is unchecked if it's still to buy and checked if
    /// it's in "recently bought". That mapping is the whole reason this provider can exist.
    func testPurchaseIsUncheckedAndRecentlyIsChecked() async throws {
        serveFixtures()
        let items = try await provider().fetchItems(listIds: ["list-a"])["list-a"]
        XCTAssertEqual(items?.map(\.checked), [false, false, true])
        XCTAssertEqual(items?.map(\.text), ["Milch (2 Liter)", "Brot", "Butter"])
    }

    func testRecentlyPurchasedCanBeHidden() async throws {
        serveFixtures()
        let options = BringOptions(showsRecentlyPurchased: false, recentlyPurchasedLimit: 10)
        let items = try await provider(options: options).fetchItems(listIds: ["list-a"])["list-a"]
        XCTAssertEqual(items?.map(\.text), ["Milch (2 Liter)", "Brot"])
    }

    func testRecentlyPurchasedIsCapped() async throws {
        serveFixtures()
        let options = BringOptions(showsRecentlyPurchased: true, recentlyPurchasedLimit: 0)
        let items = try await provider(options: options).fetchItems(listIds: ["list-a"])["list-a"]
        XCTAssertEqual(items?.count, 2)
    }

    /// Bring! keys items by display name within a list, so the list uuid is what makes the id
    /// unique — two lists both containing "Milch" must not collapse into one `ProviderMapping` id.
    func testItemIdsAreScopedToTheirList() async throws {
        serveFixtures()
        let items = try await provider().fetchItems(listIds: ["list-a", "list-b"])
        XCTAssertEqual(items["list-a"]?.first?.id, "list-a/Milch")
        XCTAssertEqual(items["list-b"]?.first?.id, "list-b/Milch")
    }

    /// A list deleted in Bring! since the user selected it is a normal event, not a sync failure —
    /// it is simply absent from the result, which is what `TodoProvider.fetchItems` promises.
    func testAMissingListIsSkippedRatherThanThrowing() async throws {
        FakeBringServer.handler = { request in
            request.url?.path.hasSuffix("list-a") == true ? .status(404) : .ok(BringFixtures.listContents)
        }
        let items = try await provider().fetchItems(listIds: ["list-a", "list-b"])
        XCTAssertNil(items["list-a"])
        XCTAssertEqual(items["list-b"]?.count, 3)
    }

    func testCheckingAnItemOffSendsAToRecentlyChange() async throws {
        serveFixtures()
        let provider = self.provider()
        _ = try await provider.fetchItems(listIds: ["list-a"])

        try await provider.setCompleted(true, forItemId: "list-a/Milch")

        let request = try XCTUnwrap(FakeBringServer.recorded.last).request
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/rest/v2/bringlists/list-a/items")

        let body = try XCTUnwrap(FakeBringServer.lastBodyJSON)
        let changes = try XCTUnwrap(body["changes"] as? [[String: Any]])
        XCTAssertEqual(changes.count, 1, "mutations are always a batch envelope, even for one item")
        XCTAssertEqual(changes[0]["operation"] as? String, "TO_RECENTLY")
        XCTAssertEqual(changes[0]["itemId"] as? String, "Milch")
        XCTAssertEqual(changes[0]["spec"] as? String, "2 Liter", "the note must survive the round trip")
        XCTAssertEqual(changes[0]["uuid"] as? String, "item-1")
        XCTAssertEqual(body["sender"] as? String, "")
        // The server requires these; the app has nothing to say about them.
        XCTAssertEqual(changes[0]["latitude"] as? String, "0.0")
        XCTAssertEqual(changes[0]["longitude"] as? String, "0.0")
    }

    /// There is no "uncomplete" operation — putting an item back on the list is `TO_PURCHASE`.
    func testUncheckingAnItemSendsToPurchase() async throws {
        serveFixtures()
        let provider = self.provider()
        _ = try await provider.fetchItems(listIds: ["list-a"])

        try await provider.setCompleted(false, forItemId: "list-a/Butter")

        let changes = try XCTUnwrap(FakeBringServer.lastBodyJSON?["changes"] as? [[String: Any]])
        XCTAssertEqual(changes[0]["operation"] as? String, "TO_PURCHASE")
        XCTAssertEqual(changes[0]["itemId"] as? String, "Butter")
    }

    func testCheckingOffAnItemThatNoLongerExistsIsANoOp() async throws {
        serveFixtures()
        let provider = self.provider()
        _ = try await provider.fetchItems(listIds: ["list-a"])
        let before = FakeBringServer.recorded.count

        try await provider.setCompleted(true, forItemId: "list-a/Gone")
        XCTAssertEqual(FakeBringServer.recorded.count, before, "no request should have been sent")
    }

    /// A 401 mid-request is retried once with a fresh token, because a token can expire between the
    /// expiry check and the server seeing it.
    func testAnExpiredTokenMidRequestIsRetriedOnce() async throws {
        nonisolated(unsafe) var listsAttempts = 0
        FakeBringServer.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/bringauth/token") { return .ok(BringFixtures.refreshedAuth) }
            listsAttempts += 1
            return listsAttempts == 1 ? .status(401) : .ok(BringFixtures.lists)
        }

        let lists = try await provider().fetchLists()
        XCTAssertEqual(lists.count, 2)
        XCTAssertEqual(listsAttempts, 2)
        XCTAssertEqual(store.stored?.accessToken, "access-2")
    }

    // MARK: - Auth state

    func testNoLoginReadsAsNotConfiguredRatherThanFailed() async throws {
        store = InMemoryBringCredentialStore()
        let provider = self.provider()
        let granted = try await provider.requestAccess()
        XCTAssertEqual(granted, false)
        XCTAssertEqual(provider.authState, .notConfigured)
    }

    /// A server outage must not read as "you're signed out" — that would send the user to a login
    /// screen for a problem no password fixes.
    func testAServerErrorReadsAsFailedNotSignedOut() async {
        FakeBringServer.handler = { _ in .status(503) }
        let provider = self.provider()
        _ = try? await provider.fetchLists()
        guard case .failed = provider.authState else {
            return XCTFail("expected .failed, got \(provider.authState)")
        }
    }

    func testOptionsSurviveARelaunch() {
        let provider = self.provider()
        provider.options = BringOptions(showsRecentlyPurchased: false, recentlyPurchasedLimit: 3)
        XCTAssertEqual(BringOptions.load(from: defaults).recentlyPurchasedLimit, 3)
        XCTAssertEqual(BringOptions.load(from: defaults).showsRecentlyPurchased, false)
    }
}
