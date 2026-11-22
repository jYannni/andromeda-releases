# Sourced by the signed app and DMG builders.
feed="${ANDROMEDA_UPDATE_FEED_URL:-${DISKPLAIN_UPDATE_FEED_URL:-}}"
public_feed="https://jyannni.github.io/andromeda-releases/updates/appcast.xml"
channel="${ANDROMEDA_RELEASE_CHANNEL:-}"
if [ -z "$channel" ]; then
    if [ "$feed" = "$public_feed" ]; then
        channel=public-release
    else
        channel=private-beta
    fi
fi

case "$channel" in
    public-release) release_suffix=; app_output=build/Andromeda.app; display_name=Andromeda ;;
    public-beta)
        release_suffix=-public-beta
        app_output=build/public-beta/Andromeda.app
        display_name="Andromeda Public Beta"
        ;;
    private-beta)
        release_suffix=-private-beta
        app_output=build/private-beta/Andromeda.app
        display_name="Andromeda Private Beta"
        ;;
    development) release_suffix=-development; app_output=build/Andromeda.app; display_name=Andromeda ;;
    *) printf 'Invalid ANDROMEDA_RELEASE_CHANNEL: %s\n' "$channel" >&2; exit 1 ;;
esac

if [[ "$channel" == public-* ]]; then
    if [ -n "$feed" ] && [ "$feed" != "$public_feed" ]; then
        printf 'Public builds must use the official public Sparkle feed.\n' >&2
        exit 1
    fi
    feed="$public_feed"
fi
if [ "$channel" = private-beta ] && [[ "$feed" == https://*.github.io/* ]]; then
    printf 'Private beta builds need a restricted feed or manual DMG updates.\n' >&2
    exit 1
fi
