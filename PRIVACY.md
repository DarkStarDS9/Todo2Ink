# Privacy Policy — Todo2Ink

_Last updated: 19 August 2026_

**Todo2Ink has no servers and no accounts of its own, and collects nothing about you.** Your lists
move between the apps you already use and your own e-ink display, over Bluetooth, in the same room.

## What the app touches, and where it goes

| Data | Why | Where it goes |
|---|---|---|
| Apple Reminders lists you select | To show them on your display, and to check items off when you check them off on the display | Read and written on your iPhone through Apple's EventKit. Never sent anywhere except, over Bluetooth, to your own display. |
| Bring! lists you select (optional) | Same, for Bring! shopping lists | Fetched from and written back to **Bring!'s own servers** using your Bring! account — see below. |
| Your Bring! email and password (optional) | To log in to Bring! | Sent to Bring! once, to obtain a session, and **never stored**. Only the session tokens Bring! returns are kept, in the iOS keychain on your device. |
| Which lists you sync, and their order | To remember your choices | Stored locally on the device. |
| Bluetooth | To find and connect to your display | Local radio only. No location is derived from it, and Todo2Ink does not request location access. |

## Third parties

Todo2Ink contacts exactly two hosts, both Bring!'s, and only if you choose to use the Bring!
provider:

- `api.getbring.com` — your Bring! lists and login, using Bring!'s own app API.
- `web.getbring.com` — Bring!'s public article catalogue, used to show item and section names in
  your language.

**Todo2Ink is not affiliated with, endorsed by, or supported by Bring! Labs AG.** The API it uses
is the one Bring!'s own app uses; it is unofficial and undocumented. What Bring! does with the data
in your Bring! account is governed by Bring!'s privacy policy, not this one. If you never log in to
Bring!, the app makes no network requests at all.

Apple Reminders data is never sent off your device by Todo2Ink. (Apple may sync it via iCloud if
you have that turned on — that is your existing Apple setup, not something this app does.)

## What Todo2Ink does not do

- No account with the developer, and no developer-run server: there is nowhere for your data to be
  collected to.
- No analytics, no telemetry, no crash reporting SDK, no advertising, no tracking, no third-party
  SDKs of any kind.
- Nothing is sold or shared with anyone.

Apple may provide the developer with aggregate, anonymous download and crash statistics through
App Store Connect. That is Apple's data collection, governed by Apple's privacy policy, and it
does not identify you.

## Permissions the app asks for

- **Reminders** — to read the lists you choose and to check items off. Only lists you explicitly
  select are ever read.
- **Bluetooth** — to connect to your display.

## Children

Todo2Ink is not directed at children and collects no data from anyone, of any age.

## Changes

Any change to this policy will be committed to this file in the public repository, so its full
history is visible at
<https://github.com/DarkStarDS9/Todo2Ink/commits/main/PRIVACY.md>.

## Contact

Questions: open an issue at <https://github.com/DarkStarDS9/Todo2Ink/issues>.
