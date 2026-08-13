import Foundation

/// Request building and status-code handling for the Bring! API.
///
/// Small on purpose: it exists so `BringAuthClient` and `BringListsClient` agree on headers and on
/// what an HTTP status means, and so both can be pointed at a fake `URLSession` in tests.
struct BringHTTP {
    let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    /// A request with the headers every Bring! endpoint wants. `session` is `nil` for the two
    /// unauthenticated auth endpoints.
    func request(
        path: String,
        method: String = "GET",
        session: BringSession? = nil
    ) -> URLRequest {
        var request = URLRequest(url: BringAPI.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue(BringAPI.apiKey, forHTTPHeaderField: "X-BRING-API-KEY")
        request.setValue(BringAPI.clientHeader, forHTTPHeaderField: "X-BRING-CLIENT")
        request.setValue(BringAPI.applicationHeader, forHTTPHeaderField: "X-BRING-APPLICATION")
        request.setValue(BringAPI.country, forHTTPHeaderField: "X-BRING-COUNTRY")
        if let session {
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(session.userUuid, forHTTPHeaderField: "X-BRING-USER-UUID")
            request.setValue(session.publicUserUuid, forHTTPHeaderField: "X-BRING-PUBLIC-USER-UUID")
        }
        return request
    }

    /// Sends a request and returns its body, translating transport and status failures into
    /// `BringError`.
    ///
    /// Only the request's shape is logged — method, path, status. Never headers (they carry the
    /// bearer token), never bodies (they carry the password on the auth path, and the user's
    /// shopping list everywhere else).
    func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let error as URLError {
            DebugLog.shared.log("bring: \(request.httpMethod ?? "?") \(request.url?.path ?? "?") — \(error.code.rawValue)")
            throw BringError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw BringError.malformedResponse("no HTTP response for \(request.url?.path ?? "?")")
        }
        DebugLog.shared.log("bring: \(request.httpMethod ?? "?") \(request.url?.path ?? "?") — \(http.statusCode)")

        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw BringError.invalidCredentials
        default:
            throw BringError.http(status: http.statusCode)
        }
    }

    /// Sends a request and decodes its body, so a shape change reads as
    /// `malformedResponse("BringListsResponse")` rather than as an opaque `DecodingError`.
    func send<T: Decodable>(_ request: URLRequest, decoding type: T.Type) async throws -> T {
        let data = try await send(request)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw BringError.malformedResponse("\(type) from \(request.url?.path ?? "?")")
        }
    }

    /// `application/x-www-form-urlencoded` body, which the two auth endpoints require and nothing
    /// else here uses.
    static func formBody(_ fields: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = fields
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        // `URLComponents` leaves `+` alone in a query, where a form body must encode it — otherwise
        // a password containing one arrives as a space and the login fails for no visible reason.
        let encoded = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        return Data(encoded.utf8)
    }
}
