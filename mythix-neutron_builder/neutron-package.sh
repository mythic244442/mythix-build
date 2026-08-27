#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║         mythix-neutron_builder  •  Neutron packager                         ║
# ║   Assembles a Steam-loadable compatibilitytool from compiled components   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Called by neutron-builder.sh after all components are compiled.
# Can also be invoked standalone if the required environment vars are set.
#
# Required env vars:
#   NEUTRON_PACKAGE_DIR  — root of the Neutron package being assembled
#   WINE_INSTALL_PREFIX  — where Wine was installed (= NEUTRON_PACKAGE_DIR/files)
#   BUILD_NAME           — human-readable name for this Neutron build
#
# Optional env vars (neutron-builder.sh sets all of these):
#   DXVK_SOURCE_KEY      — dxvk | dxvk-async | none   (used for display only)
#   VKD3D_SOURCE_KEY     — vkd3d-proton | none          (used for display only)
#
set -euo pipefail

# ── Output helpers ────────────────────────────────────────────────────────────
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
    _R="\033[0m" _B="\033[1m" _GRN="\033[1;32m" _BLU="\033[1;34m"
    _YLW="\033[1;33m" _RED="\033[1;31m" _DIM="\033[2m"
else
    _R="" _B="" _GRN="" _BLU="" _YLW="" _RED="" _DIM=""
fi
msg()  { printf "${_GRN}==> ${_R}${_B}%s${_R}\n" "$*"; }
msg2() { printf "${_BLU} -> ${_R}%s\n" "$*"; }
ok()   { printf "${_GRN} ✓  ${_R}%s\n" "$*"; }
warn() { printf "${_YLW}warn${_R} %s\n" "$*" >&2; }
err()  { printf "${_RED}ERR!${_R} %s\n" "$*" >&2; exit 1; }
sep()  { printf "\n${_BLU}${_B}── %s ──${_R}\n" "$*"; }

# ── Validate required env ─────────────────────────────────────────────────────
: "${NEUTRON_PACKAGE_DIR:?NEUTRON_PACKAGE_DIR must be set}"
: "${WINE_INSTALL_PREFIX:?WINE_INSTALL_PREFIX must be set}"
: "${BUILD_NAME:?BUILD_NAME must be set}"
: "${DXVK_SOURCE_KEY:=none}"
: "${VKD3D_SOURCE_KEY:=none}"

# ── Sanity: Wine must actually be installed ───────────────────────────────────
[ -d "$WINE_INSTALL_PREFIX" ] || \
    err "Wine install prefix not found: $WINE_INSTALL_PREFIX
     Run neutron-build-core.sh (or neutron-builder.sh) first."
[ -f "${WINE_INSTALL_PREFIX}/bin/wine" ] || \
    err "Wine binary not found at: ${WINE_INSTALL_PREFIX}/bin/wine
     The Wine build may not have installed correctly."

sep "Neutron Packager"
msg2 "Package dir  : ${NEUTRON_PACKAGE_DIR}"
msg2 "Wine prefix  : ${WINE_INSTALL_PREFIX}"
msg2 "Build name   : ${BUILD_NAME}"

# ══════════════════════════════════════════════════════════════════════════════
#  Get the wine version string for display and VDF fields
# ══════════════════════════════════════════════════════════════════════════════
_wine_ver="$("${WINE_INSTALL_PREFIX}/bin/wine" --version 2>/dev/null || printf 'unknown')"
_display_name="${BUILD_NAME}"
msg2 "Wine version : ${_wine_ver}"

# ══════════════════════════════════════════════════════════════════════════════
#  Write compatibilitytool.vdf
#
#  Steam reads this file to discover and display the custom Neutron in the
#  game's compatibility settings dropdown.
# ══════════════════════════════════════════════════════════════════════════════
sep "Writing compatibilitytool.vdf"
cat > "${NEUTRON_PACKAGE_DIR}/compatibilitytool.vdf" << EOF
"compatibilitytools"
{
  "compat_tools"
  {
    "${BUILD_NAME}"
    {
      "install_path" "."
      "display_name" "${_display_name}"
      "from_oslist"  "windows"
      "to_oslist"    "linux"
    }
  }
}
EOF
ok "compatibilitytool.vdf written"

# ══════════════════════════════════════════════════════════════════════════════
#  Write toolmanifest.vdf
#
#  Tells Steam how to invoke this Neutron build.
#  The %verb% token is replaced by Steam at runtime with the action to perform
#  (run, waitforexitandrun, runinprefix, etc.).
#
#  When SNIPER_MODE=true, we add "require_tool_appid" "1391110" which tells
#  Steam to run this tool inside the Steam Linux Runtime Sniper container
#  (SteamOS 3.x isolation). Without it, the tool runs directly on the host.
# ══════════════════════════════════════════════════════════════════════════════
sep "Writing toolmanifest.vdf"
if [ "${SNIPER_MODE:-false}" = "true" ]; then
    cat > "${NEUTRON_PACKAGE_DIR}/toolmanifest.vdf" << 'EOF'
"manifest"
{
  "version" "2"
  "commandline" "/neutron %verb%"
  "use_sessions" "1"
  "require_tool_appid" "1391110"
  "compatmanager_layer_name" "neutron"
}
EOF
    ok "toolmanifest.vdf written (Sniper mode — Steam Runtime 3.0 container)"
else
    cat > "${NEUTRON_PACKAGE_DIR}/toolmanifest.vdf" << 'EOF'
"manifest"
{
  "version" "2"
  "commandline" "/neutron %verb%"
  "use_sessions" "1"
  "compatmanager_layer_name" "neutron"
}
EOF
    ok "toolmanifest.vdf written (standard host mode)"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  lsteamclient bootstrap
#
#  kron4ek-tkg Wine builds do not ship lsteamclient.dll — it is a proprietary
#  Steam API bridge that Valve only distributes with their Proton builds.
#  Without it, any game that calls SteamAPI_Init() hangs at startup (black
#  screen) because Wine falls back to a stub that cannot talk to the real
#  Steam client.
#
#  We look for it in Proton Experimental (the most reliably up-to-date source)
#  and a handful of other common Proton install locations.  If found, we copy
#  all four files:
#    lib/wine/x86_64-windows/lsteamclient.dll  (PE, 64-bit)
#    lib/wine/x86_64-unix/lsteamclient.so      (Unix bridge, 64-bit)
#    lib/wine/i386-windows/lsteamclient.dll    (PE, 32-bit)
#    lib/wine/i386-unix/lsteamclient.so        (Unix bridge, 32-bit)
# ══════════════════════════════════════════════════════════════════════════════
sep "Checking for lsteamclient"
_wine_lib_dir="${WINE_INSTALL_PREFIX}/lib/wine"
_lsc_target="${_wine_lib_dir}/x86_64-windows/lsteamclient.dll"

if [ -f "${_lsc_target}" ]; then
    ok "lsteamclient.dll already present — skipping bootstrap"
else
    warn "lsteamclient.dll not found in Wine build; searching for Proton source..."

    # ── Discover Steam library roots ──────────────────────────────────
    # Parse libraryfolders.vdf for all Steam library paths, then add
    # well-known fallback roots in case the vdf is missing.
    # When running as root (sudo), also check the real user's home.
    _real_home="${HOME}"
    if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ]; then
        _real_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || echo "$HOME")"
    fi
    _steam_roots=()
    _vdf_candidates=()
    for _h in "$HOME" "$_real_home"; do
        _vdf_candidates+=(
            "${_h}/.steam/steam/steamapps/libraryfolders.vdf"
            "${_h}/.steam/debian-installation/steamapps/libraryfolders.vdf"
            "${_h}/.local/share/Steam/steamapps/libraryfolders.vdf"
        )
    done
    # Also check common system-wide paths
    for _u in /home/*/; do
        [ -d "$_u" ] || continue
        _vdf_candidates+=("${_u}.steam/debian-installation/steamapps/libraryfolders.vdf")
        _vdf_candidates+=("${_u}.steam/steam/steamapps/libraryfolders.vdf")
    done
    for _vdf in "${_vdf_candidates[@]}"; do
        if [ -f "$_vdf" ]; then
            while IFS= read -r _lpath; do
                [ -n "$_lpath" ] && _steam_roots+=("$_lpath")
            done < <(grep '"path"' "$_vdf" 2>/dev/null \
                     | sed 's/.*"path"[[:space:]]*"\([^"]*\)".*/\1/')
            break   # first valid vdf wins — they're usually symlinked
        fi
    done
    # Fallback roots if vdf parsing found nothing
    if [ ${#_steam_roots[@]} -eq 0 ]; then
        _steam_roots=()
        for _h in "$HOME" "$_real_home"; do
            _steam_roots+=(
                "${_h}/.steam/steam"
                "${_h}/.steam/debian-installation"
                "${_h}/.local/share/Steam"
            )
        done
    fi
    # Extra roots from the environment
    if [ -n "${STEAM_LIBRARY_PATHS:-}" ]; then
        while IFS= read -r _slib; do
            [ -n "$_slib" ] && _steam_roots+=("$_slib")
        done <<< "${STEAM_LIBRARY_PATHS}"
    fi

    # ── Search for any installed Proton that has lsteamclient ──────
    # Check multiple Proton variants, not just Experimental.
    _proton_names=(
        "Proton - Experimental"
        "Proton Hotfix"
        "Proton 9.0"
        "Proton 8.0"
    )
    # Also glob for any "Proton*" directories we haven't listed
    _proton_candidates=()
    for _root in "${_steam_roots[@]}"; do
        _common="${_root}/steamapps/common"
        [ -d "$_common" ] || continue
        # Named variants first (preferred order)
        for _pname in "${_proton_names[@]}"; do
            [ -d "${_common}/${_pname}/files" ] && \
                _proton_candidates+=("${_common}/${_pname}/files")
        done
        # Then any other Proton directories we haven't caught
        for _pdir in "${_common}"/Proton*/files; do
            [ -d "$_pdir" ] || continue
            # Skip if already in the list
            _dup=false
            for _existing in "${_proton_candidates[@]}"; do
                [ "$_existing" = "$_pdir" ] && { _dup=true; break; }
            done
            [ "$_dup" = "true" ] || _proton_candidates+=("$_pdir")
        done
    done

    _proton_src=""
    for _candidate in "${_proton_candidates[@]}"; do
        if [ -f "${_candidate}/lib/wine/x86_64-windows/lsteamclient.dll" ]; then
            _proton_src="${_candidate}"
            break
        fi
    done

    if [ -z "${_proton_src}" ]; then
        warn "No local Proton install found — downloading Steam components from GitHub..."
        msg2 "Searched ${#_proton_candidates[@]} candidate(s) across ${#_steam_roots[@]} Steam root(s)"

        # Download Proton from Kron4ek's proton-archive (reliable, all versions)
        _dl_tmp="$(mktemp -d)"
        _dl_ok=false
        if command -v curl >/dev/null 2>&1; then
            # Preferred: proton-10.0-4 (matches our Wine 11.x base)
            # Fallback through recent versions
            for _ptag in "10.0/proton-10.0-4" "10.0/proton-10.0-3" "9.0/proton-9.0-4" "8.0/proton-8.0-5"; do
                _dl_url="https://github.com/Kron4ek/proton-archive/releases/download/${_ptag}.tar.xz"
                msg2 "Downloading: ${_ptag##*/}.tar.xz ..."
                if curl -#fL "${_dl_url}" | xz -d | tar x -C "${_dl_tmp}" --strip-components=1 2>/dev/null; then
                    if [ -d "${_dl_tmp}/files" ]; then
                        _proton_src="${_dl_tmp}/files"
                        _dl_ok=true
                        ok "Downloaded ${_ptag##*/} from Kron4ek/proton-archive"
                        break
                    fi
                else
                    msg2 "${_ptag##*/} not available, trying next..."
                fi
            done
        fi

        if [ "$_dl_ok" = "false" ]; then
            warn "Download failed — Steam components NOT bootstrapped."
            warn "Steam API games may hang at startup."
            warn "Install 'Proton Hotfix' or 'Proton - Experimental' via Steam,"
            warn "or check your internet connection and re-run --reinstall-components."
            rm -rf "${_dl_tmp}"
        else
            ok "Downloaded Proton components from GitHub"
        fi
    fi

    if [ -n "${_proton_src:-}" ]; then
        msg2 "Found Proton source: ${_proton_src}"
        _lsc_files=(
            "lib/wine/x86_64-windows/lsteamclient.dll"
            "lib/wine/x86_64-unix/lsteamclient.so"
            "lib/wine/i386-windows/lsteamclient.dll"
            "lib/wine/i386-unix/lsteamclient.so"
        )
        _copied=0
        for _f in "${_lsc_files[@]}"; do
            _src="${_proton_src}/${_f}"
            _dst="${_wine_lib_dir}/${_f#lib/wine/}"
            if [ -f "${_src}" ]; then
                mkdir -p "$(dirname "${_dst}")"
                cp -f "${_src}" "${_dst}"
                msg2 "Copied: ${_f}"
                (( _copied++ )) || true
            else
                warn "Missing in Proton source: ${_f}"
            fi
        done
        ok "lsteamclient bootstrap complete (${_copied} file(s) copied)"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Additional Steam component bootstrap
#
#  These components are also sourced from Proton and are needed for full
#  Steam integration:
#    steam_helper.exe   — Steam overlay helper / steamwebhelper bridge
#    steam.exe          — Steam client stub expected by some games
#    gameoverlayrenderer.so — in-game overlay (shift+tab)
#
#  We reuse _proton_src from the lsteamclient search above. If lsteamclient
#  was already present (skipped search), we search now.
# ══════════════════════════════════════════════════════════════════════════════
sep "Checking for additional Steam components"

# If we skipped the Proton search above (lsteamclient already present), find
# a Proton source now for the other components.
if [ -z "${_proton_src:-}" ]; then
    # Re-run the same discovery logic — the variables may not exist if
    # lsteamclient was already present and the search block was skipped.
    if [ -z "${_proton_candidates+x}" ] || [ ${#_proton_candidates[@]} -eq 0 ]; then
        _proton_candidates=()
        _proton_names=("Proton - Experimental" "Proton Hotfix" "Proton 9.0" "Proton 8.0")
        # Rebuild _steam_roots if needed
        if [ -z "${_steam_roots+x}" ] || [ ${#_steam_roots[@]} -eq 0 ]; then
            _real_home="${HOME}"
            if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ]; then
                _real_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || echo "$HOME")"
            fi
            _steam_roots=()
            for _h in "$HOME" "$_real_home"; do
                for _vdf in "${_h}/.steam/steam/steamapps/libraryfolders.vdf" \
                            "${_h}/.steam/debian-installation/steamapps/libraryfolders.vdf" \
                            "${_h}/.local/share/Steam/steamapps/libraryfolders.vdf"; do
                    if [ -f "$_vdf" ]; then
                        while IFS= read -r _lpath; do
                            [ -n "$_lpath" ] && _steam_roots+=("$_lpath")
                        done < <(grep '"path"' "$_vdf" 2>/dev/null \
                                 | sed 's/.*"path"[[:space:]]*"\([^"]*\)".*/\1/')
                        break 2
                    fi
                done
            done
            if [ ${#_steam_roots[@]} -eq 0 ]; then
                for _h in "$HOME" "$_real_home"; do
                    _steam_roots+=("${_h}/.steam/steam" "${_h}/.steam/debian-installation" "${_h}/.local/share/Steam")
                done
            fi
        fi
        for _root in "${_steam_roots[@]}"; do
            _common="${_root}/steamapps/common"
            [ -d "$_common" ] || continue
            for _pname in "${_proton_names[@]}"; do
                [ -d "${_common}/${_pname}/files" ] && \
                    _proton_candidates+=("${_common}/${_pname}/files")
            done
            for _pdir in "${_common}"/Proton*/files; do
                [ -d "$_pdir" ] || continue
                _dup=false
                for _existing in "${_proton_candidates[@]}"; do
                    [ "$_existing" = "$_pdir" ] && { _dup=true; break; }
                done
                [ "$_dup" = "true" ] || _proton_candidates+=("$_pdir")
            done
        done
    fi
    for _candidate in "${_proton_candidates[@]}"; do
        if [ -d "${_candidate}/lib/wine/x86_64-windows" ]; then
            _proton_src="${_candidate}"
            break
        fi
    done
fi

if [ -z "${_proton_src:-}" ]; then
    warn "No Proton source found — skipping additional Steam component bootstrap."
else
    msg2 "Using Proton source: ${_proton_src}"

    # steam_helper.exe / steam.exe
    _steam_helper_files=(
        "lib/wine/x86_64-windows/steam_helper.exe"
        "lib/wine/i386-windows/steam_helper.exe"
        "lib/wine/x86_64-windows/steam.exe"
        "lib/wine/i386-windows/steam.exe"
    )
    _sh_copied=0
    for _f in "${_steam_helper_files[@]}"; do
        _src="${_proton_src}/${_f}"
        _dst="${_wine_lib_dir}/${_f#lib/wine/}"
        if [ -f "${_src}" ]; then
            mkdir -p "$(dirname "${_dst}")"
            cp -f "${_src}" "${_dst}"
            msg2 "Copied: ${_f}"
            (( _sh_copied++ )) || true
        fi
    done
    if [ $_sh_copied -gt 0 ]; then
        ok "steam_helper/steam.exe bootstrap: ${_sh_copied} file(s)"
    else
        warn "steam_helper.exe not found in Proton source — some overlay features may not work"
    fi

    # gameoverlayrenderer
    _overlay_files=(
        "lib/wine/x86_64-unix/gameoverlayrenderer.so"
        "lib/wine/i386-unix/gameoverlayrenderer.so"
    )
    _ov_copied=0
    for _f in "${_overlay_files[@]}"; do
        _src="${_proton_src}/${_f}"
        _dst="${_wine_lib_dir}/${_f#lib/wine/}"
        if [ -f "${_src}" ]; then
            mkdir -p "$(dirname "${_dst}")"
            cp -f "${_src}" "${_dst}"
            msg2 "Copied: ${_f}"
            (( _ov_copied++ )) || true
        fi
    done
    if [ $_ov_copied -gt 0 ]; then
        ok "gameoverlayrenderer bootstrap: ${_ov_copied} file(s)"
    else
        warn "gameoverlayrenderer.so not found in Proton source — in-game overlay may not work"
    fi

    # steamclient.dll (some Proton builds ship this separately)
    _sc_files=(
        "lib/wine/x86_64-windows/steamclient.dll"
        "lib/wine/i386-windows/steamclient.dll"
        "lib/wine/x86_64-windows/steamclient64.dll"
        "lib/wine/i386-windows/steamclient64.dll"
    )
    _sc_copied=0
    for _f in "${_sc_files[@]}"; do
        _src="${_proton_src}/${_f}"
        _dst="${_wine_lib_dir}/${_f#lib/wine/}"
        if [ -f "${_src}" ]; then
            mkdir -p "$(dirname "${_dst}")"
            cp -f "${_src}" "${_dst}"
            msg2 "Copied: ${_f}"
            (( _sc_copied++ )) || true
        fi
    done
    if [ $_sc_copied -gt 0 ]; then
        ok "steamclient bootstrap: ${_sc_copied} file(s)"
    else
        msg2 "steamclient.dll not found in Proton source (may not be needed)"
    fi
fi

# Clean up downloaded Proton temp dir if we created one
[ -n "${_dl_tmp:-}" ] && [ -d "${_dl_tmp:-}" ] && rm -rf "${_dl_tmp}"

# ══════════════════════════════════════════════════════════════════════════════
#  Ship DXVK and VKD3D-Proton config files
# ══════════════════════════════════════════════════════════════════════════════
sep "Installing runtime configs"
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_files_dir="${NEUTRON_PACKAGE_DIR}/files"

if [ -f "${_script_dir}/dxvk.conf" ]; then
    cp -f "${_script_dir}/dxvk.conf" "${_files_dir}/dxvk.conf"
    ok "dxvk.conf installed"
else
    msg2 "dxvk.conf not found alongside packager — skipping"
fi
if [ -f "${_script_dir}/vkd3d-proton.conf" ]; then
    cp -f "${_script_dir}/vkd3d-proton.conf" "${_files_dir}/vkd3d-proton.conf"
    ok "vkd3d-proton.conf installed"
else
    msg2 "vkd3d-proton.conf not found alongside packager — skipping"
fi

sep "Installing neutron launcher"
_launcher_src="${_script_dir}/neutron.py"
if [ ! -f "$_launcher_src" ]; then
    err "neutron.py not found alongside packager: $_launcher_src"
fi
cp -f "$_launcher_src" "${NEUTRON_PACKAGE_DIR}/neutron"
chmod +x "${NEUTRON_PACKAGE_DIR}/neutron"
ok "neutron launcher installed ($(wc -l < "$_launcher_src") lines)"

# ══════════════════════════════════════════════════════════════════════════════
#  Write version file (read by the Python launcher for prefix versioning)
#
#  Format: "<timestamp> <build-name>"  — the launcher takes the last token
#  as the prefix schema version via load_prefix_version().
# ══════════════════════════════════════════════════════════════════════════════
_version_str="${BUILD_NAME}"
if [ -n "$_wine_ver" ] && [ "$_wine_ver" != "unknown" ]; then
    # Strip "wine-" prefix and anything after the version number
    # e.g. "wine-11.16 (Staging)" -> "11.16", "wine-10.17.r0.gabcdef" -> "10.17"
    _clean_ver="$(printf '%s' "${_wine_ver#wine-}" | sed 's/[[:space:]].*//' | grep -oP '^\d+\.\d+')"
    [ -n "$_clean_ver" ] && _version_str="${BUILD_NAME}-${_clean_ver}"
fi
printf '%s %s\n' "$(date +%s)" "$_version_str" > "${NEUTRON_PACKAGE_DIR}/version"
ok "version file written: $_version_str"

# ══════════════════════════════════════════════════════════════════════════════
#  Write a minimal README inside the package
# ══════════════════════════════════════════════════════════════════════════════
sep "Writing package README"
cat > "${NEUTRON_PACKAGE_DIR}/README.md" << EOF
# ${BUILD_NAME}

Built by **mythix-neutron_builder**.

| Component       | Status                                       |
|-----------------|----------------------------------------------|
| proton-wine     | ${_wine_ver}                                 |
| DXVK            | ${DXVK_SOURCE_KEY}                           |
| VKD3D-Proton    | ${VKD3D_SOURCE_KEY}                          |

## Installation

Copy this directory into Steam's compatibility tools folder and restart Steam:

\`\`\`bash
cp -r "$(basename "$NEUTRON_PACKAGE_DIR")" ~/.steam/steam/compatibilitytools.d/
\`\`\`

Then open a game's Properties → Compatibility and select **${_display_name}**.

## Built with

- [mythix-neutron_builder](https://github.com/blu2442/mythix-neutron_builder)
- [ValveSoftware/wine](https://github.com/ValveSoftware/wine)
EOF
ok "README written"

# ══════════════════════════════════════════════════════════════════════════════
#  Verify the package structure
# ══════════════════════════════════════════════════════════════════════════════
sep "Verifying package"

_verify() {
    local path="$1" label="$2"
    if [ -e "$path" ]; then
        ok "$label"
    else
        warn "Expected file missing: $path"
    fi
}

_verify "${NEUTRON_PACKAGE_DIR}/compatibilitytool.vdf" "compatibilitytool.vdf"
_verify "${NEUTRON_PACKAGE_DIR}/toolmanifest.vdf"       "toolmanifest.vdf"
_verify "${NEUTRON_PACKAGE_DIR}/neutron"                "neutron launcher"
_verify "${WINE_INSTALL_PREFIX}/bin/wine"              "files/bin/wine"
_verify "${WINE_INSTALL_PREFIX}/bin/wineserver"        "files/bin/wineserver"
_verify "${WINE_INSTALL_PREFIX}/bin/wine64"            "files/bin/wine64"

# ── Package size ──────────────────────────────────────────────────────────────
_pkg_size="$(du -sh "$NEUTRON_PACKAGE_DIR" 2>/dev/null | cut -f1)"
ok "Package size: ${_pkg_size}"

sep "Packaging complete"
ok "Neutron package ready at: ${NEUTRON_PACKAGE_DIR}"
msg2 "To install:  cp -r ${NEUTRON_PACKAGE_DIR} ~/.steam/steam/compatibilitytools.d/"
msg2 "Then restart Steam and enable in game Properties → Compatibility."
