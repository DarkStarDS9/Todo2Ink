import CompanionKit
import XCTest
@testable import Todo2Ink

/// Asserts the document a provider's lists turn into, including that it survives the wire codec —
/// a correct-looking `TodoList` array that `encoded()` rejects is not a correct document.
final class TodoDocumentBuilderTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var mapping: ProviderMapping!

    override func setUp() {
        super.setUp()
        suiteName = "TodoDocumentBuilderTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        mapping = ProviderMapping(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func build(_ provider: ProviderId, _ title: String, _ items: [ProviderItem]) -> TodoList {
        TodoDocumentBuilder.buildList(
            provider: provider,
            list: ProviderList(id: "list-\(title)", title: title),
            items: items,
            mapping: mapping
        )
    }

    func testEachListBecomesOneUngroupedGroup() {
        let list = build(.reminders, "Groceries", [
            ProviderItem(id: "a", text: "Milk", checked: false),
            ProviderItem(id: "b", text: "Bread", checked: true),
        ])

        XCTAssertEqual(list.title, "Groceries")
        XCTAssertEqual(list.groups.count, 1)
        XCTAssertEqual(list.groups[0].label, "", "empty label is the wire's 'ungrouped' convention")
        XCTAssertEqual(list.groups[0].items.map(\.text), ["Milk", "Bread"])
        XCTAssertEqual(list.groups[0].items.map(\.checked), [false, true])
    }

    func testItemOrderIsPreserved() {
        let items = (1...20).map { ProviderItem(id: "\($0)", text: "Item \($0)", checked: false) }
        let list = build(.reminders, "Long", items)
        XCTAssertEqual(list.groups[0].items.map(\.text), items.map(\.text))
    }

    /// Two providers' lists in one document must not share a `listId`, and their items must not
    /// share an `itemId` — even when both backends hand out the same native ids.
    func testDocumentAcrossProvidersHasNoIdCollisions() throws {
        let reminders = TodoDocumentBuilder.buildList(
            provider: .reminders,
            list: ProviderList(id: "same", title: "Reminders List"),
            items: [ProviderItem(id: "same-item", text: "A", checked: false)],
            mapping: mapping
        )
        let bring = TodoDocumentBuilder.buildList(
            provider: .bring,
            list: ProviderList(id: "same", title: "Bring List"),
            items: [ProviderItem(id: "same-item", text: "B", checked: false)],
            mapping: mapping
        )

        XCTAssertNotEqual(reminders.listId, bring.listId)
        XCTAssertNotEqual(reminders.groups[0].items[0].itemId, bring.groups[0].items[0].itemId)

        let document = TodoDocument(revision: 1, lists: [reminders, bring])
        XCTAssertNoThrow(try document.encoded())
    }

    /// When no item has a section, the output must be byte-identical to a provider (Reminders) that
    /// never sets one — a Bring! list with an unresolvable catalogue must still look like today.
    func testAllNilSectionsProduceExactlyOneUngroupedGroup() {
        let list = build(.bring, "Flat", [
            ProviderItem(id: "a", text: "Milk", checked: false, section: nil),
            ProviderItem(id: "b", text: "Bread", checked: true, section: nil),
        ])

        XCTAssertEqual(list.groups.count, 1)
        XCTAssertEqual(list.groups[0].label, "")
        XCTAssertEqual(list.groups[0].items.map(\.text), ["Milk", "Bread"])
    }

    /// Items with the same section land in one group; groups appear in the order their section is
    /// first seen in the item array, so a provider controls section order simply by ordering it.
    func testItemsAreGroupedBySectionInFirstSeenOrder() {
        let list = build(.bring, "Grouped", [
            ProviderItem(id: "a", text: "Apples", checked: false, section: "Fruit"),
            ProviderItem(id: "b", text: "Milk", checked: false, section: "Dairy"),
            ProviderItem(id: "c", text: "Pears", checked: false, section: "Fruit"),
        ])

        XCTAssertEqual(list.groups.map(\.label), ["Fruit", "Dairy"])
        XCTAssertEqual(list.groups[0].items.map(\.text), ["Apples", "Pears"])
        XCTAssertEqual(list.groups[1].items.map(\.text), ["Milk"])
    }

    /// Unsectioned items (Bring!'s recently-bought tail) sort last regardless of where they appear
    /// among the sectioned ones.
    func testTheUngroupedGroupSortsLastEvenWhenItAppearsFirst() {
        let list = build(.bring, "Mixed", [
            ProviderItem(id: "a", text: "Butter", checked: true, section: nil),
            ProviderItem(id: "b", text: "Apples", checked: false, section: "Fruit"),
        ])

        XCTAssertEqual(list.groups.map(\.label), ["Fruit", ""])
        XCTAssertEqual(list.groups[0].items.map(\.text), ["Apples"])
        XCTAssertEqual(list.groups[1].items.map(\.text), ["Butter"])
    }

    /// The wire counts lists in a `u8`. `TodoDocumentBuilder.maxLists` mirrors CompanionKit's own
    /// check so the UI can warn first; this asserts the two agree, so the mirror can't drift.
    func testMaxListsMatchesTheWireLimit() throws {
        let list = build(.reminders, "L", [])
        let atLimit = TodoDocument(
            revision: 1,
            lists: (0..<TodoDocumentBuilder.maxLists).map { index in
                TodoList(listId: UInt16(index + 1), title: "L\(index)", groups: list.groups)
            }
        )
        XCTAssertNoThrow(try atLimit.encoded())

        let overLimit = TodoDocument(
            revision: 1,
            lists: (0...TodoDocumentBuilder.maxLists).map { index in
                TodoList(listId: UInt16(index + 1), title: "L\(index)", groups: list.groups)
            }
        )
        XCTAssertThrowsError(try overLimit.encoded())
    }
}
