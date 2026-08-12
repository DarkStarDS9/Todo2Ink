import CompanionKit
import Foundation

/// Who Todo2Ink is to a companion display, and what it tells the device about itself.
///
/// The types here — `CompanionIdentity`, `UiDeclaration`, `CompanionAssetProvider` — come from
/// CompanionKit, which ships alongside the wire format it implements. This file is only Todo2Ink's
/// *configuration* of them; the encoding, tagging and handshake are the library's, and deliberately
/// not reimplemented here.
enum Todo2InkPeer {

    /// **Todo2Ink's permanent application id. Never change this value.**
    ///
    /// It is identical across every install and every version of the app, forever: it is what makes
    /// two phones running Todo2Ink group into one tile on the device's sleep screen, and changing it
    /// would orphan every existing pairing on every device in the world, with no way to clean them
    /// up — unpairing is on-device only, there is no protocol opcode for "forget me".
    ///
    /// Derived reproducibly rather than picked at random, matching how Snap2Ink and SpokenFeeds
    /// derive their own:
    ///
    /// ```
    /// uuid5(NAMESPACE_DNS, "app.todo2ink.reminders") == 06601C50-AB2E-5C2E-97D2-25BAEED7FBF0
    /// ```
    ///
    /// Anyone can regenerate it from the app's reverse-DNS name and confirm it, which a magic
    /// constant does not allow. The firmware compares sixteen opaque bytes and never parses them —
    /// the UUIDv5 structure is purely for humans.
    static let appId = UUID(uuidString: "06601C50-AB2E-5C2E-97D2-25BAEED7FBF0")!

    /// Shown in the device's pairing prompt ("Pair with Todo2Ink?"). Deliberately short — it is
    /// drawn on a 528px-wide e-ink panel.
    static let displayName = "Todo2Ink"

    /// Todo2Ink's button scheme.
    ///
    /// **Mandatory, not polish**: the device refuses `ACQUIRE` from a peer with no stored map, so an
    /// app with undefined buttons cannot reach the screen at all.
    ///
    /// A `LIST`-shaped peer's Up/Down/Left/Right/Confirm are already claimed by the firmware's own
    /// on-device list navigation (`docs/companion-todo-list-design.md` §5 in the firmware repo) —
    /// item cursor, list switching, and check-off toggle are all local, no protocol surface. Every
    /// entry here is therefore `.none`: Todo2Ink has nothing left to bind. `back` leaves the screen,
    /// which the firmware also handles locally.
    static let uiDeclaration = UiDeclaration(shape: .list, buttons: [
        ButtonMapEntry(.confirm, .none),
        ButtonMapEntry(.back, .none),
        ButtonMapEntry(.left, .none),
        ButtonMapEntry(.right, .none),
        ButtonMapEntry(.up, .none),
        ButtonMapEntry(.down, .none),
    ])

    private static let userLabelDefaultsKey = "Todo2Ink.userLabel"

    /// What this install calls itself on the device's gallery picker — distinct from `displayName`,
    /// which is identical across every install. Two people pairing the same reader both show up as
    /// "iPhone" under CompanionKit's own default, so without this they're indistinguishable in the
    /// picker. Empty means "not set yet."
    static func userLabel(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: userLabelDefaultsKey) ?? ""
    }

    /// Persists the label. Purely presentational, unlike `appId`/`installId`. Takes effect the next
    /// time Todo2Ink launches: `identity()` is read once at app start.
    static func setUserLabel(_ label: String, defaults: UserDefaults = .standard) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: userLabelDefaultsKey)
        } else {
            defaults.set(trimmed, forKey: userLabelDefaultsKey)
        }
    }

    /// This install's identity, with the `installId` minted into `UserDefaults` by CompanionKit.
    ///
    /// `UserDefaults` rather than the Keychain is a platform-wide decision, shared with Snap2Ink and
    /// SpokenFeeds: a Keychain item outlives app deletion, so a fresh install would silently
    /// re-attach to the peer directory the previous one left on the device.
    static func identity(defaults: UserDefaults = .standard) -> CompanionIdentity {
        let label = userLabel(defaults: defaults)
        return CompanionIdentity(
            appId: appId,
            displayName: displayName,
            userName: label.isEmpty ? CompanionIdentity.defaultUserName : label,
            defaults: defaults
        )
    }
}

/// Supplies the two per-peer assets the device stores and versions by tag: the UI declaration and
/// the sleep-screen tile icon.
///
/// Not `StaticAssetProvider`, because the icon is *rendered* to whatever dimensions the device
/// advertises rather than shipped at a fixed size — see `DeviceIcon`, same pattern as Snap2Ink's own
/// `Snap2InkAssetProvider`.
final class Todo2InkAssetProvider: CompanionAssetProvider, @unchecked Sendable {
    var uiDeclaration: UiDeclaration { Todo2InkPeer.uiDeclaration }

    func icon(for capabilities: CompanionCapabilities) -> Data? {
        DeviceIcon.encoded(
            width: capabilities.iconPixelWidth,
            height: capabilities.iconPixelHeight,
            expectedByteCount: capabilities.iconByteCount
        )
    }
}
