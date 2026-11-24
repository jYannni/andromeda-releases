#!/bin/bash
# Builds and signs build/Andromeda.app with its embedded helper and automation worker.
# Signs only; never registers anything. Developer ID identity comes from the login keychain.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

APP_ID="io.github.jyannni.diskplain"
HELPER_ID="io.github.jyannni.diskplain.helper"
WORKER_ID="io.github.jyannni.diskplain.automation"
DEVID="Developer ID Application: Yanko Thomson (6K3XJ2VR2C)"
TEAM="6K3XJ2VR2C"
PLIST_NAME="$HELPER_ID.plist"
# --trace: dedicated debug build with the compile-time scan trace (ANDROMEDA_TRACE_FILE); output build/Andromeda-trace.app.
# --verify: dedicated build where ANDROMEDA_VERIFY_ENTRIES names catalog entries that count as verified
# (plan 3.1 test-machine runs); output build/Andromeda-verify.app. Mutually exclusive with --trace.
TRACE=0
VERIFY=0
SWIFT_EXTRA=()
APP="build/Andromeda.app"
for arg in "$@"; do
    case "$arg" in
        --trace) TRACE=1; SWIFT_EXTRA=(-Xswiftc -DANDROMEDA_TRACE); APP="build/Andromeda-trace.app" ;;
        --verify) VERIFY=1; SWIFT_EXTRA=(-Xswiftc -DANDROMEDA_VERIFY); APP="build/Andromeda-verify.app" ;;
        *) echo "usage: $0 [--trace | --verify]" >&2; exit 2 ;;
    esac
done
if [ "$TRACE" = 1 ] && [ "$VERIFY" = 1 ]; then echo "usage: $0 [--trace | --verify]" >&2; exit 2; fi
# shellcheck source=lib/signing-checks.sh
source "$ROOT/scripts/lib/signing-checks.sh"

VERSION="$(tr -d '[:space:]' < VERSION)"
[ -n "$VERSION" ] || die "VERSION is empty"
public_key="${ANDROMEDA_UPDATE_PUBLIC_KEY:-${DISKPLAIN_UPDATE_PUBLIC_KEY:-}}"
# shellcheck source=lib/release-channel.sh
source "$ROOT/scripts/lib/release-channel.sh"
if [ "$TRACE" = 1 ] || [ "$VERIFY" = 1 ]; then
    channel=development
else
    APP="$app_output"
fi
if [ -n "$feed" ] || [ -n "$public_key" ]; then
    [[ "$feed" =~ ^https://[^/?#@[:space:]]+/[^?#[:space:]]+$ ]] || die "Set ANDROMEDA_UPDATE_FEED_URL to an HTTPS appcast URL"
    [[ "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "Set ANDROMEDA_UPDATE_PUBLIC_KEY to the Sparkle EdDSA public key"
fi

step "swift build -c release${SWIFT_EXTRA[*]:+ ${SWIFT_EXTRA[*]}}"
swift build -c release ${SWIFT_EXTRA[@]+"${SWIFT_EXTRA[@]}"}
BIN="$(swift build -c release ${SWIFT_EXTRA[@]+"${SWIFT_EXTRA[@]}"} --show-bin-path)"
for b in Andromeda diskplain-helper andromeda-helperctl diskplain-automation-worker; do
    [ -x "$BIN/$b" ] || die "release binary $b missing in $BIN"
done

load_requirements "$BIN/andromeda-helperctl"
entitlement_positive_control "$BIN/andromeda-helperctl"

step "assemble $APP (version $VERSION)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchDaemons" "$APP/Contents/Library/LaunchAgents" "$APP/Contents/Resources"
cp "$BIN/Andromeda" "$BIN/diskplain-helper" "$BIN/diskplain-automation-worker" "$APP/Contents/MacOS/"
cp "$ROOT/Resources/LaunchDaemons/$PLIST_NAME" "$APP/Contents/Library/LaunchDaemons/"
worker_plist="$APP/Contents/Library/LaunchAgents/$WORKER_ID.plist"
cp "$ROOT/Resources/LaunchAgents/$WORKER_ID.plist" "$worker_plist"
plutil -lint "$worker_plist"
[ "$(plutil -extract Label raw "$worker_plist")" = "$WORKER_ID" ] || die "wrong automation service label"
[ "$(plutil -extract BundleProgram raw "$worker_plist")" = "Contents/MacOS/diskplain-automation-worker" ] \
    || die "wrong automation worker bundle path"
sed "s/__VERSION__/$VERSION/g" "$ROOT/Resources/App/Info.plist" > "$APP/Contents/Info.plist"
plutil -insert AndromedaReleaseChannel -string "$channel" "$APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "$display_name" "$APP/Contents/Info.plist"
if [ -n "$feed" ]; then
    plutil -insert SUFeedURL -string "$feed" "$APP/Contents/Info.plist"
    plutil -insert SUPublicEDKey -string "$public_key" "$APP/Contents/Info.plist"
fi
plutil -lint "$APP/Contents/Info.plist"
if [ "$VERIFY" = 1 ]; then
    # Distinct name so the verification build is never mistaken for the real app. Bundle ID stays: the helper is resolved through it.
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName 'Andromeda (verify)'" "$APP/Contents/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string 'Andromeda (verify)'" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName 'Andromeda (verify)'" "$APP/Contents/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleName string 'Andromeda (verify)'" "$APP/Contents/Info.plist"
    plutil -lint "$APP/Contents/Info.plist"
fi
# The app icon: Resources/App/AppIcon.icon is an Icon Composer document; actool turns it into the
# Liquid Glass Assets.car plus a flat AppIcon.icns for older surfaces.
step "app icon"
ICON_OUT="$(mktemp -d)"
icon_document="$ROOT/Resources/App/AppIcon.icon"
if [ "$channel" = public-beta ] || [ "$channel" = private-beta ]; then
    icon_document="$ICON_OUT/AppIcon.icon"
    python3 scripts/stage-beta-icon.py "$ROOT/Resources/App" "$icon_document" "$channel"
fi
xcrun actool "$icon_document" --compile "$ICON_OUT" --platform macosx \
    --minimum-deployment-target 26.0 --app-icon AppIcon --output-partial-info-plist "$ICON_OUT/partial.plist" >/dev/null \
    || die "actool could not compile Resources/App/AppIcon.icon"
[ -f "$ICON_OUT/Assets.car" ] && [ -f "$ICON_OUT/AppIcon.icns" ] || die "actool produced no icon"
cp "$ICON_OUT/Assets.car" "$ICON_OUT/AppIcon.icns" "$APP/Contents/Resources/"
rm -rf "$ICON_OUT"
# SwiftPM resource bundles; Bundle.module finds them in Bundle.main.resourceURL.
shopt -s nullglob
bundles=("$BIN"/*.bundle)
[ ${#bundles[@]} -gt 0 ] || die "no SwiftPM resource bundles in $BIN"
for b in "${bundles[@]}"; do
    case "$b" in *Tests.bundle) continue ;; esac   # test fixtures never ship
    cp -R "$b" "$APP/Contents/Resources/"
    # Xcode can produce owner-only bundles. Apps installed for all users need readable resources.
    chmod -R a+rX "$APP/Contents/Resources/${b##*/}"
done
[ -d "$APP/Contents/Resources/Andromeda_AndromedaCore.bundle" ] || die "Andromeda_AndromedaCore.bundle missing"
if [ "$channel" != development ]; then
    history="$APP/Contents/Resources/Andromeda_AndromedaAppModel.bundle/Contents/Resources/Releases.json"
    [ -f "$history" ] || die "Bundled release history is missing"
    python3 scripts/release-notes.py "$channel" "$VERSION" "$history" "build/Andromeda-${VERSION}${release_suffix}.md"
fi
ls "$APP/Contents/Resources"

step "embed Sparkle"
# SwiftPM's Xcode and native build systems place linked frameworks in different directories.
SPARKLE="$BIN/PackageFrameworks/Sparkle.framework"
[ -d "$SPARKLE" ] || SPARKLE="$BIN/Sparkle.framework"
[ -d "$SPARKLE" ] || die "Sparkle.framework missing from the SwiftPM build"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
runpaths="$(otool -l "$APP/Contents/MacOS/Andromeda")"
if ! grep -Fq 'path @executable_path/../Frameworks ' <<<"$runpaths"; then
    install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Andromeda"
fi

if [ "$TRACE" = 0 ] && [ "$VERIFY" = 0 ]; then
    step "leak guard: normal build contains no verification code"
    if strings "$APP/Contents/MacOS/Andromeda" | grep -qE "verification build|ANDROMEDA_VERIFY_ENTRIES"; then
        die "$APP/Contents/MacOS/Andromeda contains verification-build code (ANDROMEDA_VERIFY leaked into a normal build)"
    fi
fi

step "sign (Developer ID, hardened runtime, timestamp; nested code first)"
H="$APP/Contents/MacOS/diskplain-helper"
W="$APP/Contents/MacOS/diskplain-automation-worker"
for component in "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app" "$SPARKLE/Versions/Current/XPCServices/"*.xpc "$SPARKLE"; do
    codesign --force --options runtime --timestamp --preserve-metadata=identifier,entitlements -s "$DEVID" "$component"
done
codesign --force --options runtime --timestamp --identifier "$HELPER_ID" -s "$DEVID" "$H"
codesign --force --options runtime --timestamp --identifier "$WORKER_ID" -s "$DEVID" "$W"
plutil -lint "$ROOT/Resources/App/Entitlements.plist"
codesign --force --options runtime --timestamp --identifier "$APP_ID" \
    --entitlements "$ROOT/Resources/App/Entitlements.plist" -s "$DEVID" "$APP"

step "verify"
codesign --verify --deep --strict --verbose=2 "$APP"
check_designated_requirements "$APP" "$H"
check_requirement_satisfaction "$APP" "$H"
check_hardened_and_entitlements "$APP" "$H" "$W"
codesign -v -R "=anchor apple generic and identifier \"$WORKER_ID\" and certificate leaf[subject.OU] = \"$TEAM\"" "$W" \
    || die "automation worker does not satisfy its Developer ID requirement"
worker_version="$("$W" --version)"
[ "${worker_version%%+*}" = "$VERSION" ] || die "automation worker version doesn’t match app version"
unreadable="$(find "$APP" \( -type d ! -perm -055 \) -o \( -type f ! -perm -044 \))"
[ -z "$unreadable" ] || die "App bundle has resources unreadable by other users: $unreadable"

step "self-test: bundled catalog resolves inside the .app"
N="$("$APP/Contents/MacOS/Andromeda" --self-test-catalog)"
history_version="$("$APP/Contents/MacOS/Andromeda" --self-test-release-history)"
[ "$history_version" = "$VERSION" ] || die "bundled release history doesn't match the app version"
echo "catalog entries: $N"
[ "$N" = "42" ] || die "expected 42 catalog entries, got '$N'"

step "done: $APP"
