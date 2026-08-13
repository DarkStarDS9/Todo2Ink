import CompanionKit
import XCTest
@testable import Todo2Ink

/// The reader has one flat run of lists, so the two user-editable orderings — providers, and the
/// lists inside each — only mean anything once flattened. These tests pin that flattening down.
final class SyncConfigurationTests: XCTestCase {
    private func configuration() -> SyncConfiguration {
        SyncConfiguration(providers: [
            .init(providerId: .reminders, enabled: true, selectedListIds: ["r1", "r2"]),
            .init(providerId: .bring, enabled: true, selectedListIds: ["b1"]),
        ])
    }

    func testFlattensProvidersThenListsInOrder() {
        let flattened = configuration().flattened()
        XCTAssertEqual(flattened.map(\.listId), ["r1", "r2", "b1"])
        XCTAssertEqual(flattened.map(\.provider), [.reminders, .reminders, .bring])
    }

    func testReorderingProvidersReordersWholeBlocks() {
        var config = configuration()
        config.providers.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(config.flattened().map(\.listId), ["b1", "r1", "r2"])
    }

    func testDisabledProvidersContributeNothingButKeepTheirSelection() {
        var config = configuration()
        config[.reminders]?.enabled = false
        XCTAssertEqual(config.flattened().map(\.listId), ["b1"])
        // Toggling back on must not have cost the user their setup.
        XCTAssertEqual(config[.reminders]?.selectedListIds, ["r1", "r2"])
    }

    /// A provider that appears because the user updated the app must not start syncing on its own,
    /// and must not disturb an order they already chose.
    func testRegisterAppendsUnknownProvidersDisabled() {
        var config = SyncConfiguration(providers: [
            .init(providerId: .bring, enabled: true, selectedListIds: ["b1"]),
        ])
        config.register([.bring, .reminders])

        XCTAssertEqual(config.providers.map(\.providerId), [.bring, .reminders])
        XCTAssertEqual(config[.reminders]?.enabled, false)
        XCTAssertEqual(config[.reminders]?.selectedListIds, [])
        XCTAssertEqual(config[.bring]?.enabled, true, "an existing entry must be left alone")
    }

    func testRoundTripsThroughJSON() throws {
        let original = configuration()
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(SyncConfiguration.self, from: data), original)
    }

    /// `ProviderId` encodes as a bare string, so the persisted blob stays readable — worth pinning
    /// because it's a hand-written conformance that synthesis would otherwise silently replace.
    func testProviderIdEncodesAsABareString() throws {
        let data = try JSONEncoder().encode(ProviderId.reminders)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"reminders\"")
    }
}
