import Foundation

/// The wire types of Bring!'s unofficial REST API, and the constants every request needs.
///
/// Bring! publishes no API and no documentation. Everything here was taken from the behaviour of
/// the public Python client `miaucl/bring-api` (which Home Assistant ships as a first-party
/// integration), not from Bring! themselves — so treat each field name as an observation that can
/// stop being true, and prefer failing with `BringError.malformedResponse` over guessing.
enum BringAPI {
    static let baseURL = URL(string: "https://api.getbring.com/rest/")!

    /// The single API key Bring!'s own Android app ships with, and which every public client reuses.
    /// It is not a secret and not per-user — it identifies "a Bring client" and nothing more — so it
    /// belongs in source rather than in the Keychain next to the user's actual credentials.
    static let apiKey = "cof4Nc6D8saplXjE3h3HXqHH8m7VU2i1Gs0g85Sp"

    static let clientHeader = "android"
    static let applicationHeader = "bring"

    /// Bring! segments some behaviour by country. The user's own region is the honest answer; `DE`
    /// is the fallback the public clients use and the service accepts.
    static var country: String {
        Locale.current.region?.identifier ?? "DE"
    }

    /// What a change to an item means. These four strings are the wire vocabulary — note that
    /// un-checking an item is `toPurchase`, there is no separate "uncomplete" operation, and that
    /// `remove` is deliberately never sent by this app (Todo2Ink syncs completion state, never
    /// deletions).
    enum Operation: String, Encodable {
        case toPurchase = "TO_PURCHASE"
        case toRecently = "TO_RECENTLY"
        case remove = "REMOVE"
    }
}

// MARK: - Authentication

/// `POST v2/bringauth` and `POST v2/bringauth/token`. Both are **form-encoded**, unlike everything
/// else here, and both answer with this.
struct BringAuthResponse: Decodable {
    let uuid: String?
    let publicUuid: String?
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case uuid
        case publicUuid
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

// MARK: - Lists

/// `GET bringusers/{uuid}/lists`.
struct BringListsResponse: Decodable {
    struct List: Decodable {
        let listUuid: String
        let name: String
    }

    let lists: [List]
}

/// One entry in a list's `purchase` or `recently` array.
///
/// `itemId` is Bring!'s own identifier and it is the item's *display name* — "Milk", not a uuid.
/// That is not a mistake in this client: Bring! keys items by name within a list, which is why
/// mutations send the name back rather than an opaque handle. `specification` is the free-text note
/// the user attaches ("2 litres"), and it is what the mutation payload calls `spec`.
struct BringItem: Decodable, Equatable {
    let itemId: String
    let specification: String
    let uuid: String?

    enum CodingKeys: String, CodingKey {
        case itemId
        case specification
        case spec
        case uuid
    }

    init(itemId: String, specification: String = "", uuid: String? = nil) {
        self.itemId = itemId
        self.specification = specification
        self.uuid = uuid
    }

    /// Hand-written because the note arrives as `specification` when reading and `spec` when
    /// writing, and the two have been observed on the read path at different times.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemId = try container.decode(String.self, forKey: .itemId)
        specification = try container.decodeIfPresent(String.self, forKey: .specification)
            ?? container.decodeIfPresent(String.self, forKey: .spec)
            ?? ""
        uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
    }
}

/// `GET v2/bringlists/{listUuid}`.
///
/// `purchase` is the shopping list proper — things still to buy. `recently` is what was bought
/// lately, which is Bring!'s equivalent of a completed item; it is a rolling window Bring! trims
/// itself, not a full history.
///
/// Two shapes are accepted because the service returns both: the arrays nested under an `items`
/// envelope (`{"uuid":…,"status":…,"items":{"purchase":[…],"recently":[…]}}`), and flat at the top
/// level. The nested one is what a real account answered with; the flat one is what older clients
/// document. Accepting both is not defensive padding — it is the difference between this working
/// through a server-side rollout and failing halfway through one.
struct BringListContentResponse: Decodable {
    let purchase: [BringItem]
    let recently: [BringItem]

    private struct Items: Decodable {
        let purchase: [BringItem]?
        let recently: [BringItem]?
    }

    enum CodingKeys: String, CodingKey {
        case purchase
        case recently
        case items
    }

    init(purchase: [BringItem], recently: [BringItem]) {
        self.purchase = purchase
        self.recently = recently
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let nested = try container.decodeIfPresent(Items.self, forKey: .items) {
            purchase = nested.purchase ?? []
            recently = nested.recently ?? []
            return
        }

        // A body with neither shape is a third shape, and must fail rather than decode to an empty
        // list — "your shopping list is empty" is a much worse lie than an error message.
        guard container.contains(.purchase) || container.contains(.recently) else {
            throw DecodingError.keyNotFound(CodingKeys.items, DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "no items, purchase or recently key"
            ))
        }
        purchase = try container.decodeIfPresent([BringItem].self, forKey: .purchase) ?? []
        recently = try container.decodeIfPresent([BringItem].self, forKey: .recently) ?? []
    }
}

/// One entry of `GET bringlists/{listUuid}/details` — per-item overrides the list-contents endpoint
/// doesn't carry, `userSectionId` chief among them: the section the user explicitly assigned an
/// item to, which wins over whatever the article catalogue would otherwise say.
///
/// This endpoint is not documented by `miaucl/bring-api` at the time of writing, so the vocabulary
/// of `userSectionId` (a canonical section id? a uuid? a localized name?) is unconfirmed — see
/// `BringProvider` for how that gets logged rather than assumed. Every field but `itemId` is
/// optional, so an endpoint that adds, renames or omits a field this client doesn't read never
/// fails the decode.
struct BringItemDetails: Decodable {
    let itemId: String
    let userSectionId: String?
}

/// `GET bringlists/{listUuid}/details`. The envelope is as unconfirmed as the field vocabulary
/// above, so — following `BringListContentResponse`'s precedent — two shapes are accepted: a bare
/// top-level array, and an object wrapping the array under a plausible key (`details`, mirroring
/// how `BringListContentResponse` nests under `items`). A third shape must still fail rather than
/// decode to empty: silently losing every override would read as "the user never assigned a
/// section", which is a worse lie than an error.
struct BringItemDetailsResponse: Decodable {
    let details: [BringItemDetails]

    private struct Wrapper: Decodable {
        let details: [BringItemDetails]?
    }

    init(details: [BringItemDetails]) {
        self.details = details
    }

    init(from decoder: Decoder) throws {
        if let array = try? [BringItemDetails](from: decoder) {
            details = array
            return
        }
        if let wrapper = try? Wrapper(from: decoder), let wrapped = wrapper.details {
            details = wrapped
            return
        }
        throw DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "neither a bare array nor an object with a details key"
        ))
    }
}

// MARK: - Settings

/// `GET bringusersettings/{userUuid}` — settings for the account *and* for every one of its lists at
/// once, as loosely-typed key/value pairs.
///
/// `listArticleLanguage` picks the catalogue a list's items are named from; `listSectionOrder` is
/// Bring!'s own section order for that list, holding a JSON array encoded inside a string (exact
/// shape unconfirmed — `BringCatalogClient` parses it defensively and falls back to the catalogue's
/// own order if it can't).
struct BringUserSettingsResponse: Decodable {
    struct Entry: Decodable {
        let key: String
        let value: String
    }

    struct ListSettings: Decodable {
        let listUuid: String
        let usersettings: [Entry]
    }

    let usersettings: [Entry]?
    let userlistsettings: [ListSettings]?
}

// MARK: - Catalogue

/// `GET https://web.getbring.com/locale/catalog.{locale}.json` — the full per-locale article
/// catalogue: every section Bring! groups items into, and each item's canonical and localized name.
///
/// Supersedes the flat `articles.{locale}.json` map this client used to fetch: the two agree on
/// every display name (verified against all ~362 entries in the de-DE catalogue), and the catalogue
/// additionally carries the section each item defaults into, which `articles.json` does not.
struct BringCatalogResponse: Decodable {
    struct Item: Decodable {
        let itemId: String
        let name: String
    }

    /// `sectionId` is the canonical (de-CH) section name and is stable across locales; `name` is
    /// this locale's localized one.
    struct Section: Decodable {
        let sectionId: String
        let name: String
        let items: [Item]
    }

    struct Catalog: Decodable {
        let sections: [Section]
    }

    let catalog: Catalog
}

// MARK: - Mutations

/// `PUT v2/bringlists/{listUuid}/items`.
///
/// Always a batch envelope even for a single change, and every change carries four geo fields the
/// server requires but this app has nothing to say about — it sends the zeroes the public clients
/// send. `sender` is likewise required and empty.
struct BringChangeRequest: Encodable {
    struct Change: Encodable {
        let accuracy = "0.0"
        let altitude = "0.0"
        let latitude = "0.0"
        let longitude = "0.0"
        let itemId: String
        let spec: String
        let uuid: String?
        let operation: BringAPI.Operation
    }

    let changes: [Change]
    let sender = ""
}
