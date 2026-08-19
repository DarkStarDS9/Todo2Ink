# Todo2Ink

Sync the to-do and shopping lists you choose to your XTEINK companion display running
[`xteink-companion-ble`](https://github.com/DarkStarDS9/xteink-companion-ble) firmware. Check an
item off on the reader — no phone needed — and it's checked off in the source app next time your
phone is nearby.

Two backends ship today: **Apple Reminders** and **Bring!**. The app syncs from *providers*, not
from one app, so adding a backend means writing one `TodoProvider` conformance and nothing else.

## Why Reminders, not Notes

Apple Notes has no public API: third-party apps cannot read or write its content. The only
automation surface is the Shortcuts app's own privileged Notes actions, which this app cannot call
directly, and there's no Shortcuts action to toggle a checklist item at all — so a Notes-backed
version of this app could not close the loop. **Reminders has a real public API, EventKit**, with
full read/write/observe access, which is what makes true two-way sync possible. See the firmware
repo's `docs/companion-todo-list-design.md` for the on-device half of this feature (protocol v12,
the `LIST` content shape, `LIST_STATE` sync-back).

## How it works

1. **Pick lists** — choose which lists, from which providers, sync to the reader, and in
   which order. Only the lists you select ever leave the phone.
2. **Pair** — over BLE, via [`CompanionKit`](https://github.com/DarkStarDS9/CompanionKit), the same
   library SpokenFeeds and Snap2Ink use.
3. **Push** — the selected lists across all providers flatten into one `TodoDocument`
   (protocol field `0x08`), reassembled on-device as `Screen::List`. Providers that group their
   items (Bring! does; Reminders can't) become labelled sections on the reader.
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
  Providers/                the TodoProvider protocol, id mapping, document builder, ordering
    Bring/                  Bring! client — auth, lists, localized catalogue
  Reminders/                EventKit access, list/reminder enumeration, completion write-back
  Sync/                     provider <-> TodoDocument sync engine (pull, merge, push)
  Diagnostics/              in-app debug log
  ViewModels/
  Views/                    SwiftUI — providers, list selection, per-provider settings
Todo2InkTests/              unit tests
docs/testflight.md          TestFlight deployment
```

## Providers

**Apple Reminders** uses EventKit and needs the Reminders permission the app asks for on first use.
Lists are flat: EventKit exposes no subtasks or sections, so a Reminders list reaches the reader as
one ungrouped run of items.

**Bring!** talks to Bring!'s own app API, which is *unofficial and undocumented* — there is no
public Bring! API, so this is what the Bring! app itself uses, and it can change or stop working
without notice. Todo2Ink is not affiliated with, endorsed by, or supported by Bring! Labs AG. Your
email and password are sent to Bring! to log in and are never stored: only the session tokens Bring!
returns are kept, in the iOS keychain. Bring! lists are grouped, so they reach the reader as the
same labelled sections the Bring! app shows, in the same order.

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

Both providers and the pull-merge-push sync loop are implemented and covered by unit tests, and the
app ships to TestFlight (`docs/testflight.md`). The simulator has no Bluetooth, so pairing and sync
must be exercised on real hardware.

## License

Todo2Ink is licensed under a modified MIT license — see [LICENSE](LICENSE).

**In short: you're free to use, modify, and distribute this code by any means — except an app
store.** Publishing this software, or any modified/derivative version of it, to the Apple App
Store, Google Play Store, or any other app store is reserved exclusively to the copyright holder
(Rainer Perl). Everything else the MIT license normally allows — running it, forking it, changing
it, sharing source or builds outside of an app store — is unrestricted.

Pull requests are welcome — the app store restriction is about who can *publish* it, not who can
*contribute* to it.
