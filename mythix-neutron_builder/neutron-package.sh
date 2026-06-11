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
  "manifest_version"   "2"
  "commandline"        "/neutron waitforexitandrun"
  "use_sessions"       "1"
  "require_tool_appid" "1391110"
}
EOF
    ok "toolmanifest.vdf written (Sniper mode — Steam Runtime 3.0 container)"
else
    cat > "${NEUTRON_PACKAGE_DIR}/toolmanifest.vdf" << 'EOF'
"manifest"
{
  "manifest_version"   "2"
  "commandline"        "/neutron waitforexitandrun"
  "use_sessions"       "1"
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

sep "Writing neutron launcher script"
cat > "${NEUTRON_PACKAGE_DIR}/neutron" << 'NEUTRON_SCRIPT'
#!/usr/bin/env python3
# mythix-neutron launcher
# Steam invokes this script with a verb and optional arguments.
#
# Verbs Steam uses:
#   waitforexitandrun  — most common: run the game and wait for it to exit
#   run                — run without waiting (Steam polls for exit itself)
#   runinprefix        — run a helper command inside the Wine prefix
#   getcompatpath      — convert a Unix path to a Windows path (print to stdout)
#   getnativepath      — convert a Windows path to a Unix path (print to stdout)
#   stop               — kill the wineserver for this prefix
#
# Steam sets these environment variables before calling us:
#   STEAM_COMPAT_DATA_PATH          — game's compat data dir; prefix = <path>/pfx
#   STEAM_COMPAT_CLIENT_INSTALL_PATH — Steam client installation directory
#   STEAM_COMPAT_INSTALL_PATH       — game's installation directory
#   SteamAppId                      — numeric App ID
#   SteamGameId                     — numeric Game ID (may differ from AppId)

import os
import sys
import subprocess
import shutil

# ── Path resolution ────────────────────────────────────────────────────────────
SCRIPT_PATH  = os.path.realpath(__file__)
NEUTRON_DIR  = os.path.dirname(SCRIPT_PATH)
FILES_DIR    = os.path.join(NEUTRON_DIR, "files")
BIN_DIR      = os.path.join(FILES_DIR, "bin")
LIB_DIR      = os.path.join(FILES_DIR, "lib")
LIB64_DIR    = os.path.join(FILES_DIR, "lib64")
WINE_LIB_DIR = os.path.join(FILES_DIR, "lib")   # Wine DLLs live here, not lib64

# Wine binaries
WINE_PATH    = os.path.join(BIN_DIR, "wine")
WINE64_PATH  = os.path.join(BIN_DIR, "wine64")
SERVER_PATH  = os.path.join(BIN_DIR, "wineserver")
BOOT_PATH    = os.path.join(BIN_DIR, "wineboot")

# DXVK DLL directories (D3D9 / D3D10 / D3D11 / DXGI → Vulkan)
DXVK_DIR_64 = os.path.join(LIB64_DIR, "wine", "dxvk")
DXVK_DIR_32 = os.path.join(LIB_DIR,   "wine", "dxvk")

# VKD3D-Proton DLL directories (D3D12 → Vulkan)
VKD3D_DIR_64 = os.path.join(LIB64_DIR, "wine", "vkd3d-proton")
VKD3D_DIR_32 = os.path.join(LIB_DIR,   "wine", "vkd3d-proton")

def die(msg):
    print(f"neutron: ERROR: {msg}", file=sys.stderr)
    sys.exit(1)

# ── Sanity check ───────────────────────────────────────────────────────────────
if not os.path.isfile(WINE_PATH):
    die(f"Wine binary not found: {WINE_PATH}\n"
        f"Make sure the neutron build completed successfully.")

if len(sys.argv) < 2:
    die("Usage: neutron <verb> [args...]")

VERB       = sys.argv[1]
EXTRA_ARGS = sys.argv[2:]

# ── Steam environment ──────────────────────────────────────────────────────────
COMPAT_DATA    = os.environ.get("STEAM_COMPAT_DATA_PATH", "")
WINE_PREFIX    = os.path.join(COMPAT_DATA, "pfx") if COMPAT_DATA else ""
STEAM_ROOT     = os.environ.get("STEAM_COMPAT_CLIENT_INSTALL_PATH", "")
GAME_INSTALL   = os.environ.get("STEAM_COMPAT_INSTALL_PATH", "")
APP_ID         = os.environ.get("SteamAppId", "")
GAME_ID        = os.environ.get("SteamGameId", APP_ID)

# ── Build the Wine environment ─────────────────────────────────────────────────
env = os.environ.copy()

# ── Wine binary pointers ───────────────────────────────────────────────────────
env["WINE"]       = WINE_PATH
env["WINE64"]     = WINE64_PATH
env["WINESERVER"] = SERVER_PATH
env["WINEBOOT"]   = BOOT_PATH
# WINELOADER is critical — Wine re-execs itself through this path for WoW64
# (32-bit processes inside a 64-bit prefix). Without it, games silently exit 0.
env["WINELOADER"] = WINE64_PATH if os.path.isfile(WINE64_PATH) else WINE_PATH

# ── Wine prefix ───────────────────────────────────────────────────────────────
if WINE_PREFIX:
    env["WINEPREFIX"] = WINE_PREFIX
    os.makedirs(WINE_PREFIX, exist_ok=True)

# ── PATH: our bin dir first ────────────────────────────────────────────────────
env["PATH"] = BIN_DIR + ":" + env.get("PATH", "/usr/bin:/bin")

# ── LD_LIBRARY_PATH ───────────────────────────────────────────────────────────
# Include our Wine libs, DXVK dirs, VKD3D dirs, and the Steam overlay libs.
# The Steam overlay injects gameoverlayrenderer.so — it needs to find it.
overlay_paths = []
if STEAM_ROOT:
    overlay_paths += [
        os.path.join(STEAM_ROOT, "ubuntu12_64"),
        os.path.join(STEAM_ROOT, "ubuntu12_32"),
    ]

ld_parts = [LIB64_DIR, LIB_DIR, WINE_LIB_DIR,
            DXVK_DIR_64, DXVK_DIR_32,
            VKD3D_DIR_64, VKD3D_DIR_32] + overlay_paths
existing_ld = env.get("LD_LIBRARY_PATH", "")
env["LD_LIBRARY_PATH"] = ":".join(p for p in ld_parts + [existing_ld] if p)

# ── WINEDLLPATH: where Wine looks for Windows DLLs ───────────────────────────
# This is what makes DXVK and VKD3D-Proton actually get loaded.
# Wine searches these directories for .dll files before its own builtins.
dll_paths = []
# Standard Wine PE DLL directories — Wine needs these to find its own built-in DLLs
_wine_pe_64 = os.path.join(LIB_DIR, "wine", "x86_64-windows")
_wine_pe_32 = os.path.join(LIB_DIR, "wine", "i386-windows")
for _d in [_wine_pe_64, _wine_pe_32]:
    if os.path.isdir(_d):
        dll_paths.append(_d)
# DXVK / VKD3D override directories
for d in [DXVK_DIR_64, VKD3D_DIR_64, DXVK_DIR_32, VKD3D_DIR_32]:
    if os.path.isdir(d):
        dll_paths.append(d)
if dll_paths:
    existing_dllpath = env.get("WINEDLLPATH", "")
    env["WINEDLLPATH"] = ":".join(dll_paths + ([existing_dllpath] if existing_dllpath else []))

# ── WINEDLLOVERRIDES: force DXVK, VKD3D, and Steam API DLLs to native ────────
# Without these overrides Wine uses its own built-in WineD3D even if DXVK
# DLLs are present in WINEDLLPATH.  "n,b" = try native first, then builtin.
#
# lsteamclient: CRITICAL for games that call SteamAPI_Init().
#   Wine's built-in lsteamclient stub cannot talk to the real Steam client.
#   With "n,b" Wine loads the native lsteamclient.dll (built as a PE .dll by
#   our Wine build) which bridges to the host steamclient.so via the
#   STEAM_COMPAT_CLIENT_INSTALL_PATH libraries already in LD_LIBRARY_PATH.
#   Without this, games using Steamworks hang at startup (black screen).
dxvk_overrides    = "d3d9=n,b;d3d10=n,b;d3d10_1=n,b;d3d10core=n,b;d3d11=n,b;dxgi=n,b"
vkd3d_overrides   = "d3d12=n,b;d3d12core=n,b"
steam_overrides   = "lsteamclient=n,b;steamclient=n,b;openvr_api_dxvk=disabled;vrclient_x64=disabled;vrclient=disabled"

# Only add overrides for components that are actually installed
active_overrides = []
if os.path.isdir(DXVK_DIR_64) and any(
        f.endswith(".dll") for f in os.listdir(DXVK_DIR_64)):
    active_overrides.append(dxvk_overrides)
if os.path.isdir(VKD3D_DIR_64) and any(
        f.endswith(".dll") for f in os.listdir(VKD3D_DIR_64)):
    active_overrides.append(vkd3d_overrides)

# lsteamclient override is always applied when running inside Steam
# (STEAM_COMPAT_DATA_PATH is set by Steam before invoking us)
if COMPAT_DATA:
    active_overrides.append(steam_overrides)

if active_overrides:
    existing_overrides = env.get("WINEDLLOVERRIDES", "")
    combined = ";".join(active_overrides)
    env["WINEDLLOVERRIDES"] = (combined + ";" + existing_overrides
                               if existing_overrides else combined)

# ── Synchronization primitives ────────────────────────────────────────────────
# Detect what sync modes are compiled into the wineserver binary and enable
# the best available one automatically — no manual env var needed.
#
# Priority: ntsync (kernel module, fastest) > fsync > esync > server-side
#
# ntsync activates by itself when /dev/ntsync exists AND the binary has
# ntsync support compiled in — no env var needed for it.
# fsync/esync require WINEFSYNC=1 / WINEESYNC=1 to activate.
#
# If the user has already set these externally we respect their choice.

def _binary_has(binary_path, search_string):
    """Check if a binary contains a given string (like `strings | grep`)."""
    try:
        with open(binary_path, "rb") as f:
            return search_string.encode() in f.read()
    except OSError:
        return False

_has_ntsync = _binary_has(SERVER_PATH, "ntsync")
_has_fsync  = _binary_has(SERVER_PATH, "fsync")
_has_esync  = _binary_has(SERVER_PATH, "esync")

if _has_ntsync:
    # ntsync is compiled in — it activates automatically via /dev/ntsync,
    # no env var needed. Still set fsync as fallback for when the module
    # isn't loaded.
    if _has_fsync:
        env.setdefault("WINEFSYNC", "1")
    if _has_esync:
        env.setdefault("WINEESYNC", "1")
elif _has_fsync:
    # No ntsync (e.g. Valve proton-wine) — enable fsync explicitly.
    env.setdefault("WINEFSYNC", "1")
    if _has_esync:
        env.setdefault("WINEESYNC", "1")
elif _has_esync:
    # Older Wine without fsync — esync only.
    env.setdefault("WINEESYNC", "1")
# else: server-side sync only — nothing to set
env.setdefault("WINE_LARGE_ADDRESS_AWARE", "1")
env.setdefault("WINEDEBUG",               "-all")  # suppress noise; override externally if needed
env.setdefault("DXVK_LOG_LEVEL",          "none")  # suppress DXVK HUD spam by default

# ── DXVK config file ─────────────────────────────────────────────────────────
# Point DXVK at our shipped config unless the user has their own
_dxvk_conf = os.path.join(FILES_DIR, "dxvk.conf")
if os.path.isfile(_dxvk_conf):
    env.setdefault("DXVK_CONFIG_FILE", _dxvk_conf)

# ── DXVK async shader compilation ────────────────────────────────────────────
env.setdefault("DXVK_ASYNC", "1")

# ── Mesa / Vulkan driver hints ────────────────────────────────────────────────
# RADV (AMD): enable shader pre-caching, NGG culling
env.setdefault("RADV_PERFTEST", "gpl,nggc,sam")
# ANV (Intel): nothing specific needed but keep defaults sane
# NVIDIA: controlled by nvidia-settings / env; keep hands off unless user overrides

# ── GameMode integration ──────────────────────────────────────────────────────
# Auto-detect Feral GameMode and wrap the game process for CPU governor + nice
_gamemode_available = shutil.which("gamemoderun") is not None
_use_gamemode = os.environ.get("NEUTRON_GAMEMODE", "auto")
if _use_gamemode == "auto":
    _use_gamemode = "1" if _gamemode_available else "0"
GAMEMODE_WRAP = _use_gamemode == "1" and _gamemode_available

# ── MangoHud integration ─────────────────────────────────────────────────────
# If MANGOHUD=1 is set by the user (e.g., via Steam launch options), we let it
# through naturally. No auto-enable — user opt-in only.
# We just ensure MANGOHUD_DLSYM is set for proper hooking.
if env.get("MANGOHUD") == "1":
    env.setdefault("MANGOHUD_DLSYM", "1")

# Steam App ID forwarding
if APP_ID:
    env.setdefault("SteamAppId",  APP_ID)
    env.setdefault("SteamGameId", GAME_ID)

# ── Prefix initialization ──────────────────────────────────────────────────────
def _install_dlls_into_prefix(src_dir, dst_dir):
    """Copy all .dll files from src_dir into dst_dir (system32 or syswow64)."""
    if not os.path.isdir(src_dir):
        return
    os.makedirs(dst_dir, exist_ok=True)
    for f in os.listdir(src_dir):
        if f.lower().endswith(".dll"):
            shutil.copy2(os.path.join(src_dir, f), os.path.join(dst_dir, f))

def init_prefix():
    """Initialize the Wine prefix if it hasn't been set up yet."""
    if not WINE_PREFIX:
        return
    system_reg = os.path.join(WINE_PREFIX, "system.reg")
    if not os.path.isfile(system_reg):
        print("neutron: initializing Wine prefix...", file=sys.stderr)
        subprocess.run(
            [BOOT_PATH, "--init"],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        sys32  = os.path.join(WINE_PREFIX, "drive_c", "windows", "system32")
        syswow = os.path.join(WINE_PREFIX, "drive_c", "windows", "syswow64")
        print("neutron: installing DXVK into prefix...", file=sys.stderr)
        _install_dlls_into_prefix(DXVK_DIR_64, sys32)
        _install_dlls_into_prefix(DXVK_DIR_32, syswow)
        print("neutron: installing VKD3D-Proton into prefix...", file=sys.stderr)
        _install_dlls_into_prefix(VKD3D_DIR_64, sys32)
        _install_dlls_into_prefix(VKD3D_DIR_32, syswow)

# ── Verb handlers ──────────────────────────────────────────────────────────────
def verb_run(args, wait=True):
    """Run a Windows executable through Wine."""
    init_prefix()
    runner = WINE64_PATH if os.path.isfile(WINE64_PATH) else WINE_PATH

    # Use "start /wait" mode for games with a launcher exe that spawns the
    # real game as a child process (e.g. Skyrim's SkyrimSELauncher.exe).
    # Without this, Wine exits as soon as the launcher quits, orphaning the game.
    # Auto-detect: if NEUTRON_START_WAIT=1 or the exe name contains "launcher",
    # use start /wait. Can also be forced via env var.
    use_start_wait = os.environ.get("NEUTRON_START_WAIT", "auto")
    exe_name = os.path.basename(args[0]).lower() if args else ""
    if use_start_wait == "auto":
        use_start_wait = "launcher" in exe_name
    else:
        use_start_wait = use_start_wait == "1"

    if use_start_wait:
        print(f"neutron: using start /wait mode (launcher detected: {exe_name})", file=sys.stderr)
        cmd = [runner, "start", "/wait", "/unix"] + args
    else:
        cmd = [runner] + args

    # Wrap with gamemoderun if available and enabled
    if GAMEMODE_WRAP:
        cmd = ["gamemoderun"] + cmd
    proc = subprocess.Popen(cmd, env=env)
    if wait:
        try:
            proc.wait()
        except KeyboardInterrupt:
            proc.terminate()
        # After the main process exits, wait for wineserver to finish —
        # catches child processes that outlive their parent (common pattern)
        try:
            subprocess.run([SERVER_PATH, "-w"], env=env, timeout=30)
        except (subprocess.TimeoutExpired, Exception):
            pass
        sys.exit(proc.returncode)
    sys.exit(0)

def verb_runinprefix(args):
    """Run a helper command inside the Wine prefix."""
    init_prefix()
    runner = WINE64_PATH if os.path.isfile(WINE64_PATH) else WINE_PATH
    proc = subprocess.run([runner] + args, env=env)
    sys.exit(proc.returncode)

def verb_getcompatpath(args):
    """Convert a Unix path to a Windows path (printed to stdout for Steam)."""
    unix_path = args[0] if args else ""
    runner = WINE64_PATH if os.path.isfile(WINE64_PATH) else WINE_PATH
    result = subprocess.run(
        [runner, "winepath", "-w", unix_path],
        env=env, capture_output=True, text=True,
    )
    print(result.stdout.strip())
    sys.exit(result.returncode)

def verb_getnativepath(args):
    """Convert a Windows path to a Unix path (printed to stdout for Steam)."""
    win_path = args[0] if args else ""
    runner = WINE64_PATH if os.path.isfile(WINE64_PATH) else WINE_PATH
    result = subprocess.run(
        [runner, "winepath", "-u", win_path],
        env=env, capture_output=True, text=True,
    )
    print(result.stdout.strip())
    sys.exit(result.returncode)

def verb_stop():
    """Kill the wineserver for the current prefix."""
    subprocess.run([SERVER_PATH, "-k"], env=env)
    sys.exit(0)

# ── Dispatch ───────────────────────────────────────────────────────────────────
if VERB in ("run", "waitforexitandrun"):
    verb_run(EXTRA_ARGS, wait=True)
elif VERB == "runinprefix":
    verb_runinprefix(EXTRA_ARGS)
elif VERB == "getcompatpath":
    verb_getcompatpath(EXTRA_ARGS)
elif VERB == "getnativepath":
    verb_getnativepath(EXTRA_ARGS)
elif VERB == "stop":
    verb_stop()
else:
    # Forward-compatibility: unknown verbs attempted as wine commands
    print(f"neutron: unknown verb '{VERB}', forwarding to wine", file=sys.stderr)
    verb_run([VERB] + EXTRA_ARGS)
NEUTRON_SCRIPT

chmod +x "${NEUTRON_PACKAGE_DIR}/neutron"
ok "neutron launcher written"

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
