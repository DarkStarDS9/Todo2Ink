import CompanionKit

/// The two device calls `TodoSyncEngine` makes, as a seam it can be tested against.
///
/// `DisplayTransport` used to hand out a concrete `CompanionClient`, which meant the sync loop —
/// the one piece of this app that can destroy the user's data — had no tests at all. Two builds
/// shipped a check-off-eating ordering bug because of it. Neither was subtle in hindsight; both
/// were invisible to reading and obvious to a test.
///
/// Deliberately two methods and not a general "expose CompanionClient behind a protocol": the
/// narrower it is, the more a fake can say about *policy* (did a pull precede the push? was the
/// document assembled after the write-back?) without restating the wire.
///
/// The names differ from `CompanionClient`'s own so that the conformance below can forward rather
/// than overload — `pushTodoDocument(_:)` has a defaulted `awaitRender:`, and a same-named protocol
/// witness would make every existing call site ambiguous.
@MainActor
protocol TodoSyncClient: AnyObject {
    /// The device's accumulated check-off diff. Cheap when there is nothing to report, which is why
    /// `TodoSyncEngine` can afford to call it before every push rather than only when notified.
    func pullDeviations() async throws -> TodoDeviations

    /// Replaces the device's whole document — **and clears its diff**, which is the reason a push
    /// must never be the first thing a session does.
    func pushDocument(_ document: TodoDocument) async throws
}

extension CompanionClient: TodoSyncClient {
    func pullDeviations() async throws -> TodoDeviations {
        try await pullListState()
    }

    func pushDocument(_ document: TodoDocument) async throws {
        try await pushTodoDocument(document)
    }
}
