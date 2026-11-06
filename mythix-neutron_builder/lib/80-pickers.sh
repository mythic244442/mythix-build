# ══════════════════════════════════════════════════════════════════════════════
#  Build-target menu  — shown on a bare interactive run (no --profile/--source)
#
#  Lists the release profiles first (the recommended path — they carry the
#  patch groups, Steam bridge and Wayland config) and then the raw Wine
#  sources, in one picker.  Sets PROFILE_NAME or WINE_SOURCE_KEY; the caller
#  loads the profile / validates the source afterwards, as with the CLI flags.
# ══════════════════════════════════════════════════════════════════════════════
pick_build_target() {
    section "Build target"

    # Gather "key<TAB>label" rows: profiles (profile:<name>) then sources.
    local -a rows=()
    local conf name desc
    for conf in "${PROFILES_DIR}"/*/profile.conf; do
        [ -f "$conf" ] || continue
        name="$(basename "$(dirname "$conf")")"
        desc="$(
            unset "${_PROFILE_VARS[@]}"
            # shellcheck source=/dev/null
            . "$conf"
            printf '%s' "${PROFILE_DESC:-Mythix Wine profile}"
        )"
        local tag="profile"
        [ "$name" = "$DEFAULT_PROFILE" ] && tag="profile*"
        rows+=( "profile:${name}"$'\t'"[${tag}] ${name} — ${desc}" )
    done
    local k
    for k in "${WINE_SOURCE_KEYS[@]}"; do
        rows+=( "source:${k}"$'\t'"[source]  ${k} — ${WINE_SOURCE_DESC[$k]}" )
    done

    local picked key
    if command -v fzf >/dev/null 2>&1; then
        picked=$(
            printf '%s\n' "${rows[@]}" \
            | fzf \
                --prompt="Build target > " \
                --header="Select a release profile (recommended) or a raw Wine source  —  * = default" \
                --with-nth=2 \
                --delimiter=$'\t' \
                --height=40% \
                --border \
            || true
        )
        [ -n "$picked" ] || err "No build target selected."
        key="${picked%%$'\t'*}"
    else
        printf "\n  ${C_B}Select a build target${C_R} ${C_DIM}(profiles recommended; * = default)${C_R}\n\n"
        PS3="  Target: "
        local -a labels=() keys=()
        for k in "${rows[@]}"; do
            keys+=( "${k%%$'\t'*}" )
            labels+=( "${k#*$'\t'}" )
        done
        local choice i
        select choice in "${labels[@]}"; do
            [ -z "$choice" ] && continue
            for i in "${!labels[@]}"; do
                [ "${labels[$i]}" = "$choice" ] && key="${keys[$i]}" && break
            done
            [ -n "$key" ] && break
        done
        PS3=""
    fi

    case "$key" in
        profile:*) PROFILE_NAME="${key#profile:}";     ok "Selected profile: ${PROFILE_NAME}" ;;
        source:*)  WINE_SOURCE_KEY="${key#source:}";    ok "Selected source: ${WINE_SOURCE_KEY}" ;;
        *)         err "No build target selected." ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
#  Source menu  — interactive selector when --source is not given
# ══════════════════════════════════════════════════════════════════════════════
pick_source() {
    section "Source selection"

    if command -v fzf >/dev/null 2>&1; then
        local picked
        picked=$(
            for k in "${WINE_SOURCE_KEYS[@]}"; do
                printf '%s\t%s\n' "$k" "${WINE_SOURCE_DESC[$k]}"
            done \
            | fzf \
                --prompt="Wine source > " \
                --header="Select a Wine source for Neutron" \
                --with-nth=2 \
                --delimiter=$'\t' \
                --height=20% \
                --border \
            || true
        )
        [ -n "$picked" ] || err "No source selected."
        WINE_SOURCE_KEY="$(printf '%s' "$picked" | cut -d$'\t' -f1)"
    else
        printf "\n  ${C_B}Select a Wine source:${C_R}\n\n"
        PS3="  Source: "
        local -a menu_keys=()
        local -a menu_desc=()
        for k in "${WINE_SOURCE_KEYS[@]}"; do
            menu_keys+=("$k")
            menu_desc+=("${WINE_SOURCE_DESC[$k]}")
        done
        local choice
        select choice in "${menu_desc[@]}"; do
            [ -z "$choice" ] && continue
            local i
            for i in "${!menu_desc[@]}"; do
                [ "${menu_desc[$i]}" = "$choice" ] && \
                    WINE_SOURCE_KEY="${menu_keys[$i]}" && break
            done
            [ -n "$WINE_SOURCE_KEY" ] && break
        done
        PS3=""
    fi
    ok "Selected source: ${WINE_SOURCE_KEY}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  pick_build_name  — interactive prompt for the tool name
#
#  Asks for a base name (e.g. "mythix-neutron" or "my-gaming-neutron").
#  The actual Wine version number is appended automatically after the build,
#  so the final directory name will be e.g. "mythix-neutron-11.4.r0.gabcdef".
#  Skipped when --name was given on the command line or in non-interactive mode.
# ══════════════════════════════════════════════════════════════════════════════
pick_build_name() {
    # Only prompt interactively when stdin is a terminal and --name wasn't given
    [ -t 0 ] || return 0
    [ -z "$BUILD_NAME" ] || return 0

    section "Tool name"
    printf "  Enter a base name for this Neutron build.\n"
    printf "  The Wine version number will be appended automatically.\n"
    printf "  ${C_DIM}Example: mythix-neutron  →  mythix-neutron-11.4.r0.gabcdef${C_R}\n\n"
    printf "  ${C_B}Base name${C_R} [default: mythix-neutron]: "

    local _input
    read -r _input
    if [ -n "$_input" ]; then
        # Sanitize: spaces to hyphens, strip characters invalid in dir names
        BUILD_NAME="$(printf '%s' "$_input" \
            | tr ' ' '-' \
            | tr -cd 'a-zA-Z0-9._-' \
            | sed 's/--*/-/g; s/^-//; s/-$//')"
        ok "Build name: ${BUILD_NAME}"
    else
        BUILD_NAME="mythix-neutron"
        ok "Build name: ${BUILD_NAME}  (default)"
    fi
}
print_banner

