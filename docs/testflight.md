# TestFlight deployment

## Status

| Piece | Status |
|---|---|
| Bundle ID `app.todo2ink.reminders` | Registered via the App Store Connect API (2026-08-12). |
| App Store distribution certificate | Reused the existing team certificate shared with Snap2Ink/SpokenFeedsMixer — certificates are team-wide, not app-specific. |
| Provisioning profile "Todo2Ink AppStore" | Created via the API and installed locally (2026-08-12). |
| `Todo2Ink/Configs/Local.xcconfig` (DEVELOPMENT_TEAM) | Created locally (2026-08-12), gitignored — needed for archive to sign at all. |
| App Store Connect **app record** | Created by hand in the web UI (2026-08-12) — the one step the API cannot do. |
| App icon | Present (`Todo2Ink/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`) — real artwork (phone syncing a checklist to the reader over BLE), supplied by the user. |
| First TestFlight build | **Uploaded 2026-08-12** — `xcodebuild -exportArchive` reported `Upload succeeded` / `** EXPORT SUCCEEDED **`. Should appear in TestFlight (may need a few minutes to finish processing before it's testable). |

Real account identifiers (entity/cert/profile IDs, key ID, issuer ID) live in a gitignored local
note (`docs/testflight.local.md`, create your own from `docs/testflight.local.md.example`) rather
than here — they're personal to one Apple Developer account, not project documentation.

Everything above is done; deploying again for a new build is just re-running the script below.

## Deploying

```bash
xcodegen generate   # regenerate Todo2Ink.xcodeproj if project.yml changed since last generate
./deploy-testflight.sh
```

Wraps `xcodebuild archive` (Release scheme, `-allowProvisioningUpdates` + the ASC key so it
provisions without an Xcode GUI login) and `xcodebuild -exportArchive` (manual signing style, named
profile, `destination: upload`) with pre-flight checks and error diagnosis — same shape as
`Snap2Ink`'s script in the sibling repo, adapted for this app's bundle id and env var names.
Confirmed working end to end against the real account (2026-08-12): archive, export, and upload all
succeeded.

**Bug found and fixed during that first real run:** the script has `set -uo pipefail` at the top,
and both the archive and export steps piped `xcodebuild` through `tee`/`grep` with a trailing
`|| true`. Under `pipefail`, a failing `xcodebuild` makes the whole piped command "fail" even though
`grep` itself succeeded, which triggered the `|| true` fallback — and running `true` immediately
after silently overwrote `$PIPESTATUS`, so `ARCHIVE_EXIT=${PIPESTATUS[0]}` read back `0` regardless
of what `xcodebuild` actually returned. In practice this meant a *real* archive failure (no
`DEVELOPMENT_TEAM` set, before `Local.xcconfig` existed) was reported as `✔ Archive complete`, and
the resulting export failure (no archive to export) was reported as `✔ Upload complete`. The
`|| true` was never needed — the whole pipeline already runs under `set +e`, so a nonzero exit
can't trip `set -e` — so it was just removed from both pipelines rather than reworked.

## App Store Connect API key

`deploy-testflight.sh` reads the key ID and issuer ID from the `TODO2INK_ASC_KEY_ID` /
`TODO2INK_ASC_ISSUER_ID` environment variables (set once in your shell profile) and expects the
key file at `~/.appstoreconnect/private_keys/AuthKey_<key id>.p8` (override with
`TODO2INK_ASC_KEY_PATH`) — never committed. `ExportOptions.plist` (also gitignored, copy from
`ExportOptions.plist.example`) carries your team id and provisioning profile name; both are already
filled in from `docs/testflight.local.md`.

Your actual key ID, issuer ID, team id, and the ASC entity IDs (bundle/cert/profile) belong in
`docs/testflight.local.md`, not in this tracked file.

## Regenerating the provisioning profile

If a capability change ever invalidates it, delete the old one and recreate via the App Store
Connect API (`DELETE profiles/<id>` then `POST profiles` with the bundle id and certificate id) —
see `docs/testflight.local.md` for this project's actual entity IDs and the full recipe.

## Always ask before deploying

After presenting changes, ask the user "should I deploy to TestFlight?" — never auto-deploy.
