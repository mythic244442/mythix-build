# ══════════════════════════════════════════════════════════════════════════════
#  Build profiles
#
#  A profile is a pinned recipe for one Mythix Wine flavour:
#    profiles/<name>/profile.conf   — pins + build settings (sourced here)
#    profiles/<name>/patches/*.patch — curated layers (ge pipeline only)
#  See profiles/README.md.
# ══════════════════════════════════════════════════════════════════════════════
_PROFILE_VARS=( PROFILE_DESC PROFILE_PIPELINE PROFILE_BUILD_MODE PROFILE_PACKAGE_NAME
                PROFILE_VERSION_LABEL PROFILE_WAYLAND PROFILE_PATCH_GROUPS PROFILE_FFMPEG
                PROFILE_STEAM_BRIDGE STEAM_BRIDGE_SKIP_PATCH_DIRS
                LEGACY_WINE_BASE PIN_WINE_REPO PIN_WINE_COMMIT PIN_TKG_COMMIT
                PIN_STAGING_REPO PIN_STAGING_COMMIT PIN_STAGING_REF PIN_GE_REPO
                PIN_GE_COMMIT PIN_FFMPEG_REPO PIN_FFMPEG_COMMIT TKG_SOURCE )

_resolve_profile_dir() {
    local p="$1"
    if [ -f "${PROFILES_DIR}/${p}/profile.conf" ]; then
        printf '%s' "${PROFILES_DIR}/${p}"
    elif [ -f "${p}/profile.conf" ]; then
        (cd "$p" && pwd)
    else
        return 1
    fi
}

_list_profiles() {
    section "Build profiles  (${PROFILES_DIR})"
    local conf found=false
    for conf in "${PROFILES_DIR}"/*/profile.conf; do
        [ -f "$conf" ] || continue
        found=true
        (
            unset "${_PROFILE_VARS[@]}"
            # shellcheck source=/dev/null
            . "$conf"
            printf "\n  ${C_CYN}${C_B}%-16s${C_R} %s\n" "$(basename "$(dirname "$conf")")" "${PROFILE_DESC:-}"
            printf "  ${C_DIM}%-16s pipeline=%s  mode=%s  package=%s  wayland=%s  patches=%s${C_R}\n" "" \
                "${PROFILE_PIPELINE:-?}" "${PROFILE_BUILD_MODE:-?}" "${PROFILE_PACKAGE_NAME:-?}" \
                "${PROFILE_WAYLAND:-0}" "${PROFILE_PATCH_GROUPS:-none}"
        )
    done
    [ "$found" = "true" ] || msg2 "No profiles found."
    printf "\n  Build one with:  %s --profile <name> [--container]\n\n" "$(basename "$0")"
}

_load_profile() {
    PROFILE_DIR="$(_resolve_profile_dir "$1")" || \
        err "Unknown profile: '$1'
     Expected ${PROFILES_DIR}/$1/profile.conf (or a directory containing profile.conf).
     See: $(basename "$0") --list-profiles"

    unset "${_PROFILE_VARS[@]}"
    # shellcheck source=/dev/null
    . "${PROFILE_DIR}/profile.conf"
    PROFILE_NAME="$(basename "$PROFILE_DIR")"

    case "${PROFILE_PIPELINE:-}" in
        patch|legacy) ;;
        *) err "Profile ${PROFILE_NAME}: PROFILE_PIPELINE must be 'patch' or 'legacy' (got '${PROFILE_PIPELINE:-}')" ;;
    esac
    case "${PROFILE_BUILD_MODE:-classic}" in
        classic|wow64) ;;
        *) err "Profile ${PROFILE_NAME}: PROFILE_BUILD_MODE must be 'classic' or 'wow64'" ;;
    esac
    [ -n "${PROFILE_PACKAGE_NAME:-}" ] || err "Profile ${PROFILE_NAME}: PROFILE_PACKAGE_NAME is not set"

    # A profile always builds Mythix Wine, from its own pins.
    if [ -n "$WINE_SOURCE_KEY" ] && [ "$WINE_SOURCE_KEY" != "mythix-wine" ]; then
        err "--profile builds Mythix Wine — it can't be combined with --source ${WINE_SOURCE_KEY}"
    fi
    [ -z "$WINE_SOURCE_BRANCH_ARG" ] || \
        err "--branch can't be combined with --profile (the profile pins every source)"
    WINE_SOURCE_KEY="mythix-wine"

    if [ "$PROFILE_PIPELINE" = "legacy" ]; then
        [ -n "${LEGACY_WINE_BASE:-}" ] || err "Profile ${PROFILE_NAME}: LEGACY_WINE_BASE is not set"
        if [ "${_WINE_BASE_SET:-false}" = "true" ] && [ "$MYTHIX_WINE_BASE" != "$LEGACY_WINE_BASE" ]; then
            warn "--wine-base ${MYTHIX_WINE_BASE} ignored — profile ${PROFILE_NAME} pins ${LEGACY_WINE_BASE}"
        fi
        MYTHIX_WINE_BASE="$LEGACY_WINE_BASE"
    else
        [ -n "${PIN_GE_COMMIT:-}" ] || err "Profile ${PROFILE_NAME}: PIN_GE_COMMIT is not set"
        [ -f "$PATCH_PIPELINE" ] || err "Patch pipeline script not found: $PATCH_PIPELINE"
    fi

    # Profile defaults — explicit flags win.
    [ -n "$BUILD_NAME" ]         || BUILD_NAME="$PROFILE_PACKAGE_NAME"
    [ -n "$PATCH_GROUPS" ]       || PATCH_GROUPS="${PROFILE_PATCH_GROUPS:-none}"
    [ -n "$NEUTRON_BUILD_MODE" ] || NEUTRON_BUILD_MODE="${PROFILE_BUILD_MODE:-classic}"

    section "Profile: ${PROFILE_NAME}"
    msg  "${PROFILE_DESC:-}"
    msg2 "Pipeline    : ${PROFILE_PIPELINE}"
    msg2 "Build mode  : ${NEUTRON_BUILD_MODE}"
    msg2 "Package     : ${BUILD_NAME}"
    msg2 "Wayland     : $([ "${PROFILE_WAYLAND:-0}" = "1" ] && echo "on (launcher default)" || echo off)"
    msg2 "Patch groups: ${PATCH_GROUPS}"
    [ "${PROFILE_FFMPEG:-none}" != "none" ] && msg2 "FFmpeg      : ${PROFILE_FFMPEG} (winedmo media backend)"
    [ "${PROFILE_STEAM_BRIDGE:-none}" != "none" ] && msg2 "Steam bridge: lsteamclient + steam.exe from ${PROFILE_STEAM_BRIDGE} source"
    ok "Profile loaded: ${PROFILE_DIR}"
}

if [ "${_LIST_PROFILES:-false}" = "true" ]; then
    _list_profiles
    exit 0
fi

