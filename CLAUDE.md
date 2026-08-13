# CLAUDE.md — Todo2Ink

## What this app is

Syncs user-selected Apple Reminders lists to an XTEINK companion display over BLE, using the
firmware's ToDo List mode (protocol v12, `docs/companion-todo-list-design.md` in the firmware
repo). See `README.md` for why Reminders and not Notes — that decision is load-bearing, not a
preference: Notes has no public API and no way to toggle a checklist item programmatically, so it
cannot support the two-way sync this app exists to provide.

## Repo hygiene

**This repo is meant to be published eventually and must stay free of private information** — no
Apple Developer Team IDs, no provisioning profiles, no signing certificates, no ASC API keys. The
pattern already in place:

- `Todo2Ink/Configs/Local.xcconfig` is gitignored; `Local.xcconfig.example` (committed) is the
  placeholder every contributor copies and fills in locally.
- `ExportOptions.plist` is likewise gitignored, with a `.example` companion when one exists.
- Before any commit that touches `Configs/`, signing settings, or CI config, grep the actual diff
  for a literal team id or key material — a file being gitignored doesn't stop someone from pasting
  a real value into a tracked file by mistake.

## CompanionKit dependency

The dependency in `project.yml` is the versioned [`CompanionKit`](https://github.com/DarkStarDS9/CompanionKit)
package (major version = protocol version), pinned `from: 12.0.0`. To work on the kit itself
alongside Todo2Ink: drag a local CompanionKit checkout into the Xcode workspace — Xcode shadows the
remote package reference with the local one automatically, no project file changes needed.

CompanionKit already implements the phone-side half of ToDo List sync in full:
`TodoDocument`/`TodoList`/`TodoGroup`/`TodoItem` (the `0x08` wire codec),
`CompanionClient.pushTodoDocument(_:)`, `.pullListState()` (loops `LIST_STATE_GET` until `n = 0`),
`TodoDeviations`, and `TodoDocument.mergingDeviceDeviations(_:newRevision:)`. Todo2Ink's own job is
narrower than it might look: map Reminders onto these types, and drive the pull → merge → push
loop. Do not reimplement any of the wire codec or pagination here — if something about the sync
feels missing, check CompanionKit's source first, since it was built for exactly this consumer.

## Providers

The app syncs from *providers*, not from Reminders specifically. Apple Reminders is one conformance
of `TodoProvider` (`Todo2Ink/Providers/TodoProvider.swift`) and any future backend is another —
`TodoSyncEngine`, `AppModel` and every view work from the protocol alone and never branch on which
backend they are talking to. Adding one means writing a conformance and adding a line to
`Todo2InkApp.makeProviders()`; nothing else should need to change, and if it does, that's a bug in
the abstraction rather than a normal cost.

`SyncConfiguration` holds the user's ordering: providers in order, and each provider's selected
lists in order. The reader has only one flat run of lists and no concept of a provider, so those two
orderings exist to compose into that one flat run — see `SyncConfiguration.flattened()`, which is
the definition of what the device shows.

## Data model notes worth remembering

- **`itemId` is a wire `u16`, phone-owned and opaque to the device.** `ProviderMapping` owns the
  persisted `(providerId, native id) -> UInt16` table, assigned incrementally and never reused, so
  ids stay stable across syncs even though the device treats them as meaningless. **Keys must stay
  namespaced by provider**: the u16 space is shared by every backend, and two providers' native id
  formats are not allowed to be assumed distinct.
- **The device counts lists in a `u8` — 255 lists maximum**, and that ceiling applies to the
  *flattened* provider × list total, not per provider. `TodoDocumentBuilder.maxLists` mirrors
  CompanionKit's own check so the UI can warn before a push fails.
- **Every provider so far is flat** — EventKit reminders have no subtasks or sections (both private
  API), and Bring's purchase/recently split is a completion state rather than a grouping. Each list
  becomes one `TodoList` with a single ungrouped `TodoGroup` (empty label), matching the wire
  format's own "empty label = ungrouped" convention.
- **Only user-selected lists sync** — never all of them by default, for any provider.
- **One provider's failure must not sink the others.** `TodoSyncEngine.assembleLists()` isolates
  per provider: a failing one contributes zero lists (never stale ones) and the rest still reach the
  device, but the overall `SyncStatus` still reports the failure.

## Upstream relationship

This app has no upstream to sync from — it isn't a fork of anything. It has a *sibling* relationship
with the `xteink-companion-ble` firmware repo (the wire contract) and the `CompanionKit` repo (the
Swift client library): protocol or client changes are requested there, never made by editing a
vendored copy here.
