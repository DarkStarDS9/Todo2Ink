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
struct BringListContentResponse: Decodable {
    let purchase: [BringItem]
    let recently: [BringItem]
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
