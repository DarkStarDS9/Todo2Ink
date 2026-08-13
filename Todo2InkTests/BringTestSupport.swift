import Foundation
@testable import Todo2Ink

/// A `URLSession` that answers from a script instead of the network, so the Bring! client's request
/// shape and token handling can be tested without an account or a connection.
enum FakeBringServer {
    struct Response {
        let status: Int
        let body: Data

        static func ok(_ json: String) -> Response {
            Response(status: 200, body: Data(json.utf8))
        }

        static func status(_ status: Int) -> Response {
            Response(status: status, body: Data())
        }
    }

    /// Requests the fake saw, in order — the assertion surface for "did we send the right thing".
    nonisolated(unsafe) static var recorded: [(request: URLRequest, body: Data?)] = []

    /// Answers keyed by the path suffix of the request. First match wins, so a test can queue a
    /// different answer for the same path by pushing onto `queued`.
    nonisolated(unsafe) static var handler: ((URLRequest) -> Response)?

    static func reset() {
        recorded = []
        handler = nil
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeBringURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static var lastBodyJSON: [String: Any]? {
        guard let body = recorded.last?.body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        return object
    }
}

final class FakeBringURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // `URLProtocol` strips the body off the request it hands us, so read it back off the stream.
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            recorded.httpBody = Data(reading: stream)
        }
        FakeBringServer.recorded.append((recorded, recorded.httpBody))

        let response = FakeBringServer.handler?(recorded) ?? .status(500)
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension Data {
    init(reading stream: InputStream) {
        var data = Data()
        stream.open()
        defer { stream.close() }
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        self = data
    }
}

/// A credential store with no Keychain behind it — the Keychain needs an entitlement and a host app,
/// and none of what these tests check is Keychain behaviour.
final class InMemoryBringCredentialStore: BringCredentialStore {
    private var session: BringSession?

    init(session: BringSession? = nil) {
        self.session = session
    }

    var stored: BringSession? { session }

    func load() throws -> BringSession? { session }
    func save(_ session: BringSession) throws { self.session = session }
    func clear() throws { session = nil }
}

extension BringSession {
    static func fake(
        accessToken: String = "access-1",
        refreshToken: String = "refresh-1",
        expiresAt: Date = Date(timeIntervalSince1970: 10_000)
    ) -> BringSession {
        BringSession(
            userUuid: "user-uuid",
            publicUserUuid: "public-uuid",
            email: "someone@example.com",
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt
        )
    }
}

/// Response bodies as the real API returns them, trimmed to the fields this client reads.
enum BringFixtures {
    static let auth = """
    {
      "uuid": "user-uuid",
      "publicUuid": "public-uuid",
      "access_token": "access-1",
      "refresh_token": "refresh-1",
      "token_type": "Bearer",
      "expires_in": 3600
    }
    """

    static let refreshedAuth = """
    {
      "access_token": "access-2",
      "refresh_token": "refresh-2",
      "token_type": "Bearer",
      "expires_in": 3600
    }
    """

    static let lists = """
    {
      "lists": [
        { "listUuid": "list-a", "name": "Einkauf", "theme": "ch.publisheria.bring.theme.home" },
        { "listUuid": "list-b", "name": "Baumarkt", "theme": "ch.publisheria.bring.theme.home" }
      ]
    }
    """

    static let listContents = """
    {
      "uuid": "list-a",
      "status": "REGISTERED",
      "purchase": [
        { "uuid": "item-1", "itemId": "Milch", "specification": "2 Liter" },
        { "uuid": "item-2", "itemId": "Brot", "specification": "" }
      ],
      "recently": [
        { "uuid": "item-3", "itemId": "Butter", "specification": "" }
      ]
    }
    """
}
