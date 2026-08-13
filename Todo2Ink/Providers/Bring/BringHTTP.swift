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
    func send<T: Decodable>(
        _ request: URLRequest,
        decoding type: T.Type,
        logShape: Bool = false
    ) async throws -> T {
        let data = try await send(request)
        if logShape {
            DebugLog.shared.log("bring: \(request.url?.path ?? "?") shape: \(Self.shape(of: data))")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // The shape goes to the log, not to the error: the status bar has room for a type name
            // and nothing more, and this is exactly the failure a user can only report from the
            // field. Keys only, never values — the values are the user's shopping list.
            DebugLog.shared.log("bring: \(type) decode failed; body shape: \(Self.shape(of: data))")
            throw BringError.malformedResponse("\(type)")
        }
    }

    /// A response's key structure, with every value discarded — the keys tell us which fields a
    /// response actually carries (useful when a decode fails and we need to see what changed on
    /// Bring's side), while the values themselves are the user's shopping list and never belong in
    /// a log. Depth is counted in object nesting only — arrays are transparent, so `purchase`'s
    /// array of item objects still reveals `itemId, spec, uuid` rather than collapsing to `{…}` one
    /// level too early — and a ceiling still applies past that so a pathological response can't
    /// produce an unbounded log line.
    static func shape(of data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return "not JSON (\(data.count) bytes)"
        }
        func describe(_ value: Any, depth: Int) -> String {
            switch value {
            case let dictionary as [String: Any] where depth > 0:
                let keys = dictionary.keys.sorted()
                    .map { "\($0)\(describe(dictionary[$0] as Any, depth: depth - 1))" }
                return "{\(keys.joined(separator: ", "))}"
            case is [String: Any]:
                return "{…}"
            case let array as [Any]:
                return "[\(array.count)\(array.first.map { describe($0, depth: depth) } ?? "")]"
            default:
                return ""
            }
        }
        return describe(object, depth: 3)
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
