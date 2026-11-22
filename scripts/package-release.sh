#!/bin/bash
# Prepare a signed release DMG, then notarize it using an existing Keychain profile.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    printf 'Usage: %s <public-release|public-beta|private-beta> prepare | notarize <keychain-profile>\n' "$0" >&2
    exit 2
}

version="$(tr -d '[:space:]' < VERSION)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid release version" >&2; exit 1; }
case "${1:-}" in public-release|public-beta|private-beta) export ANDROMEDA_RELEASE_CHANNEL="$1" ;; *) usage ;; esac
shift
# shellcheck source=lib/release-channel.sh
source scripts/lib/release-channel.sh
release_base="Andromeda-${version}${release_suffix}"
candidate="${release_base}-candidate.dmg"
release="${release_base}.dmg"
case "${1:-}" in
    prepare) [ "$#" -eq 1 ] || usage ;;
    notarize) [ "$#" -eq 2 ] && [ -n "$2" ] || usage ;;
    *) usage ;;
esac

stage="$(mktemp -d "${TMPDIR:-/tmp}/andromeda-package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

if [ "$1" = prepare ]; then
    [ ! -e "build/$candidate" ] || { echo "build/$candidate already exists" >&2; exit 1; }
    scripts/build-app.sh
    app="$app_output"
    identity="$(codesign -dv --verbose=4 "$app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p')"
    [ -n "$identity" ] || { echo "The app has no Developer ID Application signature" >&2; exit 1; }

    mkdir "$stage/payload"
    ditto "$app" "$stage/payload/Andromeda.app"
    ln -s /Applications "$stage/payload/Applications"
    hdiutil create -srcfolder "$stage/payload" -volname Andromeda -fs HFS+ -format UDZO "$stage/$candidate"
    codesign --sign "$identity" --timestamp "$stage/$candidate"
    codesign --verify --strict "$stage/$candidate"
    mv -n "$stage/$candidate" "build/$candidate"
    echo "Signed candidate: build/$candidate"
else
    [ -f "build/$candidate" ] || { echo "Run prepare first" >&2; exit 1; }
    [ ! -e "build/$release" ] && [ ! -e "build/$release.sha256" ] || {
        echo "Release output already exists" >&2; exit 1;
    }
    cp "build/$candidate" "$stage/$release"
    codesign --verify --strict "$stage/$release"
    result="build/${release_base}-notary.json"
    if ! xcrun notarytool submit "$stage/$release" --keychain-profile "$2" --wait --output-format json > "$result"; then
        echo "Notarization failed. See $result" >&2
        exit 1
    fi
    [ "$(plutil -extract status raw "$result")" = Accepted ] || {
        echo "Notarization was not accepted. See $result" >&2; exit 1;
    }
    xcrun stapler staple "$stage/$release"
    xcrun stapler validate "$stage/$release"
    codesign --verify --strict "$stage/$release"
    (cd "$stage" && shasum -a 256 "$release" > "$release.sha256")
    mv -n "$stage/$release" "$stage/$release.sha256" build/
    echo "Notarized release: build/$release"
fi
