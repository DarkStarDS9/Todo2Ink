# Todo2Ink

Sync the Reminders lists you choose to your XTEINK companion display running
[`xteink-companion-ble`](https://github.com/DarkStarDS9/xteink-companion-ble) firmware. Check an
item off on the reader — no phone needed — and it's checked off in Reminders next time your phone
is nearby.

## Why Reminders, not Notes

Apple Notes has no public API: third-party apps cannot read or write its content. The only
automation surface is the Shortcuts app's own privileged Notes actions, which this app cannot call
directly, and there's no Shortcuts action to toggle a checklist item at all — so a Notes-backed
version of this app could not close the loop. **Reminders has a real public API, EventKit**, with
full read/write/observe access, which is what makes true two-way sync possible. See the firmware
repo's `docs/companion-todo-list-design.md` for the on-device half of this feature (protocol v12,
the `LIST` content shape, `LIST_STATE` sync-back).

## How it works

1. **Pick lists** — choose which Reminders lists sync to the reader.
2. **Pair** — over BLE, via [`CompanionKit`](https://github.com/DarkStarDS9/CompanionKit), the same
   library SpokenFeeds and Snap2Ink use.
3. **Push** — selected lists become one `TodoDocument` (protocol field `0x08`), reassembled
   on-device as `Screen::List`.
4. **Check off, anywhere** — an item can be toggled on the reader with no phone connected. The
   device accumulates the deviations and reports them back (`LIST_STATE_AVAIL`) the next time this
   app is in the foreground.
5. **Pull, merge, re-push** — this app pulls the device's diff (`pullListState()`), merges it into
   its own Reminders-backed snapshot (writing completions back via EventKit), and pushes a new
   revision.

## Repo layout

```
project.yml                 XcodeGen project definition — the .xcodeproj is generated, not committed
Todo2Ink/
  Identity/                 appId, installId, button map, device icon
  Transport/                DisplayTransport seam + CompanionKit adapter
  Reminders/                EventKit access, list/reminder enumeration, completion write-back
  Sync/                     TodoDocument <-> Reminders sync engine (pull, merge, push)
  ViewModels/
  Views/                    SwiftUI — list picker, pairing screen
Todo2InkTests/               unit tests
```

## Building

```sh
brew install xcodegen
xcodegen generate
xcodebuild -scheme Todo2Ink -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -scheme Todo2Ink -destination 'platform=iOS Simulator,name=iPhone 17' test
```

The simulator has no Bluetooth, so pairing and sync only work on a real device.

### On a device

Signing uses automatic signing and the Apple Development certificate already in the keychain, with
the team id supplied by `Todo2Ink/Configs/Local.xcconfig` — copy
`Todo2Ink/Configs/Local.xcconfig.example` to that path (gitignored, personal per machine) and fill
in your own team id (find it from your Apple Development certificate's **OU** field in Keychain
Access). The **first** signed build has to happen in Xcode so macOS can prompt for keychain access —
click **Always Allow**, after which command-line builds work unattended.

On another machine or account, override the team on the command line instead; nothing else needs
changing:

```sh
xcodebuild -scheme Todo2Ink -destination 'generic/platform=iOS' DEVELOPMENT_TEAM=YOURTEAM build
```

## Firmware dependency

The app depends on [`CompanionKit`](https://github.com/DarkStarDS9/CompanionKit), a versioned Swift
package whose major version tracks the protocol version (see `project.yml`'s `packages:` entry);
`Package.resolved` records the exact revision this app was built against. Todo2Ink never edits the
firmware or CompanionKit repos directly; protocol changes are requested, not made here.

To work on CompanionKit itself alongside Todo2Ink, drag a local checkout into the Xcode workspace —
Xcode shadows the remote package reference automatically, no project file changes needed.

## Status

Pairing reuses CompanionKit exactly as Snap2Ink does. The Reminders read/write layer
(`Todo2Ink/Reminders/`) and the pull-merge-push sync loop (`Todo2Ink/Sync/TodoSyncEngine.swift`) are
implemented, including the Reminders access prompt. Not yet paired against a real reader to confirm
HELLO/ACQUIRE and the sync loop end to end — that needs a physical device and reader.

See `docs/testflight.md` for TestFlight deployment status and the remaining one-time account setup
(bundle ID registration, app record, provisioning profile) before a build can be uploaded.

## License

Todo2Ink is licensed under a modified MIT license — see [LICENSE](LICENSE).

**In short: you're free to use, modify, and distribute this code by any means — except an app
store.** Publishing this software, or any modified/derivative version of it, to the Apple App
Store, Google Play Store, or any other app store is reserved exclusively to the copyright holder
(Rainer Perl). Everything else the MIT license normally allows — running it, forking it, changing
it, sharing source or builds outside of an app store — is unrestricted.

Pull requests are welcome — the app store restriction is about who can *publish* it, not who can
*contribute* to it.
