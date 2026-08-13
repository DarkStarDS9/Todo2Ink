import Foundation
import Security

/// A logged-in Bring! session: who the user is, and the two tokens that keep them logged in.
///
/// The password is deliberately *not* here. It is used once, at login, and never stored — a refresh
/// token that stops working costs the user one login screen, whereas a stored password is a
/// liability for as long as the app is installed.
struct BringSession: Codable, Equatable {
    /// Bring!'s private user uuid, which is the `{uuid}` in `bringusers/{uuid}/lists` and the
    /// `X-BRING-USER-UUID` header.
    var userUuid: String
    var publicUserUuid: String
    /// Kept only so the login screen can prefill it after a session expires.
    var email: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    /// Treats a nearly-expired token as expired, so a request never leaves with a token that dies in
    /// flight. Bring!'s tokens last hours; a minute of slack costs nothing.
    func isExpired(now: Date, slack: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(slack) >= expiresAt
    }
}

/// Where a `BringSession` lives between launches.
///
/// A protocol rather than a direct Keychain call so tests can run without one — the Keychain needs
/// an entitlement and a real (or at least keychain-sharing-capable) app host, and a client's token
/// handling is exactly the part worth testing offline.
protocol BringCredentialStore: AnyObject {
    func load() throws -> BringSession?
    func save(_ session: BringSession) throws
    func clear() throws
}

/// The real store. Keychain, never `UserDefaults`: these are the user's Bring! account tokens, and
/// `UserDefaults` is a plist in the app container that any backup or file-level inspection reads.
final class KeychainBringCredentialStore: BringCredentialStore {
    private let service: String
    private let account: String

    init(service: String = "app.todo2ink.bring", account: String = "session") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() throws -> BringSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            // A session this app can no longer decode is treated as no session rather than as an
            // error: the format changed, and the only useful outcome is a fresh login.
            return try? JSONDecoder().decode(BringSession.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw BringError.malformedResponse("keychain read failed (OSStatus \(status))")
        }
    }

    func save(_ session: BringSession) throws {
        let data = try JSONEncoder().encode(session)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // The tokens are only useful while the user is actively using the phone, and this app
            // has no background refresh — the strictest accessibility that still works is right.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = baseQuery
            insert.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw BringError.malformedResponse("keychain write failed (OSStatus \(addStatus))")
            }
            return
        }
        guard status == errSecSuccess else {
            throw BringError.malformedResponse("keychain update failed (OSStatus \(status))")
        }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BringError.malformedResponse("keychain delete failed (OSStatus \(status))")
        }
    }
}
