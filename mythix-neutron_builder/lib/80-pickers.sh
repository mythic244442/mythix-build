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

