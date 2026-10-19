# ══════════════════════════════════════════════════════════════════════════════
#  PACKAGE  — generate Steam Neutron layout
# ══════════════════════════════════════════════════════════════════════════════
section "Packaging Neutron"
export NEUTRON_PACKAGE_DIR WINE_INSTALL_PREFIX
export DXVK_SOURCE_KEY VKD3D_SOURCE_KEY
export BUILD_NAME SNIPER_MODE STEAM_RUNTIME
# Bash can't export associative arrays — hand the packager plain scalars
export STEAM_RUNTIME_APPID_VALUE="${STEAM_RUNTIME_APPID[${STEAM_RUNTIME:-none}]:-}"
export STEAM_RUNTIME_LABEL_VALUE="${STEAM_RUNTIME_LABEL[${STEAM_RUNTIME:-none}]:-}"
export NEUTRON_SOURCE_KEY="$WINE_SOURCE_KEY" NEUTRON_BUILD_MODE
export NEUTRON_PROFILE="${PROFILE_NAME:-}"
export NEUTRON_PROFILE_WAYLAND="${PROFILE_WAYLAND:-}"
export NEUTRON_STEAM_BRIDGE="${PROFILE_STEAM_BRIDGE:-}"
export NEUTRON_SOURCE_LOCK=""
if [ -n "$PROFILE_NAME" ]; then
    [ -f "${BUILD_RUN_DIR}/mythix-source.lock" ] && \
        NEUTRON_SOURCE_LOCK="${BUILD_RUN_DIR}/mythix-source.lock"
    # The profile's package name is the version tag the launcher reads
    # (prefix schema + build-profile selection), e.g. Mythix-Neutron-11.19-1.
    if [[ "$BUILD_NAME" =~ -[0-9]+\.[0-9]+(-[0-9]+)?$ ]]; then
        export NEUTRON_VERSION_STR="$BUILD_NAME"
    else
        export NEUTRON_VERSION_STR="${BUILD_NAME}-${PROFILE_VERSION_LABEL:-0.0}"
    fi
fi
"$PACKAGER"

# ══════════════════════════════════════════════════════════════════════════════
#  Version rename  — append actual wine version string to the package dir
#  Final name: <BUILD_NAME>-<version>  e.g. mythix-neutron-11.4.r0.gabcdef
#  Profile builds keep the profile's fixed package name.
# ══════════════════════════════════════════════════════════════════════════════
_wine_bin="${WINE_INSTALL_PREFIX}/bin/wine"
if [ -z "$PROFILE_NAME" ] && [ -x "$_wine_bin" ]; then
    _raw_ver="$("$_wine_bin" --version 2>/dev/null || true)"
    if [ -n "$_raw_ver" ]; then
        # Strip leading "wine-" prefix — user just wants the number
        _clean_ver="${_raw_ver#wine-}"
        _clean_ver="$(printf '%s' "$_clean_ver" \
            | tr ' ' '-' | tr -d '()[]:'  | sed 's/--*/-/g; s/-$//')"
        _new_pkg="${DEST_ROOT}/install/${BUILD_NAME}-${_clean_ver}"
        if [ "$NEUTRON_PACKAGE_DIR" != "$_new_pkg" ] && [ ! -e "$_new_pkg" ]; then
            mv "$NEUTRON_PACKAGE_DIR" "$_new_pkg"
            NEUTRON_PACKAGE_DIR="$_new_pkg"
            WINE_INSTALL_PREFIX="${_new_pkg}/files"
            ok "Package: ${_new_pkg}"
        fi
    fi
fi

# ── Summary + manifest ────────────────────────────────────────────────────────
_BUILD_END=$(date +%s)
_ELAPSED=$(( _BUILD_END - _BUILD_START ))
_ELAPSED_FMT="$(( _ELAPSED / 3600 ))h $(( (_ELAPSED % 3600) / 60 ))m $(( _ELAPSED % 60 ))s"
print_summary "$NEUTRON_PACKAGE_DIR" "$_ELAPSED_FMT"
_write_build_manifest "$NEUTRON_PACKAGE_DIR" "$_ELAPSED_FMT"

# Pause so the user can read the summary if the terminal would close on exit
if [ -t 0 ]; then
    printf "\n${C_DIM}Press Enter to exit...${C_R}"
    read -r
fi
