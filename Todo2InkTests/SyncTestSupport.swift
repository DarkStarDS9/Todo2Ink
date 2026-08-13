import CompanionKit
import Foundation
@testable import Todo2Ink

/// A generic failure for tests that only care *that* something threw, not what.
struct SyncTestError: Error, Equatable {}

/// Fakes `TodoSyncClient` — the seam `TodoSyncEngine` talks to instead of a real
/// `CompanionClient` — so the pull → merge → push ordering can be asserted directly rather than
/// inferred from a live device.
@MainActor
final class FakeSyncClient: TodoSyncClient {
    enum Call: Equatable {
        case pull
        case push(revision: UInt32)
    }

    /// The ordering assertion surface: did a pull precede this push, was there a second pull after
    /// a restart, and so on.
    private(set) var calls: [Call] = []

    /// What was actually pushed, so a test can inspect the merged document's contents, not just
    /// that a push happened.
    private(set) var pushedDocuments: [TodoDocument] = []

    /// A queue: each `pullDeviations()` call pops the front. Once empty, calls fall back to an
    /// empty diff — the ordinary "nothing to report" shape, not an error.
    var deviationsToReturn: [TodoDeviations] = []

    var pullError: Error?
    var pushError: Error?

    /// Fires synchronously from inside the call, before the error (if any) is thrown — lets a test
    /// drive the engine (e.g. `markPullOwed()`) at the exact moment a pull or push is in flight.
    var onPull: (() -> Void)?
    var onPush: (() -> Void)?

    func pullDeviations() async throws -> TodoDeviations {
        calls.append(.pull)
        onPull?()
        // A real BLE round trip suspends, and the whole class of bug these tests exist for lives in
        // what another `syncNow()` does while it is suspended. A fake that returns without ever
        // yielding lets the reentrancy tests pass against an engine that has no guard at all.
        await Task.yield()
        if let pullError { throw pullError }
        if deviationsToReturn.isEmpty {
            return TodoDeviations(revision: 0, checkedByItemId: [:])
        }
        return deviationsToReturn.removeFirst()
    }

    func pushDocument(_ document: TodoDocument) async throws {
        calls.append(.push(revision: document.revision))
        onPush?()
        await Task.yield()
        if let pushError { throw pushError }
        pushedDocuments.append(document)
    }
}

/// Fakes `DisplayTransport`. Only `state` and `client` matter to `TodoSyncEngine` — connect/
/// disconnect are no-ops because nothing under test calls them.
@MainActor
final class FakeDisplayTransport: DisplayTransport {
    var state: TransportState = .ready
    var onStateChange: ((TransportState) -> Void)?
    var onListStateAvailable: ((UInt32, UInt16) -> Void)?
    var diagnostics: [DiagnosticEntry] = []
    var client: (any TodoSyncClient)?

    func connect() {}
    func disconnect() {}
}

/// Fakes `TodoProvider`. Lists and items are plain dictionaries a test fills in directly, rather
/// than anything resembling EventKit or Bring's own plumbing.
@MainActor
final class FakeTodoProvider: TodoProvider {
    /// A tuple would do, but tuples aren't Equatable — this is what lets a test assert
    /// `completedCalls == [...]` directly.
    struct CompletedCall: Equatable {
        let itemId: String
        let completed: Bool
    }

    let id: ProviderId
    var displayName: String
    var statusDescription: String?
    var authState: ProviderAuthState = .authorized

    var lists: [ProviderList] = []
    var itemsByListId: [String: [ProviderItem]] = [:]

    var fetchItemsError: Error?
    var setCompletedError: Error?

    /// Fires from inside `fetchItems`, before `fetchItemsError` (if any) is thrown — lets a test
    /// simulate a list-state notification arriving mid-assembly.
    var onFetchItems: (() -> Void)?

    private(set) var completedCalls: [CompletedCall] = []

    init(id: ProviderId, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName ?? id.rawValue
    }

    func requestAccess() async throws -> Bool { true }

    func fetchLists() async throws -> [ProviderList] { lists }

    func fetchItems(listIds: [String]) async throws -> [String: [ProviderItem]] {
        onFetchItems?()
        // Assembly is seconds of network in the field; suspending here is what makes the
        // "notification arrived mid-assembly" tests test anything.
        await Task.yield()
        if let fetchItemsError { throw fetchItemsError }
        return itemsByListId.filter { listIds.contains($0.key) }
    }

    func setCompleted(_ completed: Bool, forItemId itemId: String) async throws {
        if let setCompletedError { throw setCompletedError }
        completedCalls.append(CompletedCall(itemId: itemId, completed: completed))
    }
}
