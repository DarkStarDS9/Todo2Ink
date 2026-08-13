#!/usr/bin/env bash
# Deploy Todo2Ink to TestFlight (Release scheme).
# Run from anywhere — paths are derived from this script's location.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$SCRIPT_DIR/Todo2Ink.xcodeproj"
EXPORT_OPTIONS="$SCRIPT_DIR/ExportOptions.plist"

# Personal to this Apple Developer account -- never hardcoded/committed. Set these in your shell
# profile, or in a gitignored .env beside this script (see .env.example); see docs/testflight.md
# for where to find your own values. Useful because a shell profile like .zshrc is normally only
# sourced by interactive shells, so a non-interactive caller (e.g. a script, CI, or an agent's
# tool shell) would otherwise not see the exports even though a human's terminal does.
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
    set +a
fi
: "${TODO2INK_ASC_KEY_ID:?Set TODO2INK_ASC_KEY_ID (see docs/testflight.md)}"
: "${TODO2INK_ASC_ISSUER_ID:?Set TODO2INK_ASC_ISSUER_ID (see docs/testflight.md)}"
ASC_KEY_ID="$TODO2INK_ASC_KEY_ID"
ASC_ISSUER_ID="$TODO2INK_ASC_ISSUER_ID"
ASC_KEY_PATH="${TODO2INK_ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
ARCHIVE_PATH=/tmp/Todo2Ink.xcarchive
EXPORT_PATH=/tmp/Todo2Ink-export
ARCHIVE_LOG=/tmp/xcodebuild-archive-todo2ink.log
EXPORT_LOG=/tmp/xcodebuild-export-todo2ink.log

# ── Colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
err()  { echo -e "${RED}✘ $*${NC}" >&2; }
warn() { echo -e "${YELLOW}⚠ $*${NC}"; }
ok()   { echo -e "${GREEN}✔ $*${NC}"; }
step() { echo -e "\n${BOLD}→ $*${NC}"; }

# ── Pre-flight ──────────────────────────────────────────────────────────────
step "Pre-flight checks"

if [ ! -f "$ASC_KEY_PATH" ]; then
    err "ASC API key not found: $ASC_KEY_PATH"
    echo "  Place AuthKey_${ASC_KEY_ID}.p8 at ~/.appstoreconnect/private_keys/"
    exit 1
fi
ok "ASC key present"

if [ ! -f "$EXPORT_OPTIONS" ]; then
    err "ExportOptions.plist not found: $EXPORT_OPTIONS"
    echo "  Copy ExportOptions.plist.example to ExportOptions.plist and fill in your own"
    echo "  teamID and provisioning profile name (it's gitignored, personal per account)."
    exit 1
fi

if [ ! -f "$PROJECT/project.pbxproj" ]; then
    err "Todo2Ink.xcodeproj not found — run 'xcodegen generate' first."
    exit 1
fi
ok "Project present"

# ── Diagnose helpers ────────────────────────────────────────────────────────

diagnose_archive() {
    local log="$1"
    echo ""
    if grep -q "errSecInternalComponent" "$log"; then
        err "Keychain is locked — codesign can't access the signing certificate."
        echo "  Fix: unlock your login keychain, then re-run."
        echo "  Quick:    security unlock-keychain ~/Library/Keychains/login.keychain-db"
    elif grep -q "No profiles for" "$log"; then
        err "No provisioning profile found for app.todo2ink.reminders."
        echo "  The App ID capabilities may have changed (invalidating the existing profile)."
        echo "  Regenerate it via the App Store Connect API (see ExportOptions.plist's"
        echo "  provisioningProfiles entry for the expected name: 'Todo2Ink AppStore')."
    elif grep -q "requires a provisioning profile" "$log"; then
        err "Missing provisioning profile (manual signing)."
        echo "  Check that 'Todo2Ink AppStore' is installed in:"
        echo "    ~/Library/Developer/Xcode/UserData/Provisioning Profiles/"
    else
        err "Archive failed. Full log: $ARCHIVE_LOG"
        echo "  Last 20 lines:"
        tail -20 "$log" | sed 's/^/    /'
    fi
}

diagnose_export() {
    local log="$1"
    echo ""
    if grep -q "25 uploads" "$log" || grep -q "maximum number of builds" "$log" || grep -q "too many builds" "$log"; then
        err "Upload limit reached: Apple allows ~25 builds per app per 24-hour window."
        echo "  The window resets 24 h after your oldest in-window build."
    elif grep -q "No profiles for" "$log"; then
        err "No App Store distribution profile found at export time."
    elif grep -q "cloud signing permission" "$log" || grep -q "Cloud signing" "$log"; then
        err "Cloud signing error — do NOT use -allowProvisioningUpdates with -exportArchive."
        echo "  This flag is only valid for the archive step (new capabilities)."
    elif grep -q "Authentication credentials are missing" "$log" || grep -q "authenticationKey" "$log"; then
        err "ASC authentication failed."
        echo "  Check that $ASC_KEY_PATH is the correct key for ID $ASC_KEY_ID."
    elif grep -q "errSecInternalComponent" "$log"; then
        err "Keychain locked during export/upload."
        echo "  Fix: security unlock-keychain ~/Library/Keychains/login.keychain-db"
    elif grep -qi "no suitable application records were found" "$log" || grep -qi "does not match an app record" "$log"; then
        err "No App Store Connect app record exists yet for app.todo2ink.reminders."
        echo "  Create it once via the web UI: App Store Connect → My Apps → + → New App"
        echo "  (bundle ID app.todo2ink.reminders is already registered — just attach it there)."
    else
        err "Export/upload failed. Full log: $EXPORT_LOG"
        echo "  Last 20 lines:"
        tail -20 "$log" | sed 's/^/    /'
    fi
}

# ── Step 1: clean ──────────────────────────────────────────────────────────
step "Cleaning previous archive"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
ok "Cleaned"

# ── Step 2: archive ────────────────────────────────────────────────────────
step "Archiving (Release scheme)"
echo "  Logging to $ARCHIVE_LOG"

set +e
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "Todo2Ink" \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    2>&1 | tee "$ARCHIVE_LOG" | grep -E "^(=== BUILD|=== ARCHIVE|.*error:|.*warning:.*profile|.*CodeSign|PhaseScriptExecution|CompileSwift)"
ARCHIVE_EXIT=${PIPESTATUS[0]}
set -e

if [ $ARCHIVE_EXIT -ne 0 ]; then
    diagnose_archive "$ARCHIVE_LOG"
    exit 1
fi
ok "Archive complete: $ARCHIVE_PATH"

# ── Step 3: export + upload ────────────────────────────────────────────────
step "Exporting and uploading to TestFlight"
echo "  Logging to $EXPORT_LOG"

set +e
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    2>&1 | tee "$EXPORT_LOG" | grep -E "(Upload|Export|error:|Uploading|Done|No profiles|FAILED)"
EXPORT_EXIT=${PIPESTATUS[0]}
set -e

if [ $EXPORT_EXIT -ne 0 ]; then
    diagnose_export "$EXPORT_LOG"
    exit 1
fi

echo ""
ok "Upload complete — build will appear in TestFlight within a few minutes."
