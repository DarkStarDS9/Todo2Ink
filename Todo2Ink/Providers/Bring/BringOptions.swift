import Foundation

/// The user-facing choices Bring! needs and Reminders doesn't.
///
/// They exist because Bring!'s "recently bought" has no equivalent in a to-do list. It is not
/// history — it is the only place a bought item still exists, so leaving it out means checking
/// something off on the reader makes it vanish at the next sync with no way to undo. Showing it
/// keeps the item around, at the cost of list space on a small screen. Neither is obviously right,
/// so it's a setting.
struct BringOptions: Codable, Equatable {
    /// Show recently-bought items, checked, below the ones still to buy.
    var showsRecentlyPurchased: Bool

    /// How many of them. Bring! trims `recently` itself, but not to a length that suits an e-ink
    /// screen, and every list shares one 16 KB document budget.
    var recentlyPurchasedLimit: Int

    static let `default` = BringOptions(showsRecentlyPurchased: true, recentlyPurchasedLimit: 10)

    static let limitRange = 0...50
}

/// Persistence for `BringOptions`. Plain `UserDefaults` — unlike the session, there is nothing
/// sensitive here.
extension BringOptions {
    private static let defaultsKey = "Todo2Ink.bringOptions.v1"

    static func load(from defaults: UserDefaults) -> BringOptions {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(BringOptions.self, from: data)
        else { return .default }
        return decoded
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
