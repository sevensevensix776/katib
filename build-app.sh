#!/bin/bash
# Build Katib (كاتب — The Scribe) as a macOS app bundle.
#
# Modes:
#   ./build-app.sh              Local dev build. Signs with the team's
#                               Developer ID when present, else ad-hoc.
#                               No notarization, no DMG.
#
#   --edition=<dir>             Build an edition (Katib plus a team's extras):
#                                 <dir>/edition.json       {"sentryDSN": "...",
#                                                           "updateManifestURL": "..."}
#                                 <dir>/Plugins/           bundled plugins
#                               Without it the app has no crash reporting
#                               and no plugins until the user adds some.
#
#   ./build-app.sh --release    Production build for team distribution.
#                               Requires a "Developer ID Application" cert
#                               and a notarytool keychain profile. Signs with
#                               hardened runtime, notarizes, staples, and
#                               produces Katib-<version>.dmg.
#
# One-time setup for --release:
#   1. Install the 776 "Developer ID Application" certificate in your Keychain
#      (download from developer.apple.com > Certificates).
#   2. Get an App Store Connect API key with Developer role from
#      appstoreconnect.apple.com/access/api. Save the .p8 somewhere stable
#      (e.g. ~/.config/katib/AuthKey_XXX.p8 — NOT in a Syncthing folder).
#   3. Export the three env vars (add to ~/.zshrc for persistence):
#        export NOTARY_KEY_FILE=~/.config/katib/AuthKey_XXXXXXXXXX.p8
#        export NOTARY_KEY_ID=XXXXXXXXXX
#        export NOTARY_ISSUER=<issuer-uuid>
#
# Legacy alternative — store creds in the login keychain instead of env:
#   xcrun notarytool store-credentials katib-notary \
#     --key /path/to/AuthKey_XXX.p8 --key-id XXX --issuer <uuid>
#   (This is brittle — the profile gets wiped occasionally by TCC resets or
#   Syncthing-synced keychains. Prefer the env-var setup above.)
#
# Env overrides:
#   SIGN_ID          Code signing identity (default: auto-detect)
#   KATIB_TEAM_ID    Apple team whose Developer ID signs (default: 776's)
#   KATIB_EDITION    Same as --edition=<dir>
#   NOTARY_KEY_FILE  Path to AuthKey_XXX.p8 — turns on key-file mode
#   NOTARY_KEY_ID    10-char App Store Connect key ID
#   NOTARY_ISSUER    Issuer UUID from App Store Connect
#   NOTARY_PROFILE   Keychain profile name fallback (default: katib-notary)

set -e

APP_NAME="Katib"
BUNDLE_ID="com.sevensevensix.katib"
TEAM_ID="${KATIB_TEAM_ID:-4HUZT3VWKU}"   # 776 Management, LLC.
VERSION="2.2.2"

RELEASE=0
LAUNCH=0
EDITION="${KATIB_EDITION:-}"
for arg in "$@"; do
    case "$arg" in
        --release) RELEASE=1 ;;
        --launch)  LAUNCH=1 ;;
        --edition=*) EDITION="${arg#--edition=}" ;;
        *)
            echo "Unknown flag: $arg"
            echo "Usage: $0 [--release] [--launch] [--edition=<dir>]"
            exit 1
            ;;
    esac
done

# --- Pick signing identity ---------------------------------------------------

if [ -n "$SIGN_ID" ]; then
    : # user override; use as-is
elif [ $RELEASE -eq 1 ]; then
    SIGN_ID=$(security find-identity -v -p codesigning \
        | grep "Developer ID Application: .*(${TEAM_ID})" \
        | head -1 \
        | sed -E 's/.*"(.*)"/\1/')
    if [ -z "$SIGN_ID" ]; then
        echo "ERROR: --release requires a 'Developer ID Application' certificate."
        echo "No such cert found in your Keychain."
        echo ""
        echo "Fix: have an Apple Developer team admin create a Developer ID"
        echo "Application cert at https://developer.apple.com/account/resources/certificates"
        echo "then download + install the .cer file in your Keychain."
        exit 1
    fi
else
    # Dev build: the team's Developer ID, same as release. TCC keys Katib's
    # grants (Accessibility, Screen Recording) on its designated requirement,
    # which names the team. The old "first Developer ID or Apple Development"
    # pick took the personal Apple Development cert whenever the Keychain
    # listed it first, so a dev rebuild looked like a different app and
    # dropped every grant.
    SIGN_ID=$(security find-identity -v -p codesigning \
        | grep "Developer ID Application: .*(${TEAM_ID})" \
        | head -1 \
        | sed -E 's/.*"(.*)"/\1/')
    if [ -z "$SIGN_ID" ]; then
        # No team cert (anyone building from source): ad-hoc. It runs, but
        # macOS sees each rebuild as a new app, so privacy grants
        # (Accessibility, Microphone) must be given again after a rebuild.
        echo "No 'Developer ID Application' cert for team ${TEAM_ID}: signing ad-hoc."
        echo "Each rebuild needs its privacy grants again. Set SIGN_ID or KATIB_TEAM_ID to use your own cert."
        SIGN_ID="-"
    fi
fi

echo "Signing identity: $SIGN_ID"
echo "Mode: $([ $RELEASE -eq 1 ] && echo release || echo dev)"
echo ""

# --- Build -------------------------------------------------------------------

echo "Building Katib..."
swift build -c release

echo "Creating app bundle..."
rm -rf "${APP_NAME}.app"
mkdir -p "${APP_NAME}.app/Contents/MacOS"
mkdir -p "${APP_NAME}.app/Contents/Resources"

cp ".build/release/${APP_NAME}" "${APP_NAME}.app/Contents/MacOS/"

if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "${APP_NAME}.app/Contents/Resources/"
fi

# Copy raw resource files into Contents/Resources so `Bundle.main` can
# find them with the standard `url(forResource:withExtension:)` lookup.
#
# Why not SwiftPM's `Bundle.module`? SPM generates a static accessor
# that looks for `Katib.app/<Pkg>_<Module>.bundle` (the .app ROOT, not
# Contents/Resources). Putting it at the root breaks codesign with
# "unsealed contents present in the bundle root" because that bundle
# has no Info.plist and isn't a recognized nested bundle. Falling back
# to the absolute build-path string only works on the machine that
# built it — every DMG before v2.1.3 SIGTRAP'd at app launch on other
# Macs because Bundle.module's static initializer fatalError'd.
#
# Resolution: ship raw resources in Contents/Resources (standard,
# codesign-clean) and rewrite the two callsites to prefer Bundle.main
# with a Bundle.module fallback for tests.
find Sources -path '*/Resources/*' -type f -exec cp {} "${APP_NAME}.app/Contents/Resources/" \;

if [ -n "$EDITION" ]; then
    if [ ! -d "$EDITION" ]; then
        echo "ERROR: edition $EDITION is not a folder."
        exit 1
    fi
    echo "Edition: $EDITION"
    # A broken edition.json must stop the build, not ship an app that
    # silently lacks the edition's crash reporting and update URL.
    if [ -f "$EDITION/edition.json" ] && ! plutil -convert xml1 -o /dev/null "$EDITION/edition.json" 2>/dev/null; then
        echo "ERROR: $EDITION/edition.json is not valid JSON."
        exit 1
    fi
    if [ -d "$EDITION/Plugins" ]; then
        cp -R "$EDITION/Plugins" "${APP_NAME}.app/Contents/Resources/Plugins"
        echo "  plugins: $(ls "$EDITION/Plugins" | tr '\n' ' ')"
    fi
fi

cat > "${APP_NAME}.app/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Katib needs microphone access to transcribe your speech in real-time.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Katib uses on-device speech recognition to transcribe your voice.</string>
</dict>
</plist>
EOF

# Edition settings (read by KatibCore's `Edition`).
if [ -n "$EDITION" ] && [ -f "$EDITION/edition.json" ]; then
    for pair in sentryDSN:KatibSentryDSN updateManifestURL:KatibUpdateManifestURL; do
        json_key="${pair%%:*}"; plist_key="${pair##*:}"
        value=$(plutil -extract "$json_key" raw -o - "$EDITION/edition.json" 2>/dev/null || true)
        if [ -n "$value" ]; then
            /usr/libexec/PlistBuddy -c "Add :${plist_key} string ${value}" "${APP_NAME}.app/Contents/Info.plist"
            echo "  ${plist_key} set"
        fi
    done
fi

echo -n "APPL????" > "${APP_NAME}.app/Contents/PkgInfo"

# --- Sign --------------------------------------------------------------------
# Apple deprecated `codesign --deep` (WWDC 2023) — sign each nested component
# first (inside-out), then the outer bundle.

echo "Signing app bundle..."

BASE_FLAGS=(--force --sign "$SIGN_ID")
if [ $RELEASE -eq 1 ]; then
    # Hardened runtime + secure timestamp are required for notarization.
    BASE_FLAGS+=(--options runtime --timestamp)
fi

FRAMEWORKS_DIR="${APP_NAME}.app/Contents/Frameworks"
if [ -d "$FRAMEWORKS_DIR" ]; then
    # Sign every embedded .framework bundle and every loose .dylib.
    find "$FRAMEWORKS_DIR" -maxdepth 1 -name "*.framework" -type d | while read -r fw; do
        echo "  signing $(basename "$fw")"
        codesign "${BASE_FLAGS[@]}" "$fw"
    done
    find "$FRAMEWORKS_DIR" -name "*.dylib" -type f | while read -r dylib; do
        echo "  signing $(basename "$dylib")"
        codesign "${BASE_FLAGS[@]}" "$dylib"
    done
fi

# Executables inside bundled plugins: notarization rejects unsigned Mach-O.
PLUGINS_DIR="${APP_NAME}.app/Contents/Resources/Plugins"
if [ -d "$PLUGINS_DIR" ]; then
    find "$PLUGINS_DIR" -type f -perm -u+x | while read -r exe; do
        if file "$exe" | grep -q "Mach-O"; then
            echo "  signing plugin $(basename "$exe")"
            codesign "${BASE_FLAGS[@]}" "$exe"
        fi
    done
fi

# Outer bundle (with entitlements — only the executable, not nested frameworks)
codesign "${BASE_FLAGS[@]}" --entitlements Katib.entitlements "${APP_NAME}.app"

xattr -dr com.apple.quarantine "${APP_NAME}.app" 2>/dev/null || true

# --- Dev build: stop here ----------------------------------------------------

if [ $RELEASE -eq 0 ]; then
    echo ""
    echo "Dev build complete: ${APP_NAME}.app"

    # Auto-relaunch is OPT-IN via --launch. Without the flag we build and
    # stop. Reason: every kill-and-relaunch tears down + reinstalls the
    # shared CGEventTap, which races with the kernel's tap dispatch path.
    # A rapid sequence of rebuilds (5x in 8 minutes — happened during the
    # v2.1.3 bundle-loader debug) has wedged the system-wide keyboard
    # hard enough to require a power-button reboot. The kill logic below
    # tries to drain cleanly (SIGTERM, wait, then SIGKILL) but is not
    # bulletproof on every macOS build. Default to safe: print the launch
    # command, let the developer run it when ready.
    if [ $LAUNCH -eq 0 ]; then
        echo ""
        echo "To run: open ${APP_NAME}.app"
        echo "       (or pass --launch to auto-kill + relaunch)"
        echo "Logs:   tail -f ~/Library/Logs/Katib/katib.log"
        exit 0
    fi

    # Kill any running Katib from a prior build, then launch the fresh bundle.
    # SIGTERM with a real timeout, SIGKILL the survivors, sleep an extra beat
    # to let the kernel reclaim the tap, refuse to launch if anything's still
    # alive after that.
    RUNNING_PATTERN="${APP_NAME}.app/Contents/MacOS/${APP_NAME}"

    # Never kill a dictation in progress: its text lives only in memory, so
    # a relaunch mid-sentence loses it for good (2026-10-19). A dictation is
    # open when the log's last hotkey-down is newer than its last
    # "stopRecording done". Wait up to 2 minutes for it to finish, then refuse.
    KATIB_LOG="$HOME/Library/Logs/Katib/katib.log"
    dictation_open() {
        [ -f "$KATIB_LOG" ] || return 1
        tail -n 2000 "$KATIB_LOG" | awk '
            /DICT\[[^]]*\]: hotkey-down/ { open = 1 }
            /stopRecording done|DICT pipeline:|BOOT\[/ { open = 0 }
            END { exit open ? 0 : 1 }'
    }
    if pgrep -f "$RUNNING_PATTERN" > /dev/null && dictation_open; then
        echo "A dictation is in progress; waiting for it to finish before relaunching..."
        for _ in $(seq 1 120); do
            dictation_open || break
            sleep 1
        done
        if dictation_open; then
            echo "Still dictating after 2 minutes. Not relaunching. Run: open ${APP_NAME}.app"
            exit 1
        fi
        sleep 2   # let the paste land before the kill
    fi

    if pgrep -f "$RUNNING_PATTERN" > /dev/null; then
        echo "Stopping running Katib..."
        pkill -TERM -f "$RUNNING_PATTERN" || true
        for _ in $(seq 1 20); do
            pgrep -f "$RUNNING_PATTERN" > /dev/null || break
            sleep 0.1
        done
        if pgrep -f "$RUNNING_PATTERN" > /dev/null; then
            echo "  graceful exit timed out — SIGKILL"
            pkill -KILL -f "$RUNNING_PATTERN" || true
            for _ in $(seq 1 20); do
                pgrep -f "$RUNNING_PATTERN" > /dev/null || break
                sleep 0.1
            done
        fi
        if pgrep -f "$RUNNING_PATTERN" > /dev/null; then
            echo "ERROR: prior Katib refused to die — aborting launch to avoid"
            echo "       running two instances and racing the keyboard tap."
            echo "       Try: pkill -9 -f Katib; then re-run this script."
            exit 1
        fi
        # Extra drain: even after the process exits, the kernel needs a
        # beat to fully reclaim the event tap. Without this, a fast
        # relaunch in the same second has wedged the keyboard.
        sleep 1
    fi

    echo "Launching ${APP_NAME}..."
    open "${APP_NAME}.app"
    echo "Logs: tail -f ~/Library/Logs/Katib/katib.log"
    exit 0
fi

# --- Notarize ----------------------------------------------------------------
# Two credential modes, checked in order:
#
# 1. Key-file mode — if NOTARY_KEY_FILE + NOTARY_KEY_ID + NOTARY_ISSUER are
#    set, notarytool uses them directly. No keychain involvement, so builds
#    survive keychain wipes (Syncthing, TCC resets, etc.). Recommended:
#    export these in ~/.zshrc once and forget.
#
# 2. Keychain profile mode — falls back to `xcrun notarytool --keychain-profile
#    <NOTARY_PROFILE>`. One-time setup: `xcrun notarytool store-credentials`.

NOTARY_PROFILE="${NOTARY_PROFILE:-katib-notary}"
NOTARY_AUTH_ARGS=()
if [ -n "$NOTARY_KEY_FILE" ] && [ -n "$NOTARY_KEY_ID" ] && [ -n "$NOTARY_ISSUER" ]; then
    if [ ! -f "$NOTARY_KEY_FILE" ]; then
        echo "ERROR: NOTARY_KEY_FILE=$NOTARY_KEY_FILE does not exist."
        exit 1
    fi
    NOTARY_AUTH_ARGS=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
    echo "Notary auth: key file ($NOTARY_KEY_ID)"
else
    NOTARY_AUTH_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    echo "Notary auth: keychain profile ($NOTARY_PROFILE)"
fi

ZIP_PATH="${APP_NAME}.zip"

echo ""
echo "Notarizing (this takes 1-5 min)..."
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "${APP_NAME}.app" "$ZIP_PATH"

if ! xcrun notarytool submit "$ZIP_PATH" \
        "${NOTARY_AUTH_ARGS[@]}" \
        --wait \
        > notarization.log 2>&1; then
    echo "ERROR: notarization failed. Last 40 lines of notarization.log:"
    tail -40 notarization.log
    echo ""
    echo "Credential setup (pick one):"
    echo "  Key-file mode (recommended — survives keychain wipes):"
    echo "    export NOTARY_KEY_FILE=/path/to/AuthKey_XXXXXXXXXX.p8"
    echo "    export NOTARY_KEY_ID=XXXXXXXXXX"
    echo "    export NOTARY_ISSUER=<issuer-uuid>"
    echo "  Keychain profile mode:"
    echo "    xcrun notarytool store-credentials $NOTARY_PROFILE --key ... --key-id ... --issuer ..."
    exit 1
fi

echo "Stapling notarization ticket..."
xcrun stapler staple "${APP_NAME}.app"
rm -f "$ZIP_PATH"

# --- DMG ---------------------------------------------------------------------

DMG_PATH="${APP_NAME}-${VERSION}.dmg"
echo "Creating ${DMG_PATH}..."
rm -f "$DMG_PATH"

STAGING=$(mktemp -d)
cp -R "${APP_NAME}.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" > /dev/null
rm -rf "$STAGING"

# Notarize the DMG itself so Gatekeeper is happy when the user mounts it.
echo "Notarizing DMG..."
if ! xcrun notarytool submit "$DMG_PATH" \
        "${NOTARY_AUTH_ARGS[@]}" \
        --wait \
        > notarization.log 2>&1; then
    echo "ERROR: DMG notarization failed. See notarization.log."
    tail -40 notarization.log
    exit 1
fi
xcrun stapler staple "$DMG_PATH"

echo ""
echo "Release build complete."
echo "  App: ${APP_NAME}.app"
echo "  DMG: ${DMG_PATH}"
echo ""
echo "Share the DMG. Coworkers: download, open, drag Katib to Applications."
echo "On first launch they grant Accessibility + Microphone once."
