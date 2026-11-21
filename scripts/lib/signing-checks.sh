#!/bin/bash
# Shared signing checks, sourced by build-helper-harness.sh and build-app.sh.
# Read-only: inspects binaries with codesign; never registers anything.
# Callers define before use: APP_ID HELPER_ID TEAM (and a die() function).

BANNED='get-task-allow|com.apple.security.cs.disable-library-validation|com.apple.security.cs.allow-dyld-environment-variables|com.apple.security.cs.allow-unsigned-executable-memory'

step() { printf '\n== %s\n' "$*"; }
die() { echo "FAIL: $*" >&2; exit 1; }

# Reads CLIENT_REQ / HELPER_REQ from `andromeda-helperctl requirements` (prints two strings,
# touches no registration or connection). $1 = path to a built andromeda-helperctl.
load_requirements() {
    local REQS
    REQS="$("$1" requirements)"
    CLIENT_REQ="$(sed -n 1p <<<"$REQS")"; HELPER_REQ="$(sed -n 2p <<<"$REQS")"
    [ -n "$CLIENT_REQ" ] && [ -n "$HELPER_REQ" ] && [ "$(wc -l <<<"$REQS")" -eq 2 ] || die "bad requirements output"
    grep -q "identifier \"$APP_ID\"" <<<"$CLIENT_REQ" || die "clientRequirement lacks $APP_ID"
    grep -q "identifier \"$HELPER_ID\"" <<<"$HELPER_REQ" || die "helperRequirement lacks $HELPER_ID"
    echo "client: $CLIENT_REQ"; echo "helper: $HELPER_REQ"
}

# Entitlement scan. Fails (not vacuously passes) if codesign errors or prints something unexpected.
# Returns 0 = clean, 1 = banned entitlement present; dies on any other output.
check_entitlements() {
    local t="$1" ents
    ents="$(codesign -d --entitlements - --xml "$t" 2>/dev/null)" || die "codesign -d --entitlements failed for $t"
    if [ -n "$ents" ] && [[ "$ents" != "<?xml"* ]]; then die "unexpected entitlements output for $t"; fi
    if grep -Eq "$BANNED" <<<"$ents"; then return 1; fi
    return 0
}

# $1 = any Mach-O to copy for the control. Ad-hoc signs a copy with get-task-allow and
# requires check_entitlements to flag it.
entitlement_positive_control() {
    step "entitlement-check positive control"
    mkdir -p build/control
    cp "$1" build/control/ctl
    cat > build/control/ent.plist <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
ENT
    codesign --force -s - --entitlements build/control/ent.plist build/control/ctl
    if check_entitlements build/control/ctl; then die "entitlement check did not detect get-task-allow (control)"; fi
    echo "control: get-task-allow detected as expected"
    rm -rf build/control
}

# $1 = app bundle, $2 = helper binary
check_designated_requirements() {
    step "designated requirements"
    echo "-- bundle";  codesign -dr - "$1" 2>&1
    echo "-- helper";  codesign -dr - "$2" 2>&1
    # Capture first: `grep -q` closing the pipe early would SIGPIPE codesign under pipefail.
    local APP_DR H_DR
    APP_DR="$(codesign -dr - "$1" 2>&1)"; H_DR="$(codesign -dr - "$2" 2>&1)"
    grep -q "identifier \"$APP_ID\"" <<<"$APP_DR" || die "bundle DR lacks identifier $APP_ID"
    grep -q "$TEAM" <<<"$APP_DR" || die "bundle DR lacks team $TEAM"
    grep -q "identifier \"$HELPER_ID\"" <<<"$H_DR" || die "helper DR lacks identifier $HELPER_ID"
    grep -q "$TEAM" <<<"$H_DR" || die "helper DR lacks team $TEAM"
}

# $1 = app bundle, $2 = helper binary. Needs CLIENT_REQ / HELPER_REQ.
check_requirement_satisfaction() {
    step "HelperIdentity requirements (codesign -v -R)"
    codesign -v -R "=$CLIENT_REQ" "$1" || die "bundle does not satisfy clientRequirement"
    echo "bundle satisfies clientRequirement"
    codesign -v -R "=$HELPER_REQ" "$2" || die "helper does not satisfy helperRequirement"
    echo "helper satisfies helperRequirement"
}

# $@ = signed Mach-O / bundles
check_hardened_and_entitlements() {
    step "hardened runtime + entitlements"
    local t dv
    for t in "$@"; do
        dv="$(codesign -dv "$t" 2>&1)"
        grep -q 'flags=0x10000(runtime)' <<<"$dv" || die "$t lacks hardened runtime"
        check_entitlements "$t" || die "$t carries a banned entitlement"
        echo "ok: $t runtime, no banned entitlements"
    done
}
