import CompanionKit
import Foundation

/// What `syncNow()` is doing, for the UI to show — see `LinkStatusBar`'s sync readout.
enum SyncStatus: Equatable {
    case idle
    case syncing
    case succeeded(at: Date)
    case failed(at: Date, message: String)
}

/// Drives the pull → merge → push loop between the configured providers and the reader.
///
/// The loop, per `docs/companion-todo-list-design.md` §7 in the firmware repo and CompanionKit's own
/// doc comments:
///
/// 1. On `.ready` (screen acquired): build a `TodoDocument` by walking `SyncConfiguration` in order,
///    asking each enabled provider for its selected lists' items, and `client.pushTodoDocument(_:)`.
/// 2. On `onListStateAvailable` (fires as soon as `HELLO_OK`, before the screen is held — see
///    `CompanionEvent.listStateAvailable`'s doc comment): remember that a pull is owed; do not pull
///    yet.
/// 3. Once the screen is held: `client.pullListState()` for the accumulated `TodoDeviations`, then
///    `document.mergingDeviceDeviations(_:newRevision:)` to fold them into a new document revision.
/// 4. Write each changed item's completion back to *whichever provider owns it*, resolving the
///    deviation's wire `itemId` through `ProviderMapping`.
/// 5. `client.pushTodoDocument(_:)` the merged document at the new revision, which also clears the
///    device's diff.
///
/// Kept as its own type, not folded into `CompanionKitTransport`, because it is sync policy
/// (providers <-> TodoDocument), not link plumbing — the same separation `Snap2Ink`'s
/// `PrintStudioModel` keeps from its own transport.
@MainActor
final class TodoSyncEngine {
    private let transport: DisplayTransport
    private let providersById: [ProviderId: any TodoProvider]
    private let mapping: ProviderMapping

    /// Mirrors `DisplayTransport.onStateChange`'s shape — `AppModel` observes this the same way it
    /// observes transport state, so the UI can show "Syncing…"/"Synced 2:45 PM"/an error inline.
    var onStatusChange: ((SyncStatus) -> Void)?

    /// What to sync and in what order — set by `AppModel`, persisted by it too.
    var configuration: SyncConfiguration = .empty

    init(
        transport: DisplayTransport,
        providers: [any TodoProvider],
        mapping: ProviderMapping = ProviderMapping()
    ) {
        self.transport = transport
        self.providersById = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.mapping = mapping
    }

    /// The document revision last pushed. Starts at 0, matching a device that has never seen this
    /// peer's document — a push always replaces the whole document regardless of revision, so this
    /// resetting on relaunch is harmless (see `docs/companion-todo-list-design.md` §6/§7).
    private var currentRevision: UInt32 = 0

    /// Set by `AppModel` when `CompanionEvent.listStateAvailable` fires. Per §7, that can arrive
    /// before the screen is held — this only remembers a pull is owed, `syncNow()` decides when to
    /// act on it.
    private var pullOwed = false

    func markPullOwed() {
        pullOwed = true
    }

    func syncNow() async {
        guard let client = transport.client, transport.state == .ready else { return }

        onStatusChange?(.syncing)

        // Write-back runs before assembly, and independently of it: a deviation is the user's own
        // check-off on the reader, and it must reach its provider even if some *other* provider's
        // fetch is about to fail. Doing it first also means the document assembled below already
        // reflects the check-off, so the merge in step 3 has less to reconcile.
        var deviations: TodoDeviations?
        if pullOwed {
            do {
                let pulled = try await client.pullListState()
                await applyDeviations(pulled)
                deviations = pulled
                pullOwed = false
            } catch {
                DebugLog.shared.log("Todo sync: pulling list state failed: \(error)")
                onStatusChange?(.failed(at: Date(), message: "Couldn't read the reader's changes: \(error)"))
                return
            }
        }

        let (todoLists, failures) = await assembleLists()

        guard todoLists.count <= TodoDocumentBuilder.maxLists else {
            onStatusChange?(.failed(
                at: Date(),
                message: "Too many lists selected — \(todoLists.count) of a maximum \(TodoDocumentBuilder.maxLists)."
            ))
            return
        }

        do {
            var document = TodoDocument(revision: currentRevision, lists: todoLists)
            if let deviations {
                document = try document.mergingDeviceDeviations(
                    deviations,
                    newRevision: currentRevision + 1,
                    evenIfRevisionMismatched: true
                )
            }
            try await client.pushTodoDocument(document)
            currentRevision = document.revision

            // A push that succeeded while a provider failed is still a failure worth surfacing:
            // the lists that did sync are correct, but a persistently broken provider would
            // otherwise go unnoticed behind a green "Synced 14:32".
            if failures.isEmpty {
                onStatusChange?(.succeeded(at: Date()))
            } else {
                onStatusChange?(.failed(at: Date(), message: failures.joined(separator: "; ")))
            }
        } catch {
            DebugLog.shared.log("Todo sync failed: \(error)")
            onStatusChange?(.failed(at: Date(), message: "\(error)"))
        }
    }

    /// Walks the configuration in order and asks each enabled provider for its lists' items.
    ///
    /// **Failure is isolated per provider**: one backend being unreachable removes only its own
    /// lists from this pass, and the rest still reach the device. A failing provider contributes
    /// *zero* lists rather than its last-known-good ones — stale lists would silently re-show
    /// already-completed or deleted items as live, and a missing list is easier to understand than
    /// a lying one.
    private func assembleLists() async -> (lists: [TodoList], failures: [String]) {
        var todoLists: [TodoList] = []
        var failures: [String] = []

        for entry in configuration.providers where entry.enabled {
            guard let provider = providersById[entry.providerId], !entry.selectedListIds.isEmpty else {
                continue
            }
            do {
                let available = try await provider.fetchLists()
                let listsById = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let itemsByListId = try await provider.fetchItems(listIds: entry.selectedListIds)

                for listId in entry.selectedListIds {
                    // A selected list the provider no longer has is skipped, not an error — it was
                    // deleted at the source. The selection itself is left alone so a list that is
                    // only temporarily missing keeps its place in the user's ordering.
                    guard let list = listsById[listId] else { continue }
                    todoLists.append(TodoDocumentBuilder.buildList(
                        provider: entry.providerId,
                        list: list,
                        items: itemsByListId[listId] ?? [],
                        mapping: mapping
                    ))
                }
            } catch {
                DebugLog.shared.log("Todo sync: provider \(entry.providerId) failed: \(error)")
                failures.append("\(provider.displayName) didn't sync: \(error.localizedDescription)")
            }
        }
        return (todoLists, failures)
    }

    /// Routes each device-side check-off back to the provider that owns the item.
    ///
    /// The whole routing story is the `ProviderMapping` lookup: it returns the provider alongside
    /// the native id, so no provider is ever asked about an item that isn't its own and
    /// `TodoSyncEngine` never switches on provider kind. Adding a third backend changes nothing
    /// here.
    private func applyDeviations(_ deviations: TodoDeviations) async {
        for (itemId, checked) in deviations.checkedByItemId {
            guard let (providerId, nativeId) = mapping.nativeItemId(forItemId: itemId),
                  let provider = providersById[providerId] else { continue }
            do {
                try await provider.setCompleted(checked, forItemId: nativeId)
            } catch {
                DebugLog.shared.log("Todo sync: write-back to \(providerId) failed: \(error)")
            }
        }
    }
}
