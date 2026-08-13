import Foundation

/// Which backend a list or item came from.
///
/// Encoded as a bare string rather than a wrapper object, because it is half of every
/// `ProviderMapping` key and those are persisted — a readable `"reminders/ABC-123"` in the stored
/// JSON is worth the dozen lines of `Codable` conformance below.
///
/// One id per provider *kind*, not per account: Todo2Ink deliberately supports a single account per
/// backend. Multiple accounts of one kind would need an instance component here (`"bring:<uuid>"`)
/// and a persisted-format migration, which is the reason this is called out rather than left to be
/// discovered later.
struct ProviderId: Hashable, Codable, RawRepresentable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { rawValue }

    static let reminders = ProviderId(rawValue: "reminders")
    static let bring = ProviderId(rawValue: "bring")
}

/// One list as a provider exposes it — deliberately smaller than any backend's own list type. The
/// picker and the ordering UI never need more than an id and something to draw.
struct ProviderList: Identifiable, Equatable {
    /// The backend's own id for this list (`EKCalendar.calendarIdentifier`, a Bring `listUuid`, …).
    /// Opaque to everything outside the provider that minted it; `ProviderMapping` is what turns it
    /// into the wire's `UInt16`.
    let id: String
    let title: String
}

/// One task as a provider exposes it, still keyed by the backend's own id.
///
/// Note this has no wire `itemId`: providers stay ignorant of the wire entirely, the same
/// separation `RemindersService` already keeps from CompanionKit. `ProviderMapping` is the only
/// thing that mints `UInt16`s.
struct ProviderItem: Equatable {
    let id: String
    let text: String
    let checked: Bool
}

/// Whether a provider is usable, and if not, whose problem it is.
///
/// `notConfigured` and `failed` are different on purpose: the first means the user has not finished
/// setting the provider up (no Bring login yet) and the UI should offer a way to; the second means
/// they did and it stopped working (revoked Reminders access, expired credentials), which needs a
/// different sentence and sometimes a different button.
enum ProviderAuthState: Equatable {
    case notConfigured
    case authorized
    case failed(String)
}

/// The seam every sync backend implements. Apple Reminders and Bring! are two equal conformances of
/// this, not "Reminders plus a special case" — `TodoSyncEngine` never branches on which is which.
///
/// Async throughout even though Reminders is local and can't really fail at the network layer,
/// because the alternative is two shapes of provider and a sync engine that knows the difference.
/// A local provider just resolves immediately.
///
/// `@MainActor` matches the rest of the app (`AppModel`, `TodoSyncEngine`, `RemindersService` are
/// all main-actor already); a provider that does real network work is expected to hop off it
/// internally, not to change this annotation.
@MainActor
protocol TodoProvider: AnyObject {
    var id: ProviderId { get }

    /// Shown in the provider list and prefixed to this provider's lists in the reader-order preview.
    var displayName: String { get }

    /// One sentence for the provider row when something needs the user's attention. `nil` when the
    /// provider is working and has nothing to say.
    var statusDescription: String? { get }

    var authState: ProviderAuthState { get }

    /// Obtains or re-checks whatever this provider needs to work — an EventKit permission prompt, a
    /// stored-credential validation. Safe to call repeatedly; providers report existing access
    /// rather than re-prompting.
    func requestAccess() async throws -> Bool

    func fetchLists() async throws -> [ProviderList]

    /// Every item in each requested list, keyed by list id. Lists the backend no longer has are
    /// simply absent from the result rather than erroring — a list deleted server-side is a normal
    /// event, and `TodoSyncEngine` prunes on that basis.
    func fetchItems(listIds: [String]) async throws -> [String: [ProviderItem]]

    /// Writes a completion state back after a device-side check-off. An item that no longer exists
    /// is a no-op, not an error — the same tolerance `RemindersService.setCompleted` already has,
    /// and the shape `TodoDocument.mergingDeviceDeviations` expects.
    func setCompleted(_ completed: Bool, forItemId itemId: String) async throws
}
