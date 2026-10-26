#!/usr/bin/env bash
# ╔═════════════════════════════════════════════════════════════════════════════╗
# ║   mythix-neutron_builder  •  mythix-steam-bridge.sh                          ║
# ║   Shared Steam client bridge: GE's lsteamclient + steam.exe, built in-tree   ║
# ╚═════════════════════════════════════════════════════════════════════════════╝
#
# Sourced (never executed) by mythix-patch-pipeline.sh (patch pipeline) and
# phases/20-fetch-wine.sh (legacy pipeline). Provides two functions:
#
#   mythix_steam_bridge_src <GE_DIR> <SRC_ROOT>
#   mythix_add_steam_bridge <WINE_DIR> <BRIDGE_DIR> [skip_patch_dirs]
#
# The bridge comes from the profile's PIN_GE_COMMIT unless it sets
# PIN_STEAM_BRIDGE_COMMIT: GE's lsteamclient follows Valve's newest Wine, so
# a profile on an older Wine base pins the last GE whose lsteamclient was
# written for that Wine (mythix-10.17: GE-Proton10-34, because newer GE calls
# ntdll helpers that only exist from Wine 11.0 on). mythix_steam_bridge_src
# sets MYTHIX_BRIDGE_SRC to the checkout to build from.
# The bridge sources are patched by GE's own helper section (run verbatim from
# that checkout's patches/protonprep-valve-staging.sh), then added to the Wine
# tree as regular modules so Wine's build makes them for every arch:
#
#   dlls/lsteamclient       → lsteamclient.dll (+ lsteamclient.so unix side)
#   programs/steam_helper   → steam.exe
#
# Proton builds both against the exact Wine they ship with; a mismatched
# lsteamclient breaks Steam games (Valve's ntdll trampolines Steam's
# steamclient64.dll into lsteamclient), which is why this is built, never
# downloaded.
#
# Requires from the sourcing script: msg/msg2/ok/warn/err (from
# _output_common.sh) and $LOG_DIR for the helper-section log/fail list.
# Honors $ALLOW_PATCH_FAILURES (default false) and the optional third argument
# (STEAM_BRIDGE_SKIP_PATCH_DIRS) — a space-separated list of GE-relative patch
# dirs to leave out (GE's discordrpc helper patches register a service for a
# bridge we don't build, so profiles skip them).

# The patch pipeline defines _git with a fixed identity; the legacy pipeline
# uses plain git, so provide the same wrapper when it isn't there.
if ! declare -F _git >/dev/null 2>&1; then
    _git() {
        git -c advice.detachedHead=false \
            -c user.name="Mythix Builder" -c user.email="builder@mythix.invalid" \
            -c core.autocrlf=false "$@"
    }
fi

mythix_steam_bridge_src() {
    local GE_DIR="$1" SRC_ROOT="$2"
    local pin="${PIN_STEAM_BRIDGE_COMMIT:-}"
    MYTHIX_BRIDGE_SRC="$GE_DIR"
    if [ -z "$pin" ] || [ "$pin" = "$(_git -C "$GE_DIR" rev-parse HEAD 2>/dev/null)" ]; then
        return 0
    fi
    # its own checkout, so the GE patch layer's checkout stays at PIN_GE_COMMIT
    MYTHIX_BRIDGE_SRC="${SRC_ROOT}/proton-ge-custom-bridge"
    if [ ! -d "${MYTHIX_BRIDGE_SRC}/.git" ]; then
        mkdir -p "$MYTHIX_BRIDGE_SRC"
        _git -C "$MYTHIX_BRIDGE_SRC" init -q
        _git -C "$MYTHIX_BRIDGE_SRC" remote add origin \
            "${PIN_GE_REPO:-https://github.com/GloriousEggroll/proton-ge-custom.git}"
    fi
    if ! _git -C "$MYTHIX_BRIDGE_SRC" cat-file -e "${pin}^{commit}" 2>/dev/null; then
        [ "${OFFLINE:-false}" = "true" ] && \
            err "Steam bridge commit ${pin} is not present in ${MYTHIX_BRIDGE_SRC} (--offline)"
        msg2 "fetching Steam bridge sources (GE ${pin:0:12})"
        _git -C "$MYTHIX_BRIDGE_SRC" fetch -q --depth=1 origin "$pin" || \
            err "Could not fetch Steam bridge commit ${pin} (PIN_STEAM_BRIDGE_COMMIT)"
    fi
    _git -C "$MYTHIX_BRIDGE_SRC" checkout -q -f "$pin"
    _git -C "$MYTHIX_BRIDGE_SRC" clean -q -fdx
    ok "Steam bridge sources pinned to GE ${pin:0:12} (PIN_STEAM_BRIDGE_COMMIT)"
}

mythix_add_steam_bridge() {
    local WINE_DIR="$1" WORK_DIR="$2"
    local skip_dirs="${3:-${STEAM_BRIDGE_SKIP_PATCH_DIRS:-}}"
    local allow_fail="${ALLOW_PATCH_FAILURES:-false}"

    for _d in lsteamclient steam_helper; do
        [ -d "${WORK_DIR}/${_d}" ] || \
            err "GE checkout has no ${_d}/ — cannot build the Steam bridge"
    done
    local _bridge_dirs=( lsteamclient steam_helper )
    [ -d "${WORK_DIR}/umu_helper" ] && _bridge_dirs+=( umu_helper )
    _git -C "$WORK_DIR" checkout -q -- "${_bridge_dirs[@]}"
    _git -C "$WORK_DIR" clean -q -fdx -- "${_bridge_dirs[@]}"

    local GE_SCRIPT="${WORK_DIR}/patches/protonprep-valve-staging.sh"
    [ -f "$GE_SCRIPT" ] || err "GE patch script not found: ${GE_SCRIPT}"

    # GE's helper section: everything between END PREP and WINE PATCHING.
    local _hs_start _hs_end
    _hs_start="$(grep -n '^### END PREP SECTION ###' "$GE_SCRIPT" | head -1 | cut -d: -f1)"
    _hs_end="$(grep -n '^### (2) WINE PATCHING ###' "$GE_SCRIPT" | head -1 | cut -d: -f1)"
    if [ -z "$_hs_start" ] || [ -z "$_hs_end" ] || [ "$_hs_end" -le "$_hs_start" ]; then
        err "GE script layout changed: could not find GE's helper section (END PREP … WINE PATCHING)"
    fi
    local _hs_section="${LOG_DIR}/mythix-ge-helpers-section.sh"
    local _hs_log="${LOG_DIR}/mythix-ge-helpers-section.log"
    local _hs_fail_list="${LOG_DIR}/mythix-ge-helpers-failed.txt"
    : > "$_hs_fail_list"
    {
        printf '# Generated by mythix-steam-bridge.sh from %s, lines %s-%s\n' \
            "${GE_SCRIPT##*/}" "$((_hs_start + 1))" "$((_hs_end - 1))"
        cat <<'EOF'
apply_patch() {
    local patch_path="$1"
    if ! patch -Np1 --no-backup-if-mismatch < "$patch_path"; then
        printf 'MYTHIX: patch failed: %s\n' "$patch_path" >&2
        printf '%s\n' "$patch_path" >> "$MYTHIX_PATCH_FAIL_LIST"
    fi
}
apply_all_in_dir() {
    local dir="$1" patch skip
    for skip in ${MYTHIX_PATCH_SKIP_PATCH_DIRS:-}; do
        if [ "${dir%/}" = "${skip%/}" ]; then
            printf 'MYTHIX: skipping %s (STEAM_BRIDGE_SKIP_PATCH_DIRS)\n' "$dir"
            return 0
        fi
    done
    for patch in "$dir"/*.patch; do
        [ -e "$patch" ] || continue
        apply_patch "$patch"
    done
}
EOF
        sed -n "$((_hs_start + 1)),$((_hs_end - 1))p" "$GE_SCRIPT"
    } > "$_hs_section"

    msg "Running GE's helper section (log: ${_hs_log##*/})…"
    [ -n "$skip_dirs" ] && msg2 "Skipping: ${skip_dirs}"
    set +e
    ( cd "$WORK_DIR" && MYTHIX_PATCH_FAIL_LIST="$_hs_fail_list" \
        MYTHIX_PATCH_SKIP_PATCH_DIRS="$skip_dirs" bash "$_hs_section" ) \
        > "$_hs_log" 2>&1
    local _hs_rc=$?
    set -e
    if [ "$_hs_rc" -ne 0 ] || [ -s "$_hs_fail_list" ]; then
        warn "GE helper section: exit ${_hs_rc}, $(wc -l < "$_hs_fail_list") failed patch(es)"
        sed 's/^/       /' "$_hs_fail_list" >&2
        if [ "$allow_fail" = "true" ]; then
            warn "continuing anyway (--allow-patch-failures)"
        else
            printf "${C_RED}ERR!${C_R} GE helper patches did not apply cleanly — see %s\n" "$_hs_log" >&2
            exit 2
        fi
    fi

    # In-tree modules: dlls/lsteamclient and programs/steam_helper (steam.exe).
    # overlay_bridge/ is a separate CMake project of GE's; gen*.py regenerate
    # sources and are not needed to build.
    rm -rf "${WINE_DIR}/dlls/lsteamclient" "${WINE_DIR}/programs/steam_helper"
    mkdir -p "${WINE_DIR}/dlls/lsteamclient" "${WINE_DIR}/programs/steam_helper"
    ( cd "${WORK_DIR}/lsteamclient" && \
      tar cf - --exclude=./overlay_bridge --exclude=./gen.sh --exclude=./gen_wrapper.py \
               --exclude='*.orig' --exclude='*.rej' . ) | tar xf - -C "${WINE_DIR}/dlls/lsteamclient"
    # steam_helper: Makefile.in plus exactly the sources it lists (the dir also
    # carries prebuilt libsteam_api.so blobs and old C++ sources it doesn't use)
    cp "${WORK_DIR}/steam_helper/Makefile.in" "${WINE_DIR}/programs/steam_helper/"
    local _src
    while IFS= read -r _src; do
        cp "${WORK_DIR}/steam_helper/${_src}" "${WINE_DIR}/programs/steam_helper/" || \
            err "steam_helper source listed in Makefile.in is missing: ${_src}"
    done < <(awk '
        /^SOURCES[[:space:]]*=/ { f = 1; sub(/^SOURCES[[:space:]]*=/, "") }
        f {
            line = $0; cont = (line ~ /\\[[:space:]]*$/)
            gsub(/\\/, " ", line)
            n = split(line, a, /[[:space:]]+/)
            for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
            if (!cont) f = 0
        }' "${WORK_DIR}/steam_helper/Makefile.in")

    # Register both modules in configure.ac (sorted like Wine's own list)
    python3 - "${WINE_DIR}/configure.ac" <<'PYEOF'
import re, sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
lines = src.split("\n")
def register(module):
    entry = "WINE_CONFIG_MAKEFILE(%s)" % module
    if entry in lines:
        return
    top = module.split("/")[0] + "/"
    idx = [i for i, l in enumerate(lines)
           if (m := re.match(r"WINE_CONFIG_MAKEFILE\((" + re.escape(top) + r"[^),]*)", l))]
    if not idx:
        sys.exit("no WINE_CONFIG_MAKEFILE(%s…) entries found in configure.ac" % top)
    for i in idx:
        name = re.match(r"WINE_CONFIG_MAKEFILE\(([^),]*)", lines[i]).group(1)
        if name > module:
            lines.insert(i, entry)
            return
    lines.insert(idx[-1] + 1, entry)
register("dlls/lsteamclient")
register("programs/steam_helper")
open(path, "w", encoding="utf-8").write("\n".join(lines))
PYEOF

    _git -C "$WINE_DIR" add -A
    _git -C "$WINE_DIR" commit -q --no-verify \
        -m "mythix: Steam client bridge (lsteamclient + steam.exe from GE)"
    ok "lsteamclient + steam.exe added in-tree ($(find "${WINE_DIR}/dlls/lsteamclient" -type f | wc -l) files)"
}
