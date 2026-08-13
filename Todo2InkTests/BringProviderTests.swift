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
            // An in-memory catalogue store, not the real disk default: these tests serve the same
            // locale (de-DE) with different fixtures from test to test, and the real Caches directory
            // would let one test's catalogue leak into another's — or into a run days later, inside
            // the 7-day TTL.
            catalog: BringCatalogClient(http: http, auth: auth, store: InMemoryBringCatalogStore()),
            defaults: defaults
        )
        provider.options = options
        return provider
    }

    /// Serves the article catalogue and the settings that point at it, on top of the list fixtures.
    /// The de-CH (base-locale) catalogue is served too — it now carries the section data — but empty,
    /// since these tests aren't concerned with sections.
    private func serveLocalizedFixtures() {
        FakeBringServer.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("catalog.de-DE.json") {
                return .ok(BringFixtures.catalog(language: "de-DE", sections: [
                    (id: "Snacks & Süsswaren", name: "Snacks & Süssigkeiten",
                     items: [(itemId: "Pommes Chips", name: "Chips")]),
                ]))
            }
            if path.hasSuffix("catalog.de-CH.json") {
                return .ok(BringFixtures.catalog(language: "de-CH", sections: []))
            }
            if path.hasPrefix("/rest/bringusersettings") {
                return .ok("""
                {"usersettings": [], "userlistsettings": [
                  {"listUuid": "list-a", "usersettings": [
                    {"key": "listArticleLanguage", "value": "de-DE"}
                  ]}
                ]}
                """)
            }
            if path.hasPrefix("/rest/bringusers/") && !path.hasSuffix("/lists") {
                return .ok("{\"userLocale\": \"de-CH\"}")
            }
            if path.hasSuffix("/lists") { return .ok(BringFixtures.lists) }
            if path.hasSuffix("/items") { return .ok("{}") }
            return .ok("""
            {"items": {"purchase": [
              {"uuid": "item-1", "itemId": "Pommes Chips", "specification": ""}
            ], "recently": []}}
            """)
        }
    }

    /// Bring! keys items by a canonical name and shows a localized one — a list displaying "Chips"
    /// comes back over the wire as "Pommes Chips".
    func testItemNamesAreLocalizedForDisplay() async throws {
        serveLocalizedFixtures()
        let items = try await provider().fetchItems(listIds: ["list-a"])["list-a"]
        XCTAssertEqual(items?.map(\.text), ["Chips"])
    }

    /// The localized name is for the screen only. Writing one back would fail for exactly the items
    /// this translation exists for, so the id — and the change payload — stay canonical.
    func testWriteBackStillUsesTheCanonicalName() async throws {
        serveLocalizedFixtures()
        let provider = self.provider()
        let items = try await provider.fetchItems(listIds: ["list-a"])["list-a"]
        XCTAssertEqual(items?.first?.id, "list-a/Pommes Chips")

        try await provider.setCompleted(true, forItemId: "list-a/Pommes Chips")
        let changes = try XCTUnwrap(FakeBringServer.lastBodyJSON?["changes"] as? [[String: Any]])
        XCTAssertEqual(changes[0]["itemId"] as? String, "Pommes Chips")
    }

    /// An unreachable or unsupported catalogue must cost an odd-looking name, never a failed sync.
    func testAMissingCatalogueFallsBackToCanonicalNames() async throws {
        FakeBringServer.handler = { request in
            let path = request.url?.path ?? ""
            if path.contains("catalog.") { return .status(404) }
            if path.hasPrefix("/rest/bringusersettings") {
                return .ok("""
                {"userlistsettings": [{"listUuid": "list-a", "usersettings": [
                  {"key": "listArticleLanguage", "value": "de-DE"}
                ]}]}
                """)
            }
            if path.hasPrefix("/rest/bringusers/") && !path.hasSuffix("/lists") {
                return .ok("{}")
            }
            return .ok(BringFixtures.listContents)
        }

        let items = try await provider().fetchItems(listIds: ["list-a"])["list-a"]
        XCTAssertEqual(items?.map(\.text), ["Milch (2 Liter)", "Brot", "Butter"])
    }

    /// `ProviderItem.section` is the canonical `sectionId` — the same string the group label on the
    /// device shows and `sectionOrder` orders by.
    func testDisplayNameAndSectionAreResolvedFromCatalogue() async throws {
        serveLocalizedFixtures()
        let items = try await provider().fetchItems(listIds: ["list-a"])["list-a"]
        XCTAssertEqual(items?.first?.text, "Chips")
        XCTAssertEqual(
            items?.first?.section, "Snacks & Süssigkeiten",
            "the section is grouped by the canonical id but shown by the locale's own name for it"
        )
    }

    /// `sectionId` is canonical and locale-independent, so a list whose locale has no catalogue of
    /// its own (a 404) still gets grouped, using the base (de-CH) catalogue's section assignment —
    /// with the item's name left canonical, since there is no localized one to use.
    func testAnUnsupportedLocaleFallsBackToBaseCatalogueSectionsWithCanonicalNames() async throws {
        FakeBringServer.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("catalog.en-DE.json") { return .status(404) }
            if path.hasSuffix("catalog.de-CH.json") {
                return .ok(BringFixtures.catalog(language: "de-CH", sections: [
                    (id: "Fruit", name: "Fruit", items: [(itemId: "Apple", name: "Apple")]),
                ]))
            }
            if path.hasPrefix("/rest/bringusersettings") {
                return .ok("""
                {"userlistsettings": [{"listUuid": "list-a", "usersettings": [
                  {"key": "listArticleLanguage", "value": "en-DE"}
                ]}]}
                """)
            }
            if path.hasPrefix("/rest/bringusers/") && !path.hasSuffix("/lists") { return .ok("{}") }
            if path.hasSuffix("/lists") { return .ok(BringFixtures.lists) }
            return .ok("""
            {"items": {"purchase": [
              {"uuid": "item-1", "itemId": "Apple", "specification": ""}
            ], "recently": []}}
            """)
        }

        let items = try await provider().fetchItems(listIds: ["list-a"])["list-a"]
        XCTAssertEqual(items?.first?.text, "Apple", "no catalogue in the list's own locale, so the name stays canonical")
        XCTAssertEqual(items?.first?.section, "Fruit", "the base catalogue still supplies a correct section")
    }

    /// A canonical name the catalogue has never heard of degrades to its own name and no section,
    /// same as a missing catalogue would — never a failed sync.
    func testAnItemAbsentFromTheCatalogueGetsNilSectionAndItsOwnName() async throws {
        FakeBringServer.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("catalog.de-DE.json") {
                return .ok(BringFixtures.catalog(language: "de-DE", sections: [
                    (id: "Fruit", name: "Obst", items: [(itemId: "Apfel", name: "Apfel")]),
                ]))
            }
            if path.hasSuffix("catalog.de-CH.json") {
                return .ok(BringFixtures.catalog(language: "de-CH", sections: []))
            }
            if path.hasPrefix("/rest/bringusersettings") {
                return .ok("""
                {"userlistsettings": [{"listUuid": "list-a", "usersettings": [
                  {"key": "listArticleLanguage", "value": "de-DE"}
                ]}]}
                """)
            }
            if path.hasPrefix("/rest/bringusers/") && !path.hasSuffix("/lists") { return .ok("{}") }
            if path.hasSuffix("/lists") { return .ok(BringFixtures.lists) }
            return .ok("""
            {"items": {"purchase": [
              {"uuid": "item-1", "itemId": "Mysteriöses Ding", "specification": ""}
            ], "recently": []}}
            """)
        }

        let items = try await provider().fetchItems(listIds: ["list-a"])["list-a"]
        XCTAssertEqual(items?.first?.text, "Mysteriöses Ding")
        XCTAssertNil(items?.first?.section)
    }

    /// Purchase items are ordered by the list's section order (here, the catalogue's own order, since
    /// no `listSectionOrder` setting is served) rather than the order Bring! happened to return them.
    func testPurchaseItemsAreOrderedBySectionOrder() async throws {
        FakeBringServer.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("catalog.de-DE.json") {
                return .ok(BringFixtures.catalog(language: "de-DE", sections: [
                    (id: "Dairy", name: "Milchprodukte", items: [(itemId: "Milch", name: "Milch")]),
                    (id: "Fruit", name: "Obst", items: [(itemId: "Apfel", name: "Apfel")]),
                ]))
            }
            if path.hasSuffix("catalog.de-CH.json") {
                return .ok(BringFixtures.catalog(language: "de-CH", sections: []))
            }
            if path.hasPrefix("/rest/bringusersettings") {
                return .ok("""
                {"userlistsettings": [{"listUuid": "list-a", "usersettings": [
                  {"key": "listArticleLanguage", "value": "de-DE"}
                ]}]}
                """)
            }
            if path.hasPrefix("/rest/bringusers/") && !path.hasSuffix("/lists") { return .ok("{}") }
            if path.hasSuffix("/lists") { return .ok(BringFixtures.lists) }
            return .ok("""
            {"items": {"purchase": [
              {"uuid": "item-1", "itemId": "Apfel", "specification": ""},
              {"uuid": "item-2", "itemId": "Milch", "specification": ""}
            ], "recently": []}}
            """)
        }

        let items = try await provider().fetchItems(listIds: ["list-a"])["list-a"]
        XCTAssertEqual(
            items?.map(\.text), ["Milch", "Apfel"],
            "purchase items follow the catalogue's own section order, not the wire order"
        )
    }

    /// Recently-bought items are always unsectioned — Bring!'s purchase/recently split is a
    /// completion state, not a grouping — even when the catalogue has a section for them, so they
    /// land in the trailing ungrouped group `TodoDocumentBuilder` sorts last.
    func testRecentlyItemsAreUnsectionedAndLast() async throws {
        FakeBringServer.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("catalog.de-DE.json") {
                return .ok(BringFixtures.catalog(language: "de-DE", sections: [
                    (id: "Fruit", name: "Obst",
                     items: [(itemId: "Apfel", name: "Apfel"), (itemId: "Birne", name: "Birne")]),
                ]))
            }
            if path.hasSuffix("catalog.de-CH.json") {
                return .ok(BringFixtures.catalog(language: "de-CH", sections: []))
            }
            if path.hasPrefix("/rest/bringusersettings") {
                return .ok("""
                {"userlistsettings": [{"listUuid": "list-a", "usersettings": [
                  {"key": "listArticleLanguage", "value": "de-DE"}
                ]}]}
                """)
            }
            if path.hasPrefix("/rest/bringusers/") && !path.hasSuffix("/lists") { return .ok("{}") }
            if path.hasSuffix("/lists") { return .ok(BringFixtures.lists) }
            return .ok("""
            {"items": {"purchase": [
              {"uuid": "item-1", "itemId": "Apfel", "specification": ""}
            ], "recently": [
              {"uuid": "item-2", "itemId": "Birne", "specification": ""}
            ]}}
            """)
        }

        let items = try await provider().fetchItems(listIds: ["list-a"])["list-a"]
        XCTAssertEqual(items?.map(\.text), ["Apfel", "Birne"])
        XCTAssertEqual(
            items?.map(\.section), ["Obst", nil],
            "recently-bought items are always unsectioned, even though the catalogue has a section for them"
        )
    }

    /// An item Bring!'s catalogue has never heard of is one the user typed themselves, and Bring!
    /// files those under a section of its own — named by `listSectionOrder` and absent from the
    /// catalogue. A list of mostly hand-typed items is the normal case, so getting this wrong turns
    /// the whole list into one nameless run.
    func testItemsAbsentFromTheCatalogueGoIntoTheOwnArticlesSection() async throws {
        FakeBringServer.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("catalog.de-DE.json") {
                return .ok(BringFixtures.catalog(language: "de-DE", sections: [
                    (id: "Brot & Gebäck", name: "Brot & Gebäck",
                     items: [(itemId: "Brot", name: "Brot")]),
                ]))
            }
            if path.hasSuffix("catalog.de-CH.json") {
                return .ok(BringFixtures.catalog(language: "de-CH", sections: []))
            }
            if path.hasPrefix("/rest/bringusersettings") {
                return .ok("""
                {"userlistsettings": [{"listUuid": "list-a", "usersettings": [
                  {"key": "listArticleLanguage", "value": "de-DE"},
                  {"key": "listSectionOrder", "value": "[\\"Brot & Gebäck\\",\\"Eigene Artikel\\"]"}
                ]}]}
                """)
            }
            if path.hasPrefix("/rest/bringusers/") && !path.hasSuffix("/lists") { return .ok("{}") }
            if path.hasSuffix("/lists") { return .ok(BringFixtures.lists) }
            return .ok("""
            {"items": {"purchase": [
              {"uuid": "item-1", "itemId": "Topfenschnitte", "specification": ""},
              {"uuid": "item-2", "itemId": "Brot", "specification": ""}
            ], "recently": []}}
            """)
        }

        let items = try await provider().fetchItems(listIds: ["list-a"])["list-a"]
        XCTAssertEqual(
            items?.map(\.text), ["Brot", "Topfenschnitte"],
            "own articles come last because that is where listSectionOrder puts their section"
        )
        XCTAssertEqual(
            items?.map(\.section), ["Brot & Gebäck", "Eigene Artikel"],
            "the own-articles section is taken from the user's own settings, not hardcoded"
        )
    }

    // MARK: - userSectionId (bringlists/{listUuid}/details)

    /// The user's own explicit assignment (`userSectionId`) wins over whatever the catalogue would
    /// otherwise say for the same item.
    func testUserSectionIdOverridesTheCatalogueSection() async throws {
        FakeBringServer.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("catalog.de-DE.json") {
                return .ok(BringFixtures.catalog(language: "de-DE", sections: [
                    (id: "Fruit", name: "Obst", items: [(itemId: "Apfel", name: "Apfel")]),
                ]))
            }
            if path.hasSuffix("catalog.de-CH.json") {
                return .ok(BringFixtures.catalog(language: "de-CH", sections: []))
            }
            if path.hasPrefix("/rest/bringusersettings") {
                return .ok("""
                {"userlistsettings": [{"listUuid": "list-a", "usersettings": [
                  {"key": "listArticleLanguage", "value": "de-DE"}
                ]}]}
                """)
            }
            if path.hasPrefix("/rest/bringusers/") && !path.hasSuffix("/lists") { return .ok("{}") }
            if path.hasSuffix("/lists") { return .ok(BringFixtures.lists) }
            if path.hasSuffix("/details") {
                return .ok(BringFixtures.details([(itemId: "Apfel", userSectionId: "Getränke & Tabak")]))
            }
            return .ok("""
            {"items": {"purchase": [
              {"uuid": "item-1", "itemId": "Apfel", "specification": ""}
            ], "recently": []}}
            """)
        }

        let items = try await provider().fetchItems(listIds: ["list-a"])["list-a"]
        XCTAssertEqual(
            items?.first?.section, "Getränke & Tabak",
            "the user's own assignment wins over the catalogue's default (Fruit)"
        )
    }

    /// `userSectionId` supplies a section for an item the catalogue has never heard of — the exact
    /// case the screenshot that motivated this (Sprite, Tee Earl Grey, …) showed.
    func testUserSectionIdSuppliesASectionForAnItemTheCatalogueDoesNotKnow() async throws {
        FakeBringServer.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("catalog.de-DE.json") {
                return .ok(BringFixtures.catalog(language: "de-DE", sections: []))
            }
            if path.hasSuffix("catalog.de-CH.json") {
                return .ok(BringFixtures.catalog(language: "de-CH", sections: []))
            }
            if path.hasPrefix("/rest/bringusersettings") {
                return .ok("""
                {"userlistsettings": [{"listUuid": "list-a", "usersettings": [
                  {"key": "listArticleLanguage", "value": "de-DE"}
                ]}]}
                """)
            }
            if path.hasPrefix("/rest/bringusers/") && !path.hasSuffix("/lists") { return .ok("{}") }
            if path.hasSuffix("/lists") { return .ok(BringFixtures.lists) }
            if path.hasSuffix("/details") {
                return .ok(BringFixtures.details([(itemId: "Sprite", userSectionId: "Getränke & Tabak")]))
            }
            return .ok("""
            {"items": {"purchase": [
              {"uuid": "item-1", "itemId": "Sprite", "specification": ""}
            ], "recently": []}}
            """)
        }

        let items = try await provider().fetchItems(listIds: ["list-a"])["list-a"]
        XCTAssertEqual(items?.first?.text, "Sprite")
        XCTAssertEqual(items?.first?.section, "Getränke & Tabak")
    }

    /// The `/details` call is a nicety, not load-bearing: a 500 from it must not sink the sync, and
    /// the rest of the list still groups by the catalogue as before.
    func testAFailingDetailsCallLeavesCatalogueSectionsIntact() async throws {
        FakeBringServer.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("catalog.de-DE.json") {
                return .ok(BringFixtures.catalog(language: "de-DE", sections: [
                    (id: "Fruit", name: "Obst", items: [(itemId: "Apfel", name: "Apfel")]),
                ]))
            }
            if path.hasSuffix("catalog.de-CH.json") {
                return .ok(BringFixtures.catalog(language: "de-CH", sections: []))
            }
            if path.hasPrefix("/rest/bringusersettings") {
                return .ok("""
                {"userlistsettings": [{"listUuid": "list-a", "usersettings": [
                  {"key": "listArticleLanguage", "value": "de-DE"}
                ]}]}
                """)
            }
            if path.hasPrefix("/rest/bringusers/") && !path.hasSuffix("/lists") { return .ok("{}") }
            if path.hasSuffix("/lists") { return .ok(BringFixtures.lists) }
            if path.hasSuffix("/details") { return .status(500) }
            return .ok("""
            {"items": {"purchase": [
              {"uuid": "item-1", "itemId": "Apfel", "specification": ""}
            ], "recently": []}}
            """)
        }

        let items = try await provider().fetchItems(listIds: ["list-a"])["list-a"]
        XCTAssertEqual(items?.first?.text, "Apfel")
        XCTAssertEqual(
            items?.first?.section, "Obst",
            "a failing /details call falls back to the catalogue's own section (shown by its "
                + "localized label) rather than failing the whole sync"
        )
    }

    /// Both envelope shapes `BringItemDetailsResponse` accepts must decode: a bare top-level array,
    /// and an object wrapping the array under `details`.
    func testBothDetailsEnvelopeShapesDecode() async throws {
        for wrapped in [false, true] {
            FakeBringServer.handler = { request in
                let path = request.url?.path ?? ""
                if path.hasSuffix("catalog.de-DE.json") {
                    return .ok(BringFixtures.catalog(language: "de-DE", sections: []))
                }
                if path.hasSuffix("catalog.de-CH.json") {
                    return .ok(BringFixtures.catalog(language: "de-CH", sections: []))
                }
                if path.hasPrefix("/rest/bringusersettings") {
                    return .ok("""
                    {"userlistsettings": [{"listUuid": "list-a", "usersettings": [
                      {"key": "listArticleLanguage", "value": "de-DE"}
                    ]}]}
                    """)
                }
                if path.hasPrefix("/rest/bringusers/") && !path.hasSuffix("/lists") { return .ok("{}") }
                if path.hasSuffix("/lists") { return .ok(BringFixtures.lists) }
                if path.hasSuffix("/details") {
                    let array = BringFixtures.details([(itemId: "Apfel", userSectionId: "Obst")])
                    return .ok(wrapped ? "{\"details\": \(array)}" : array)
                }
                return .ok("""
                {"items": {"purchase": [
                  {"uuid": "item-1", "itemId": "Apfel", "specification": ""}
                ], "recently": []}}
                """)
            }

            let items = try await provider().fetchItems(listIds: ["list-a"])["list-a"]
            XCTAssertEqual(items?.first?.section, "Obst", "wrapped=\(wrapped)")
        }
    }

    private func serveFixtures() {
        FakeBringServer.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/lists") { return .ok(BringFixtures.lists) }
            if path.hasSuffix("/items") { return .ok("{}") }
            return .ok(BringFixtures.listContents)
        }
    }

    /// The shape a real account returned, which the first TestFlight build failed to decode: the
    /// two arrays nested under `items` rather than at the top level.
    func testListContentsNestedUnderItemsAreDecoded() async throws {
        serveFixtures()
        let items = try await provider().fetchItems(listIds: ["list-a"])["list-a"]
        XCTAssertEqual(items?.map(\.text), ["Milch (2 Liter)", "Brot", "Butter"])
    }

    func testTheFlatListContentsShapeIsStillAccepted() async throws {
        FakeBringServer.handler = { _ in .ok(BringFixtures.flatListContents) }
        let items = try await provider().fetchItems(listIds: ["list-a"])["list-a"]
        XCTAssertEqual(items?.map(\.text), ["Milch (2 Liter)", "Brot", "Butter"])
    }

    /// A third shape must fail loudly. Decoding it to an empty list would tell the user their
    /// shopping list is empty, which is a far worse lie than an error.
    func testAnUnknownListContentsShapeFailsRatherThanReadingAsEmpty() async {
        FakeBringServer.handler = { _ in .ok("{\"uuid\":\"list-a\",\"entries\":[]}") }
        do {
            _ = try await provider().fetchItems(listIds: ["list-a"])
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? BringError, .malformedResponse("BringListContentResponse"))
        }
    }

    /// The whole point of logging a shape rather than a body is that a field-name change ("what
    /// does Bring call the item id now?") is diagnosable from the field without ever putting a
    /// user's shopping list in a log file. That only holds if the array elements' own keys are
    /// revealed too — `purchase` and `recently` are arrays of item objects, and it's exactly those
    /// item objects' field names (`itemId`, `specification`, `uuid`) that a decode failure needs to
    /// show.
    func testTheLoggedResponseShapeCarriesKeysButNoValues() {
        let shape = BringHTTP.shape(of: Data(BringFixtures.listContents.utf8))
        XCTAssertTrue(shape.contains("items{purchase[2{"), "array elements' keys must be revealed — got \(shape)")
        XCTAssertTrue(shape.contains("itemId"), "got \(shape)")
        XCTAssertTrue(shape.contains("specification"), "got \(shape)")
        XCTAssertTrue(shape.contains("[2"), "purchase's element count must appear — got \(shape)")
        XCTAssertTrue(shape.contains("[1"), "recently's element count must appear — got \(shape)")
        XCTAssertFalse(shape.contains("Milch"), "values must not be logged — got \(shape)")
        XCTAssertFalse(shape.contains("2 Liter"), "values must not be logged — got \(shape)")
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

    /// The reader's own check-off must reach Bring! even on the first sync of a session, when
    /// nothing has filled the item cache yet — `TodoSyncEngine` writes deviations back *before* it
    /// assembles the document, and the pull is owed from HELLO_OK, before any list has been read.
    /// Dropping the write here is what made a check-off come back undone at the next sync.
    func testCheckingOffWithoutAPriorFetchStillReachesBring() async throws {
        serveFixtures()
        // No fetchItems() first — exactly the state a freshly launched app is in.
        try await provider().setCompleted(true, forItemId: "list-a/Milch")

        let request = try XCTUnwrap(FakeBringServer.recorded.last).request
        XCTAssertEqual(request.httpMethod, "PUT")
        let changes = try XCTUnwrap(FakeBringServer.lastBodyJSON?["changes"] as? [[String: Any]])
        XCTAssertEqual(changes[0]["itemId"] as? String, "Milch")
        XCTAssertEqual(changes[0]["operation"] as? String, "TO_RECENTLY")
        XCTAssertEqual(changes[0]["spec"] as? String, "2 Liter",
                       "the note has to be recovered too, or writing back would erase it")
    }

    /// Bring! returns "recently bought" oldest-first; the reader should show it the way the Bring!
    /// app does. The limit is applied after the reversal, so it keeps the newest rather than the
    /// oldest — the part that would still be wrong if only the display order were fixed.
    func testRecentlyPurchasedIsNewestFirstAndTheLimitKeepsTheNewest() async throws {
        let recently = (1...5).map { "{\"uuid\":\"u\($0)\",\"itemId\":\"Item\($0)\",\"specification\":\"\"}" }
        FakeBringServer.handler = { _ in
            .ok("{\"items\":{\"purchase\":[],\"recently\":[\(recently.joined(separator: ","))]}}")
        }

        let options = BringOptions(showsRecentlyPurchased: true, recentlyPurchasedLimit: 3)
        let items = try await provider(options: options).fetchItems(listIds: ["list-a"])["list-a"]
        XCTAssertEqual(items?.map(\.text), ["Item5", "Item4", "Item3"])
    }

    /// An item Bring! genuinely no longer has is a no-op rather than an error. It may cost a lookup
    /// — a cache miss can't be told from a deleted item without asking — but it must never turn into
    /// a write against an item that isn't there.
    func testCheckingOffAnItemThatNoLongerExistsSendsNoWrite() async throws {
        serveFixtures()
        let provider = self.provider()
        _ = try await provider.fetchItems(listIds: ["list-a"])

        try await provider.setCompleted(true, forItemId: "list-a/Gone")
        XCTAssertFalse(
            FakeBringServer.recorded.contains { $0.request.httpMethod == "PUT" },
            "no change should have been written"
        )
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
