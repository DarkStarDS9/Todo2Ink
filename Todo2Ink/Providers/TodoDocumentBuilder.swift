import CompanionKit
import Foundation

/// Maps provider lists onto CompanionKit's `TodoDocument` shape.
///
/// Every provider so far is flat — EventKit reminders have no subtasks or sections (both private
/// API), and Bring's purchase/recently split is a completion state, not a grouping — so each list
/// becomes one `TodoList` with a single ungrouped `TodoGroup` (empty label, matching the wire
/// format's own "empty label = ungrouped" convention). The group's `groupId` doesn't need
/// `ProviderMapping`-style stability: `TodoDeviations` key check-offs by `itemId` only, never by
/// group, so any constant works.
///
/// Knows nothing about EventKit or any other backend — it sees only `ProviderList`/`ProviderItem`.
/// That is what makes adding a provider a matter of writing one `TodoProvider` conformance and
/// touching nothing here.
enum TodoDocumentBuilder {
    private static let ungroupedGroupId: UInt16 = 1

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
        let todoItems = items.compactMap { item -> TodoItem? in
            guard let itemId = mapping.itemId(forProvider: provider, nativeId: item.id) else {
                // Only reachable with a exhausted UInt16 space; dropping the item is better than
                // failing the whole sync for every other list.
                return nil
            }
            return TodoItem(itemId: itemId, text: item.text, checked: item.checked)
        }
        return TodoList(
            listId: mapping.listId(forProvider: provider, nativeId: list.id),
            title: list.title,
            groups: [TodoGroup(groupId: ungroupedGroupId, items: todoItems)]
        )
    }
}
