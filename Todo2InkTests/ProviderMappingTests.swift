import CompanionKit
import XCTest
@testable import Todo2Ink

/// Covers the invariants `ProviderMapping`'s doc comment claims: ids are stable across launches,
/// never reused, and — the reason the type exists at all — namespaced per provider so two backends
/// can hand out identical native id strings without colliding on the wire.
final class ProviderMappingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ProviderMappingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testItemIdIsStableForTheSameNativeId() {
        let mapping = ProviderMapping(defaults: defaults)
        let first = mapping.itemId(forProvider: .reminders, nativeId: "abc")
        let second = mapping.itemId(forProvider: .reminders, nativeId: "abc")
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
    }

    /// The whole point of namespacing: the same native id string from two providers must never
    /// resolve to the same wire id. Without the provider prefix this test fails outright.
    func testIdenticalNativeIdsFromDifferentProvidersDoNotCollide() {
        let mapping = ProviderMapping(defaults: defaults)
        let reminders = mapping.itemId(forProvider: .reminders, nativeId: "shared-id")
        let bring = mapping.itemId(forProvider: .bring, nativeId: "shared-id")
        XCTAssertNotNil(reminders)
        XCTAssertNotNil(bring)
        XCTAssertNotEqual(reminders, bring)

        XCTAssertEqual(mapping.nativeItemId(forItemId: reminders!)?.provider, .reminders)
        XCTAssertEqual(mapping.nativeItemId(forItemId: bring!)?.provider, .bring)

        // Same for list ids, which share the concern but not the counter.
        XCTAssertNotEqual(
            mapping.listId(forProvider: .reminders, nativeId: "shared-list"),
            mapping.listId(forProvider: .bring, nativeId: "shared-list")
        )
    }

    func testIdsSurviveARelaunch() {
        let first = ProviderMapping(defaults: defaults)
        let itemId = first.itemId(forProvider: .reminders, nativeId: "abc")
        let listId = first.listId(forProvider: .reminders, nativeId: "list-1")

        let reloaded = ProviderMapping(defaults: defaults)
        XCTAssertEqual(reloaded.itemId(forProvider: .reminders, nativeId: "abc"), itemId)
        XCTAssertEqual(reloaded.listId(forProvider: .reminders, nativeId: "list-1"), listId)
        XCTAssertEqual(reloaded.nativeItemId(forItemId: itemId!)?.nativeId, "abc")
    }

    /// Ids are never reused, so a native id seen after others were minted gets a fresh number
    /// rather than filling a gap — the reverse lookup depends on it.
    func testIdsAreNotReused() {
        let mapping = ProviderMapping(defaults: defaults)
        let a = mapping.itemId(forProvider: .reminders, nativeId: "a")
        let b = mapping.itemId(forProvider: .reminders, nativeId: "b")
        let c = mapping.itemId(forProvider: .reminders, nativeId: "c")
        XCTAssertEqual(Set([a, b, c]).count, 3)
        XCTAssertEqual(mapping.itemId(forProvider: .reminders, nativeId: "a"), a)
    }

    /// Native ids may contain the `/` the composite key uses as its separator; provider ids may
    /// not. Splitting at the first one is what keeps that asymmetry safe.
    func testNativeIdsContainingTheKeySeparatorRoundTrip() {
        let mapping = ProviderMapping(defaults: defaults)
        let messy = "x-apple/id/with/slashes"
        let itemId = mapping.itemId(forProvider: .reminders, nativeId: messy)
        let resolved = mapping.nativeItemId(forItemId: itemId!)
        XCTAssertEqual(resolved?.provider, .reminders)
        XCTAssertEqual(resolved?.nativeId, messy)
    }

    /// The upgrade from `ReminderMapping` is a reset, not a migration — asserted here so that
    /// choice is a decision on record rather than something a future reader has to infer.
    func testOldReminderMappingStorageIsIgnored() {
        defaults.set(Data("{\"itemIdByReminderId\":{\"abc\":7}}".utf8), forKey: "ReminderMapping.v1")
        let mapping = ProviderMapping(defaults: defaults)
        XCTAssertEqual(mapping.itemId(forProvider: .reminders, nativeId: "abc"), 1)
    }
}
