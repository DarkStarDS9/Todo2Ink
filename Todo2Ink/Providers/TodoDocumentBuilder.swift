import CompanionKit
import Foundation

/// Maps provider lists onto CompanionKit's `TodoDocument` shape.
///
/// Not every provider is flat: EventKit reminders have no subtasks or sections (both private API)
/// and always produce a single ungrouped `TodoGroup`, but Bring! sets `ProviderItem.section` from its
/// article catalogue, and this builder groups by it — items with the same non-nil `section` land in
/// one `TodoGroup` (label = the section), in the order their section is first encountered in `items`,
/// so a provider controls section order simply by ordering its array. Items with `section == nil`
/// land in a single trailing group with an empty label, matching the wire format's own "empty label =
/// ungrouped" convention; it sorts last regardless of where those items appear in `items`, since for
/// Bring! that group is the unsectioned "recently bought" tail. When no item has a section, this
/// degrades to exactly one ungrouped group — byte-identical to a provider that never sets `section` at
/// all, which is why Reminders is unaffected. `groupId`s are assigned 1, 2, 3… within the list; they
/// don't need `ProviderMapping`-style stability because `TodoDeviations` key check-offs by `itemId`
/// only, never by group.
///
/// Knows nothing about EventKit, Bring! or any other backend — it sees only
/// `ProviderList`/`ProviderItem`. That is what makes adding a provider a matter of writing one
/// `TodoProvider` conformance and touching nothing here.
enum TodoDocumentBuilder {
    private static let ungroupedLabel = ""

    /// The device counts lists in a `u8`, so this is a hard wire limit, not a guideline — and it
    /// applies to the *flattened* provider × list total, which is why it is checked here rather than
    /// per provider. Duplicated from `TodoDocument.encoded()`'s own check so the UI can say
    /// something useful before a push fails.
    static let maxLists = 255

    static func buildList(
        provider: ProviderId,
        list: ProviderList,
        items: [ProviderItem],
        mapping: ProviderMapping
    ) -> TodoList {
        // Sectioned groups keep the order their label was first seen in; the ungrouped label is
        // reserved up front so it always sorts last, even when unsectioned items appear first.
        var itemsByLabel: [String: [TodoItem]] = [:]
        var labelOrder: [String] = []
        var sawSectioned = false

        for item in items {
            guard let itemId = mapping.itemId(forProvider: provider, nativeId: item.id) else {
                // Only reachable with an exhausted UInt16 space; dropping the item is better than
                // failing the whole sync for every other list.
                continue
            }
            let todoItem = TodoItem(itemId: itemId, text: item.text, checked: item.checked)
            let label = item.section ?? ungroupedLabel
            if item.section != nil { sawSectioned = true }
            if itemsByLabel[label] == nil {
                labelOrder.append(label)
            }
            itemsByLabel[label, default: []].append(todoItem)
        }

        // No provider so far mixes sectioned and unsectioned items with none sectioned at all, but
        // the degenerate case — no item anywhere has a section — must still produce the one ungrouped
        // group a flat provider like Reminders always has, not an empty group list.
        if !sawSectioned {
            let allItems = labelOrder.flatMap { itemsByLabel[$0] ?? [] }
            return TodoList(
                listId: mapping.listId(forProvider: provider, nativeId: list.id),
                title: list.title,
                groups: [TodoGroup(groupId: 1, items: allItems)]
            )
        }

        var orderedLabels = labelOrder.filter { $0 != ungroupedLabel }
        if labelOrder.contains(ungroupedLabel) {
            orderedLabels.append(ungroupedLabel)
        }

        let groups = orderedLabels.enumerated().map { index, label in
            TodoGroup(groupId: UInt16(index + 1), label: label, items: itemsByLabel[label] ?? [])
        }
        return TodoList(
            listId: mapping.listId(forProvider: provider, nativeId: list.id),
            title: list.title,
            groups: groups
        )
    }
}
