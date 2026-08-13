import XCTest
@testable import Todo2Ink

/// `BringCatalogClient`'s disk cache: the lookup order (memory → disk → network), the 7-day TTL, the
/// `clearCache()` escape hatch, and that every failure mode (a 404, a corrupt file) degrades to a
/// network fetch rather than an error — the same contract the in-memory cache it wraps already had.
final class BringCatalogClientTests: XCTestCase {
    private var authStore: InMemoryBringCredentialStore!
    private var catalogStore: InMemoryBringCatalogStore!
    private var http: BringHTTP!
    private var now: Date!

    override func setUp() {
        super.setUp()
        FakeBringServer.reset()
        authStore = InMemoryBringCredentialStore(session: .fake(expiresAt: Date(timeIntervalSinceNow: 3600)))
        catalogStore = InMemoryBringCatalogStore()
        http = BringHTTP(urlSession: FakeBringServer.session())
        now = Date(timeIntervalSince1970: 1_000_000)
    }

    override func tearDown() {
        FakeBringServer.reset()
        super.tearDown()
    }

    /// A fresh client sharing `catalogStore` — the disk cache — but never the in-memory one, which is
    /// exactly what a relaunch looks like.
    private func client() -> BringCatalogClient {
        let auth = BringAuthClient(http: http, store: authStore, now: { self.now })
        return BringCatalogClient(http: http, auth: auth, store: catalogStore, now: { self.now })
    }

    private func serveFixtures(catalogStatus: Int = 200) {
        FakeBringServer.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("catalog.de-DE.json") {
                guard catalogStatus == 200 else { return .status(catalogStatus) }
                return .ok(BringFixtures.catalog(language: "de-DE", sections: [
                    (id: "Fruit", name: "Obst", items: [(itemId: "Apfel", name: "Apfel")]),
                ]))
            }
            if path.hasPrefix("/rest/bringusersettings") {
                return .ok("""
                {"userlistsettings": [{"listUuid": "list-a", "usersettings": [
                  {"key": "listArticleLanguage", "value": "de-DE"}
                ]}]}
                """)
            }
            return .status(404)
        }
    }

    private func catalogRequestCount() -> Int {
        FakeBringServer.recorded
            .filter { $0.request.url?.path.hasSuffix("catalog.de-DE.json") == true }
            .count
    }

    func testASecondClientServesFromDiskWithoutHittingTheNetwork() async {
        serveFixtures()

        _ = await client().sectionOrder(forList: "list-a")
        XCTAssertEqual(catalogRequestCount(), 1)

        // A brand-new client — no in-memory cache of its own — sharing only `catalogStore`, the way
        // a relaunch would.
        _ = await client().sectionOrder(forList: "list-a")
        XCTAssertEqual(catalogRequestCount(), 1, "the disk cache should have served the second call")
    }

    func testPastTheTTLItRefetches() async {
        serveFixtures()

        _ = await client().sectionOrder(forList: "list-a")
        XCTAssertEqual(catalogRequestCount(), 1)

        now = now.addingTimeInterval(8 * 24 * 60 * 60)
        _ = await client().sectionOrder(forList: "list-a")
        XCTAssertEqual(catalogRequestCount(), 2, "a cache entry past its 7-day TTL must not be trusted")
    }

    func testWithinTheTTLItDoesNotRefetch() async {
        serveFixtures()

        _ = await client().sectionOrder(forList: "list-a")
        now = now.addingTimeInterval(6 * 24 * 60 * 60)
        _ = await client().sectionOrder(forList: "list-a")
        XCTAssertEqual(catalogRequestCount(), 1)
    }

    func testClearCacheForcesARefetch() async {
        serveFixtures()

        let first = client()
        _ = await first.sectionOrder(forList: "list-a")
        XCTAssertEqual(catalogRequestCount(), 1)

        await first.clearCache()
        _ = await first.sectionOrder(forList: "list-a")
        XCTAssertEqual(catalogRequestCount(), 2, "clearCache() must wipe both the memory and disk cache")
    }

    /// The one case this whole cache exists to fix: a locale Bring! publishes no catalogue for must
    /// not keep costing a wasted request every launch.
    func testA404LocaleIsRememberedAsNoCatalogueAndNotReRequested() async {
        serveFixtures(catalogStatus: 404)

        let items = await client().articles(for: ["Apfel"], inList: "list-a")
        XCTAssertEqual(items["Apfel"]?.displayName, "Apfel", "falls back to the canonical name")
        XCTAssertEqual(catalogRequestCount(), 1)

        // A fresh client, disk cache shared: the remembered 404 must still be honored.
        _ = await client().articles(for: ["Apfel"], inList: "list-a")
        XCTAssertEqual(catalogRequestCount(), 1, "a remembered 404 must not be re-requested within the TTL")
    }

    /// A corrupted cache file — a partial write, a format change, anything unreadable — must be a
    /// cache miss, never an error: this type's whole contract is that a catalogue problem costs an
    /// odd item name, never a failed sync.
    func testCorruptCachedDataFallsBackToTheNetworkRatherThanFailing() async {
        serveFixtures()

        _ = await client().sectionOrder(forList: "list-a")
        XCTAssertEqual(catalogRequestCount(), 1)

        catalogStore.corrupt(locale: "de-DE")
        let order = await client().sectionOrder(forList: "list-a")
        XCTAssertEqual(catalogRequestCount(), 2, "a corrupt cache entry must fall back to a network fetch")
        XCTAssertEqual(order, ["Fruit"], "and the re-fetch must succeed and return real data")
    }

    /// A successful network fetch writes through to disk, so the entry a later launch reads back is
    /// actually usable — not just present.
    func testASuccessfulFetchWritesThroughToDisk() async {
        serveFixtures()
        _ = await client().sectionOrder(forList: "list-a")

        let entry = catalogStore.load(locale: "de-DE")
        XCTAssertNotNil(entry?.body)
        XCTAssertEqual(entry?.fetchedAt, now)
    }
}
