import Foundation

/// Owns the Bring! login: the stored session, and keeping its access token fresh.
///
/// An `actor` because token refresh must not race. Two list fetches starting at once on an expired
/// token would otherwise both refresh, and Bring! invalidates the old refresh token when it issues a
/// new one — the second refresh would fail and log the user out mid-sync. Serializing here means the
/// second caller waits and gets the first one's result.
actor BringAuthClient {
    private let http: BringHTTP
    private let store: BringCredentialStore
    private let now: () -> Date

    /// Cached so the common path doesn't hit the Keychain on every request. The store stays the
    /// source of truth: this is only ever filled from it or written through to it.
    private var cachedSession: BringSession?
    private var loaded = false

    init(
        http: BringHTTP = BringHTTP(),
        store: BringCredentialStore = KeychainBringCredentialStore(),
        now: @escaping () -> Date = Date.init
    ) {
        self.http = http
        self.store = store
        self.now = now
    }

    /// Whether there is a stored session at all — the question "has the user set Bring! up?", which
    /// is distinct from whether that session still works.
    var hasSession: Bool {
        (try? storedSession()) != nil
    }

    var storedEmail: String? {
        (try? storedSession())?.email
    }

    /// Exchanges email and password for a session and stores it. The password is used here and
    /// nowhere else; it is never persisted.
    @discardableResult
    func logIn(email: String, password: String) async throws -> BringSession {
        var request = http.request(path: "v2/bringauth", method: "POST")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = BringHTTP.formBody(["email": email, "password": password])

        let response = try await http.send(request, decoding: BringAuthResponse.self)
        guard let uuid = response.uuid, let publicUuid = response.publicUuid,
              let refreshToken = response.refreshToken
        else {
            throw BringError.malformedResponse("login response without a uuid or refresh token")
        }

        let session = BringSession(
            userUuid: uuid,
            publicUserUuid: publicUuid,
            email: email,
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            expiresAt: now().addingTimeInterval(response.expiresIn ?? 3600)
        )
        try persist(session)
        return session
    }

    /// A session with a usable access token, refreshing first if the stored one has expired.
    func validSession() async throws -> BringSession {
        guard let session = try storedSession() else { throw BringError.notLoggedIn }
        guard session.isExpired(now: now()) else { return session }
        return try await refresh(session)
    }

    /// Forces a refresh regardless of the recorded expiry — for the caller that just got a 401 back
    /// with a token it believed was still good.
    func refreshedSession() async throws -> BringSession {
        guard let session = try storedSession() else { throw BringError.notLoggedIn }
        return try await refresh(session)
    }

    func logOut() {
        cachedSession = nil
        loaded = true
        try? store.clear()
    }

    // MARK: - Private

    private func refresh(_ session: BringSession) async throws -> BringSession {
        var request = http.request(path: "v2/bringauth/token", method: "POST")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = BringHTTP.formBody([
            "refresh_token": session.refreshToken,
            "grant_type": "refresh_token",
        ])

        let response: BringAuthResponse
        do {
            response = try await http.send(request, decoding: BringAuthResponse.self)
        } catch let error as BringError where error.requiresReauthentication {
            // The refresh token is spent or revoked. Clearing here rather than leaving a session
            // that can only fail is what turns this into a "log in again" prompt instead of a
            // provider that quietly errors on every sync.
            logOut()
            throw error
        }

        var refreshed = session
        refreshed.accessToken = response.accessToken
        // Bring! returns a new refresh token on most refreshes but not all; keeping the old one when
        // it doesn't is what the public clients do.
        refreshed.refreshToken = response.refreshToken ?? session.refreshToken
        refreshed.expiresAt = now().addingTimeInterval(response.expiresIn ?? 3600)
        try persist(refreshed)
        return refreshed
    }

    private func storedSession() throws -> BringSession? {
        if !loaded {
            cachedSession = try store.load()
            loaded = true
        }
        return cachedSession
    }

    private func persist(_ session: BringSession) throws {
        cachedSession = session
        loaded = true
        try store.save(session)
    }
}
