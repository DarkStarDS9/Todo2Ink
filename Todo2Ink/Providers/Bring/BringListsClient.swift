import Foundation

/// Reading and writing Bring! lists, on top of whatever session `BringAuthClient` currently holds.
///
/// Every call goes through `authenticated(_:)`, which retries once with a forced refresh on a 401.
/// That retry exists because a token can expire between "we checked the expiry" and "the server saw
/// the request", and because Bring! sometimes invalidates a token early — neither should surface to
/// the user as a failed sync when one refresh fixes it.
actor BringListsClient {
    private let http: BringHTTP
    private let auth: BringAuthClient

    init(http: BringHTTP = BringHTTP(), auth: BringAuthClient) {
        self.http = http
        self.auth = auth
    }

    func lists() async throws -> [BringListsResponse.List] {
        try await authenticated { session in
            let request = self.http.request(
                path: "bringusers/\(session.userUuid)/lists",
                session: session
            )
            return try await self.http.send(request, decoding: BringListsResponse.self).lists
        }
    }

    /// A list's contents, split the way Bring! splits them: still to buy, and recently bought.
    func contents(ofList listUuid: String) async throws -> BringListContentResponse {
        try await authenticated { session in
            let request = self.http.request(path: "v2/bringlists/\(listUuid)", session: session)
            return try await self.http.send(request, decoding: BringListContentResponse.self)
        }
    }

    /// Moves an item between "to buy" and "recently bought" — Bring!'s equivalent of checking a box.
    ///
    /// Sent as a one-change batch because that is the only shape the endpoint accepts.
    func setPurchased(_ purchased: Bool, item: BringItem, inList listUuid: String) async throws {
        let change = BringChangeRequest.Change(
            itemId: item.itemId,
            spec: item.specification,
            uuid: item.uuid,
            operation: purchased ? .toRecently : .toPurchase
        )
        let body = try JSONEncoder().encode(BringChangeRequest(changes: [change]))

        try await authenticated { session in
            var request = self.http.request(
                path: "v2/bringlists/\(listUuid)/items",
                method: "PUT",
                session: session
            )
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            _ = try await self.http.send(request)
        }
    }

    private func authenticated<T>(_ body: (BringSession) async throws -> T) async throws -> T {
        let session = try await auth.validSession()
        do {
            return try await body(session)
        } catch BringError.invalidCredentials {
            // One retry, and only one: if a freshly refreshed token is also rejected, the problem is
            // the account rather than the clock, and looping would just spend the refresh token.
            let refreshed = try await auth.refreshedSession()
            return try await body(refreshed)
        }
    }
}
