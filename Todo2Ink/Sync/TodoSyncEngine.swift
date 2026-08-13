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
/// 1. On `.ready` (screen acquired), and again whenever `onListStateAvailable` says the reader has
///    something to report: `client.pullDeviations()` for the accumulated `TodoDeviations`. Every run
///    pulls, because a push clears the device's diff and so must never be the first thing a session
///    does.
/// 2. Build a `TodoDocument` by walking `SyncConfiguration` in order, asking each enabled provider
///    for its selected lists' items.
/// 3. Write each changed item's completion back to *whichever provider owns it*, resolving the
///    deviation's wire `itemId` through `ProviderMapping`. This happens before assembly, so the
///    document built in step 2 already reflects the check-off.
/// 4. `document.mergingDeviceDeviations(_:newRevision:)` to fold the deviations into a new revision,
///    then `client.pushDocument(_:)`, which also clears the device's diff.
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
    ///
    /// It is a *trigger*, never a gate: `performSync()` pulls on every run whether or not this is
    /// set, because gaining the screen and the list-state notification are two independent arrivals
    /// and the notification is routinely the later one. Gating the pull on it lost a whole session's
    /// check-offs to a 36 ms gap — the screen-gained sync pushed first, and a push replaces the
    /// device's document and clears its diff, so the deviations were gone before anyone read them.
    /// A pull with nothing to report is one cheap round trip; a pull skipped is silent data loss.
    private var pullOwed = false

    func markPullOwed() {
        pullOwed = true
    }

    /// Whether a sync is in flight, and whether another was asked for while it was.
    ///
    /// Being `@MainActor` prevents a data race but not reentrancy: every `await` below is a point
    /// where a second `syncNow()` can start, and the app has several triggers that fire together
    /// (foregrounding, regaining the screen, a list-state notification). Two overlapping runs lose
    /// the user's check-offs outright — the first pulls the deviations and clears `pullOwed`, the
    /// second sees nothing owed and pushes a document assembled from a provider that hasn't been
    /// written to yet, putting every box back. So a request that arrives mid-run is remembered and
    /// serviced afterwards rather than run alongside.
    private var isSyncing = false
    private var syncRequestedWhileSyncing = false

    /// How many times this run has abandoned an assembled document because the reader reported
    /// changes while it was being assembled. Bounded so a device notifying continuously can't hold
    /// the loop off the push forever: past the bound we push anyway, and the notification that
    /// arrives next starts a fresh `syncNow()` that pulls before it pushes. That costs a cycle, not
    /// a check-off.
    private var restartsThisRun = 0

    func syncNow() async {
        guard !isSyncing else {
            syncRequestedWhileSyncing = true
            return
        }
        isSyncing = true
        restartsThisRun = 0
        defer { isSyncing = false }

        repeat {
            syncRequestedWhileSyncing = false
            await performSync()
        } while syncRequestedWhileSyncing
    }

    private func performSync() async {
        guard let client = transport.client, transport.state == .ready else { return }

        onStatusChange?(.syncing)

        // Write-back runs before assembly, and independently of it: a deviation is the user's own
        // check-off on the reader, and it must reach its provider even if some *other* provider's
        // fetch is about to fail. Doing it first also means the document assembled below already
        // reflects the check-off, so the merge in step 3 has less to reconcile.
        var deviations: TodoDeviations?
        var writeBackFailures: [String] = []
        do {
            let pulled = try await client.pullDeviations()
            pullOwed = false
            if !pulled.checkedByItemId.isEmpty {
                writeBackFailures = await applyDeviations(pulled)
                deviations = pulled
            }
        } catch {
            DebugLog.shared.log("Todo sync: pulling list state failed: \(error)")
            onStatusChange?(.failed(at: Date(), message: "Couldn't read the reader's changes: \(error)"))
            return
        }

        let (todoLists, assemblyFailures) = await assembleLists()
        let failures = writeBackFailures + assemblyFailures

        guard todoLists.count <= TodoDocumentBuilder.maxLists else {
            onStatusChange?(.failed(
                at: Date(),
                message: "Too many lists selected — \(todoLists.count) of a maximum \(TodoDocumentBuilder.maxLists)."
            ))
            return
        }

        // Assembly is seconds of network, and the reader can be checked off during it. Since a push
        // clears the device's diff, pushing now would discard whatever arrived — so hand the run
        // back to `syncNow()`, which starts again from the pull.
        if pullOwed, restartsThisRun < 3 {
            restartsThisRun += 1
            DebugLog.shared.log("Todo sync: reader reported changes mid-sync; restarting before push")
            syncRequestedWhileSyncing = true
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
            try await client.pushDocument(document)
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
    /// Returns one sentence per check-off that did not reach its provider, for the status readout.
    ///
    /// A failure here is worse than a failed fetch and has to be at least as visible: the push that
    /// follows clears the device's diff, so a check-off whose write-back threw is gone from both
    /// sides — the provider never heard about it, and the reader has stopped remembering it. There
    /// is no retry queue that could rescue it, which is exactly why the user has to be told rather
    /// than shown a green "Synced".
    private func applyDeviations(_ deviations: TodoDeviations) async -> [String] {
        DebugLog.shared.log("Todo sync: applying \(deviations.checkedByItemId.count) deviation(s)")
        var failures: [String] = []
        for (itemId, checked) in deviations.checkedByItemId {
            guard let (providerId, nativeId) = mapping.nativeItemId(forItemId: itemId),
                  let provider = providersById[providerId]
            else {
                // A deviation the mapping can't place is a check-off that will never reach any
                // backend, and the next push then puts the box back — the exact failure this whole
                // path exists to prevent. It was a silent `continue` once; it never should have
                // been, because there is no way to see it from the outside.
                DebugLog.shared.log("Todo sync: no provider for deviation on item \(itemId); dropped")
                continue
            }
            do {
                try await provider.setCompleted(checked, forItemId: nativeId)
            } catch {
                DebugLog.shared.log("Todo sync: write-back to \(providerId) failed: \(error)")
                failures.append("\(provider.displayName) didn't record a check-off: \(error.localizedDescription)")
            }
        }
        return failures
    }
}
