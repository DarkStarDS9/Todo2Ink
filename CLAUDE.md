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
- **Reminders is flat, Bring is grouped, and `TodoDocumentBuilder` handles both from one field.**
  EventKit reminders genuinely have no subtasks or sections (both private API) and always set
  `ProviderItem.section` to nil, which the builder collapses into the single ungrouped `TodoGroup`
  (empty label) the wire format's own "empty label = ungrouped" convention describes. Bring sets a
  section per item, and the builder makes one labelled `TodoGroup` per distinct one, in the order
  the provider's array first mentions it — so a provider controls section order by ordering its
  items, and the builder still knows nothing about any backend. Bring's recently-bought items get
  Bring's own "recently bought" header (`BringCatalogClient.recentlyLabel(forList:)`) rather than the
  nil-section group — that header isn't in the API or catalogue anywhere, so it's a small hardcoded
  per-language table, keyed by the list's own locale like every other section label. It always sorts
  last because the provider appends it after every purchase section regardless of item order.
- **Bring keys items *and sections* by a canonical name and displays a localized one** —
  `"Pommes Chips"` on the wire is `"Chips"` in a de-DE list, and section `"Früchte & Gemüse"` is
  headed `"Obst & Gemüse"` there. Both come from one file, `web.getbring.com/locale/catalog.{locale}.json`
  (13 sections, ~360 articles; `articles.{locale}.json` is the same names without the sections and is
  no longer used). `BringCatalogClient` resolves them; the canonical name stays the item's identity
  everywhere else, because it is the only name Bring accepts in a write, and `sectionId` likewise
  stays canonical so it can be ordered and compared across locales. A locale Bring publishes no
  catalogue for (`en-DE` 404s) falls back to the base `de-CH` catalogue **for sections only** — ids
  are locale-independent, so an unsupported locale still gets a grouped list, just with canonical
  names. Per-list section order comes from `listSectionOrder` in the user settings — a plain JSON
  array of section ids, confirmed against a real account, though still undocumented anywhere public,
  so parsing stays defensive and falls back to the catalogue's own order.
- **A section the catalogue doesn't have is where the user's own items go.** `listSectionOrder` ends
  with one entry that is in no catalogue — `"Eigene Artikel"` on a German account — and that is what
  Bring files a hand-typed item under. Most real lists are mostly hand-typed, so treating those items
  as merely unsectioned collapses the whole list into one nameless run; `BringCatalogClient.ownArticlesSection(forList:)`
  recovers the section as the order entry the catalogue can't account for, which also means it
  arrives already localized and already in the position the user put it.
- **Only user-selected lists sync** — never all of them by default, for any provider.
- **One provider's failure must not sink the others.** `TodoSyncEngine.assembleLists()` isolates
  per provider: a failing one contributes zero lists (never stale ones) and the rest still reach the
  device, but the overall `SyncStatus` still reports the failure.

## Upstream relationship

This app has no upstream to sync from — it isn't a fork of anything. It has a *sibling* relationship
with the `xteink-companion-ble` firmware repo (the wire contract) and the `CompanionKit` repo (the
Swift client library): protocol or client changes are requested there, never made by editing a
vendored copy here.
