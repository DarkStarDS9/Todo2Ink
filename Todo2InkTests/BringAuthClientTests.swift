import XCTest
@testable import Todo2Ink

/// Bring! is a reverse-engineered API, so the parts worth pinning down are the ones a server-side
/// change or a careless refactor would break silently: the exact request shapes, and the token
/// lifecycle around them.
final class BringAuthClientTests: XCTestCase {
    private var store: InMemoryBringCredentialStore!
    private var http: BringHTTP!
    private var now: Date!

    override func setUp() {
        super.setUp()
        FakeBringServer.reset()
        store = InMemoryBringCredentialStore()
        http = BringHTTP(urlSession: FakeBringServer.session())
        now = Date(timeIntervalSince1970: 1_000)
    }

    override func tearDown() {
        FakeBringServer.reset()
        super.tearDown()
    }

    private func client() -> BringAuthClient {
        BringAuthClient(http: http, store: store, now: { self.now })
    }

    func testLoginSendsAFormEncodedBodyAndStoresTheSession() async throws {
        FakeBringServer.handler = { _ in .ok(BringFixtures.auth) }

        let session = try await client().logIn(email: "a@b.com", password: "hunter2")

        let request = try XCTUnwrap(FakeBringServer.recorded.last)
        XCTAssertEqual(request.request.url?.path, "/rest/v2/bringauth")
        XCTAssertEqual(request.request.httpMethod, "POST")
        XCTAssertEqual(
            request.request.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded",
            "the auth endpoints are form-encoded, unlike every other endpoint"
        )
        XCTAssertEqual(String(decoding: try XCTUnwrap(request.body), as: UTF8.self),
                       "email=a@b.com&password=hunter2")

        XCTAssertEqual(session.userUuid, "user-uuid")
        XCTAssertEqual(session.expiresAt, now.addingTimeInterval(3600))
        XCTAssertEqual(store.stored, session)
        XCTAssertNil(
            store.stored.map { "\($0)" }?.range(of: "hunter2"),
            "the password must never reach storage"
        )
    }

    func testEveryRequestCarriesTheClientIdentificationHeaders() async throws {
        FakeBringServer.handler = { _ in .ok(BringFixtures.auth) }
        _ = try await client().logIn(email: "a@b.com", password: "x")

        let request = try XCTUnwrap(FakeBringServer.recorded.last).request
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-BRING-API-KEY"), BringAPI.apiKey)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-BRING-CLIENT"), "android")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-BRING-APPLICATION"), "bring")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-BRING-COUNTRY"))
    }

    /// A `+` in a password is the classic form-encoding bug: left alone it arrives as a space and
    /// the login fails with a plain "wrong password".
    func testPlusInAPasswordIsEncoded() async throws {
        FakeBringServer.handler = { _ in .ok(BringFixtures.auth) }
        _ = try await client().logIn(email: "a@b.com", password: "a+b")

        let body = String(decoding: try XCTUnwrap(FakeBringServer.recorded.last?.body), as: UTF8.self)
        XCTAssertTrue(body.contains("password=a%2Bb"), "got \(body)")
    }

    func testRejectedCredentialsSurfaceAsInvalidCredentials() async {
        FakeBringServer.handler = { _ in .status(401) }
        do {
            _ = try await client().logIn(email: "a@b.com", password: "wrong")
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? BringError, .invalidCredentials)
        }
        XCTAssertNil(store.stored)
    }

    func testValidSessionRefreshesAnExpiredToken() async throws {
        store = InMemoryBringCredentialStore(
            session: .fake(expiresAt: now.addingTimeInterval(-1))
        )
        FakeBringServer.handler = { _ in .ok(BringFixtures.refreshedAuth) }

        let session = try await client().validSession()

        let request = try XCTUnwrap(FakeBringServer.recorded.last)
        XCTAssertEqual(request.request.url?.path, "/rest/v2/bringauth/token")
        XCTAssertEqual(String(decoding: try XCTUnwrap(request.body), as: UTF8.self),
                       "grant_type=refresh_token&refresh_token=refresh-1")
        XCTAssertEqual(session.accessToken, "access-2")
        XCTAssertEqual(session.refreshToken, "refresh-2")
        XCTAssertEqual(store.stored?.accessToken, "access-2")
    }

    func testValidSessionLeavesALiveTokenAlone() async throws {
        store = InMemoryBringCredentialStore(session: .fake(expiresAt: now.addingTimeInterval(3600)))

        let session = try await client().validSession()

        XCTAssertEqual(session.accessToken, "access-1")
        XCTAssertTrue(FakeBringServer.recorded.isEmpty, "no request should have been needed")
    }

    /// A token that expires seconds from now is treated as expired, so a request can't leave with a
    /// token that dies in flight.
    func testATokenAboutToExpireIsRefreshed() async throws {
        store = InMemoryBringCredentialStore(session: .fake(expiresAt: now.addingTimeInterval(5)))
        FakeBringServer.handler = { _ in .ok(BringFixtures.refreshedAuth) }

        _ = try await client().validSession()
        XCTAssertEqual(FakeBringServer.recorded.count, 1)
    }

    /// A refresh token Bring! no longer accepts means the user must log in again — leaving the dead
    /// session in place would turn that into a provider that errors on every sync forever.
    func testARejectedRefreshClearsTheSession() async {
        store = InMemoryBringCredentialStore(session: .fake(expiresAt: now.addingTimeInterval(-1)))
        FakeBringServer.handler = { _ in .status(401) }

        do {
            _ = try await client().validSession()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? BringError, .invalidCredentials)
        }
        XCTAssertNil(store.stored)
    }

    /// A network blip must *not* clear the session — otherwise a train tunnel logs the user out.
    func testAServerErrorDuringRefreshKeepsTheSession() async {
        store = InMemoryBringCredentialStore(session: .fake(expiresAt: now.addingTimeInterval(-1)))
        FakeBringServer.handler = { _ in .status(503) }

        do {
            _ = try await client().validSession()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? BringError, .http(status: 503))
        }
        XCTAssertNotNil(store.stored)
    }

    func testNoStoredSessionIsNotLoggedIn() async {
        do {
            _ = try await client().validSession()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? BringError, .notLoggedIn)
        }
    }

    /// Bring! doesn't always issue a new refresh token; dropping the old one when it doesn't would
    /// strand the session at the next expiry.
    func testARefreshWithoutANewRefreshTokenKeepsTheOldOne() async throws {
        store = InMemoryBringCredentialStore(session: .fake(expiresAt: now.addingTimeInterval(-1)))
        FakeBringServer.handler = { _ in
            .ok("{\"access_token\":\"access-2\",\"expires_in\":3600}")
        }

        let session = try await client().validSession()
        XCTAssertEqual(session.refreshToken, "refresh-1")
    }
}
