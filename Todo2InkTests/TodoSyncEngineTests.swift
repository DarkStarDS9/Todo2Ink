import CompanionKit
import XCTest
@testable import Todo2Ink

/// Tests for the pull → merge → push loop — the app's data-loss-critical path. Two consecutive
/// TestFlight builds shipped bugs that erased the user's check-offs, both invisible to reading and
/// obvious to a test, once `TodoSyncClient` gave the loop something fakeable to run against.
@MainActor
final class TodoSyncEngineTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var mapping: ProviderMapping!
    private var transport: FakeDisplayTransport!
    private var client: FakeSyncClient!

    override func setUp() {
        super.setUp()
        suiteName = "TodoSyncEngineTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        mapping = ProviderMapping(defaults: defaults)
        client = FakeSyncClient()
        transport = FakeDisplayTransport()
        transport.client = client
        transport.state = .ready
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeEngine(providers: [any TodoProvider]) -> TodoSyncEngine {
        TodoSyncEngine(transport: transport, providers: providers, mapping: mapping)
    }

    private func configuration(_ entries: [(ProviderId, [String])]) -> SyncConfiguration {
        SyncConfiguration(providers: entries.map {
            SyncConfiguration.ProviderEntry(providerId: $0.0, enabled: true, selectedListIds: $0.1)
        })
    }

    private func makeProvider(
        _ rawId: String,
        listId: String,
        listTitle: String,
        items: [ProviderItem]
    ) -> FakeTodoProvider {
        let provider = FakeTodoProvider(id: ProviderId(rawValue: rawId))
        provider.lists = [ProviderList(id: listId, title: listTitle)]
        provider.itemsByListId = [listId: items]
        return provider
    }

    // MARK: 1. Pull always precedes the first push

    /// The build-12 bug: gaining the screen started a sync 36 ms before the list-state notification
    /// arrived, the sync saw `pullOwed == false`, skipped the pull, and the push wiped the device's
    /// diff with seven unread check-offs in it. `syncNow()` must pull unconditionally on every run,
    /// notification or not.
    func testPullAlwaysPrecedesTheFirstPush() async {
        let engine = makeEngine(providers: [])

        await engine.syncNow()

        XCTAssertEqual(client.calls, [.pull, .push(revision: 0)])
    }

    // MARK: 2. A check-off reaches only its owning provider

    func testDeviceCheckOffReachesOnlyOwningProvider() async {
        let providerA = makeProvider("A", listId: "listA", listTitle: "List A", items: [
            ProviderItem(id: "item-a1", text: "A1", checked: false),
        ])
        let providerB = makeProvider("B", listId: "listB", listTitle: "List B", items: [
            ProviderItem(id: "item-b1", text: "B1", checked: false),
        ])

        let engine = makeEngine(providers: [providerA, providerB])
        engine.configuration = configuration([(providerA.id, ["listA"]), (providerB.id, ["listB"])])

        // First sync mints the wire ids ProviderMapping assigns during assembly.
        await engine.syncNow()

        guard let bItemId = mapping.itemId(forProvider: providerB.id, nativeId: "item-b1") else {
            return XCTFail("expected item-b1 to already have a minted wire id")
        }

        client.deviationsToReturn = [TodoDeviations(revision: 0, checkedByItemId: [bItemId: true])]
        engine.markPullOwed()
        await engine.syncNow()

        XCTAssertEqual(providerB.completedCalls, [.init(itemId: "item-b1", completed: true)])
        XCTAssertTrue(providerA.completedCalls.isEmpty)
    }

    // MARK: 3. An unplaceable deviation reaches no one

    /// A deviation naming an itemId the mapping never assigned — dropped in `applyDeviations`. That
    /// path used to be a silent `continue`; asserting it here is what keeps it from becoming one
    /// again without anyone noticing.
    func testUnplaceableDeviationReachesNoProviderButStillPushes() async {
        let provider = makeProvider("A", listId: "listA", listTitle: "List A", items: [
            ProviderItem(id: "item-a1", text: "A1", checked: false),
        ])
        let engine = makeEngine(providers: [provider])
        engine.configuration = configuration([(provider.id, ["listA"])])

        client.deviationsToReturn = [TodoDeviations(revision: 0, checkedByItemId: [60000: true])]

        await engine.syncNow()

        XCTAssertTrue(provider.completedCalls.isEmpty)
        // Still bumps the revision — the pulled diff was non-empty (it named an itemId), even
        // though nothing in it resolved to a real item; only an *empty* diff skips the merge.
        XCTAssertEqual(client.calls, [.pull, .push(revision: 1)])
    }

    // MARK: 4. The pushed document reflects the check-off

    func testPushedDocumentReflectsTheCheckOffAndBumpsRevision() async {
        let provider = makeProvider("A", listId: "listA", listTitle: "List A", items: [
            ProviderItem(id: "item-a1", text: "A1", checked: false),
        ])
        let engine = makeEngine(providers: [provider])
        engine.configuration = configuration([(provider.id, ["listA"])])

        await engine.syncNow()
        XCTAssertEqual(client.pushedDocuments.count, 1)
        XCTAssertEqual(client.pushedDocuments[0].revision, 0)

        guard let itemId = mapping.itemId(forProvider: provider.id, nativeId: "item-a1") else {
            return XCTFail("expected item-a1 to already have a minted wire id")
        }
        client.deviationsToReturn = [TodoDeviations(revision: 0, checkedByItemId: [itemId: true])]
        engine.markPullOwed()
        await engine.syncNow()

        XCTAssertEqual(client.pushedDocuments.count, 2)
        let pushed = client.pushedDocuments[1]
        XCTAssertEqual(pushed.revision, 1, "mergingDeviceDeviations bumps the revision by one")
        let checkedItem = pushed.lists.flatMap(\.groups).flatMap(\.items).first { $0.itemId == itemId }
        XCTAssertEqual(checkedItem?.checked, true)
    }

    // MARK: 5. A mid-assembly notification restarts before push

    func testNotificationDuringAssemblyRestartsBeforePush() async {
        let providerA = makeProvider("A", listId: "listA", listTitle: "List A", items: [
            ProviderItem(id: "item-a1", text: "A1", checked: false),
        ])
        let providerB = makeProvider("B", listId: "listB", listTitle: "List B", items: [
            ProviderItem(id: "item-b1", text: "B1", checked: false),
        ])

        // Minted directly rather than via a warm-up sync, so the call log below starts clean.
        let bItemId = mapping.itemId(forProvider: providerB.id, nativeId: "item-b1")!

        let engine = makeEngine(providers: [providerA, providerB])
        engine.configuration = configuration([(providerA.id, ["listA"]), (providerB.id, ["listB"])])

        var fetchCount = 0
        providerA.onFetchItems = {
            fetchCount += 1
            if fetchCount == 1 {
                engine.markPullOwed()
            }
        }

        client.deviationsToReturn = [
            TodoDeviations(revision: 0, checkedByItemId: [:]),
            TodoDeviations(revision: 0, checkedByItemId: [bItemId: true]),
        ]

        await engine.syncNow()

        // Not [.pull, .push] — the mid-assembly notification must force a second pull before the
        // push, or the document assembled from the first (stale) pass would go out instead.
        XCTAssertEqual(client.calls, [.pull, .pull, .push(revision: 1)])
        XCTAssertEqual(providerB.completedCalls, [.init(itemId: "item-b1", completed: true)])
    }

    // MARK: 6. Restarts are bounded

    func testRestartsAreBoundedToFourPulls() async {
        let provider = makeProvider("A", listId: "listA", listTitle: "List A", items: [
            ProviderItem(id: "item-a1", text: "A1", checked: false),
        ])
        let engine = makeEngine(providers: [provider])
        engine.configuration = configuration([(provider.id, ["listA"])])

        // Marks a pull owed on every pass, simulating a reader that keeps notifying — the run must
        // still terminate rather than being held off the push forever.
        provider.onFetchItems = {
            engine.markPullOwed()
        }

        await engine.syncNow()

        XCTAssertEqual(client.calls, [.pull, .pull, .pull, .pull, .push(revision: 0)])
    }

    // MARK: 7. A failed pull does not push

    func testFailedPullDoesNotPush() async {
        client.pullError = SyncTestError()
        var statuses: [SyncStatus] = []
        let engine = makeEngine(providers: [])
        engine.onStatusChange = { statuses.append($0) }

        await engine.syncNow()

        XCTAssertEqual(client.calls, [.pull])
        XCTAssertTrue(client.pushedDocuments.isEmpty)
        guard case .failed = statuses.last else {
            return XCTFail("expected the last status to be .failed, got \(String(describing: statuses.last))")
        }
    }

    // MARK: 8. Overlapping syncNow() calls do not interleave

    /// The other half of the build-12 fix: two triggers firing together (foregrounding, regaining
    /// the screen) must not run two syncs side by side. The first pulls and clears `pullOwed`; a
    /// second run that started alongside it would see nothing owed and push a document assembled
    /// from a provider not yet written to, putting every box back. A request that arrives mid-run
    /// must be remembered and serviced afterwards, not dropped and not interleaved.
    func testOverlappingSyncsDoNotInterleave() async {
        let provider = makeProvider("A", listId: "listA", listTitle: "List A", items: [
            ProviderItem(id: "item-a1", text: "A1", checked: false),
        ])
        let engine = makeEngine(providers: [provider])
        engine.configuration = configuration([(provider.id, ["listA"])])

        let first = Task { await engine.syncNow() }
        let second = Task { await engine.syncNow() }
        await first.value
        await second.value

        XCTAssertEqual(client.calls.count, 4, "the second call must be coalesced into its own run, not dropped")
        for chunkStart in stride(from: 0, to: client.calls.count, by: 2) {
            XCTAssertEqual(client.calls[chunkStart], .pull)
            guard case .push = client.calls[chunkStart + 1] else {
                return XCTFail("expected a push immediately after each pull, got \(client.calls)")
            }
        }
    }

    // MARK: 9. A failing provider doesn't stop the others

    func testFailingProviderDoesNotStopOthersFromReachingTheDevice() async {
        let providerA = FakeTodoProvider(id: ProviderId(rawValue: "A"))
        providerA.lists = [ProviderList(id: "listA", title: "List A")]
        providerA.fetchItemsError = SyncTestError()

        let providerB = makeProvider("B", listId: "listB", listTitle: "List B", items: [
            ProviderItem(id: "item-b1", text: "B1", checked: false),
        ])

        let engine = makeEngine(providers: [providerA, providerB])
        engine.configuration = configuration([(providerA.id, ["listA"]), (providerB.id, ["listB"])])

        var statuses: [SyncStatus] = []
        engine.onStatusChange = { statuses.append($0) }

        await engine.syncNow()

        XCTAssertEqual(client.pushedDocuments.count, 1)
        XCTAssertEqual(client.pushedDocuments[0].lists.map(\.title), ["List B"])

        // A push that succeeded while a provider failed is still a failure worth surfacing — the
        // code's own comment on `assembleLists`'s caller. A green "Synced" would hide a
        // persistently broken provider behind the lists that did make it.
        guard case .failed = statuses.last else {
            return XCTFail("expected the last status to be .failed, got \(String(describing: statuses.last))")
        }
    }

    // MARK: 10. A write-back failure still pushes, but is never reported as success

    /// Found by writing these tests, and worth spelling out because it is the harshest failure in
    /// the app: the push below clears the reader's diff, so a check-off whose write-back threw is
    /// lost from both sides at once — the provider never heard it, the reader has stopped
    /// remembering it, and nothing retries. Reporting `.succeeded` over that would be a green light
    /// on the one case where the user most needs to know to check.
    func testWriteBackFailureStillPushesButReportsFailure() async {
        let provider = makeProvider("A", listId: "listA", listTitle: "List A", items: [
            ProviderItem(id: "item-a1", text: "A1", checked: false),
        ])
        let engine = makeEngine(providers: [provider])
        engine.configuration = configuration([(provider.id, ["listA"])])

        await engine.syncNow()
        guard let itemId = mapping.itemId(forProvider: provider.id, nativeId: "item-a1") else {
            return XCTFail("expected item-a1 to already have a minted wire id")
        }

        provider.setCompletedError = SyncTestError()
        client.deviationsToReturn = [TodoDeviations(revision: 0, checkedByItemId: [itemId: true])]
        var statuses: [SyncStatus] = []
        engine.onStatusChange = { statuses.append($0) }
        engine.markPullOwed()
        await engine.syncNow()

        // The push still goes out: the rest of the document is correct, and withholding it would
        // strand every other list over one item.
        XCTAssertEqual(client.pushedDocuments.count, 2, "a write-back failure must not hold the push back")

        guard case .failed(_, let message) = statuses.last else {
            return XCTFail("expected .failed, got \(String(describing: statuses.last))")
        }
        XCTAssertTrue(message.contains(provider.displayName), "the message must name the provider that lost it")
    }

    // MARK: 11. Nothing happens when the transport isn't ready

    func testNothingHappensWhenTransportIsNotReady() async {
        transport.state = .disconnected
        let engine = makeEngine(providers: [])

        await engine.syncNow()

        XCTAssertTrue(client.calls.isEmpty)
    }

    func testNothingHappensWhenClientIsMissing() async {
        transport.state = .ready
        transport.client = nil
        let engine = makeEngine(providers: [])

        await engine.syncNow()

        XCTAssertTrue(client.calls.isEmpty)
    }
}
