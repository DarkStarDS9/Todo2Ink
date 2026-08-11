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

## Data model notes worth remembering

- **`itemId` is a wire `u16`, phone-owned and opaque to the device.** EKReminder's stable identity
  is `calendarItemIdentifier` (a string). `ReminderMapping` owns a persisted
  `calendarItemIdentifier -> UInt16` table, assigned incrementally and never reused, so ids stay
  stable across syncs even though the device treats them as meaningless.
- **EventKit reminders are flat** — no subtasks, no sections (both are private API). Map each
  `EKCalendar` (a Reminders list) to one `TodoList` with a single ungrouped `TodoGroup` (empty
  label), matching the wire format's own "empty label = ungrouped" convention.
- **Only user-selected Reminders lists sync** — never all of them by default.

## Upstream relationship

This app has no upstream to sync from — it isn't a fork of anything. It has a *sibling* relationship
with the `xteink-companion-ble` firmware repo (the wire contract) and the `CompanionKit` repo (the
Swift client library): protocol or client changes are requested there, never made by editing a
vendored copy here.
