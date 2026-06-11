#!/usr/bin/env bash
# ╔═════════════════════════════════════════════════════════════════════════════╗
# ║            mythix-neutron_builder  •  multi-component  v1.0.0               ║
# ║   WineHQ  •  proton-wine  •  DXVK  •  VKD3D-Proton  •  Steam package      ║
# ╚═════════════════════════════════════════════════════════════════════════════╝
#
# Entry point for building a custom Neutron compatibility tool for Steam.
#
# Phase 1 (this release):
#   • proton-wine  — Valve's Wine fork, compiled with --with-mingw + Proton flags
#   • Packaging    — Steam-loadable Neutron layout (compatibilitytool.vdf etc.)
#
# Components:
#   • DXVK        — D3D9/10/11 → Vulkan (neutron-dxvk-build.sh)
#   • VKD3D-Proton — D3D12 → Vulkan (neutron-vkd3d-build.sh)
#
# Usage:  ./neutron-builder.sh [options]
#         ./neutron-builder.sh --help
#
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# ══════════════════════════════════════════════════════════════════════════════
#  Path resolution — works from both the source tree and after `make install`
#
#  Source tree layout:
#    mythix-neutron_builder/
#      neutron-builder.sh        ← this script
#      neutron-build-core.sh     ← engine scripts alongside it
#      neutron-customization.cfg ← config alongside it
#      buildz/                   ← build output
#      src/                      ← git clones
#
#  Installed layout (make install PREFIX=~/.local):
#    ~/.local/bin/neutron-builder                   ← this script
#    ~/.local/lib/mythix-neutron_builder/*.sh        ← engine scripts
#    ~/.config/mythix-build/*.cfg                    ← config
#    ~/.local/share/mythix-neutron_builder/          ← build output + git clones
# ══════════════════════════════════════════════════════════════════════════════
if [ -f "${SCRIPT_DIR}/neutron-build-core.sh" ]; then
    # Running directly from the source tree — lib scripts are alongside us,
    # but data (build output, git clones) always goes to the XDG data dir so
    # builds never accumulate inside the git repo.
    _LIB_DIR="$SCRIPT_DIR"
    _CFG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/mythix-build"
    _DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/mythix-neutron_builder"
elif [ -f "${SCRIPT_DIR}/../lib/mythix-neutron_builder/neutron-build-core.sh" ]; then
    # Running from an installed bin/ directory
    _LIB_DIR="$(cd "${SCRIPT_DIR}/../lib/mythix-neutron_builder" && pwd)"
    _CFG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/mythix-build"
    _DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/mythix-neutron_builder"
else
    printf "ERR! Cannot locate engine scripts.\n" >&2
    printf "     Expected alongside this script or in ../lib/mythix-neutron_builder/\n" >&2
    printf "     Run from the source tree, or install with: make install\n" >&2
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Colour & output helpers
# ══════════════════════════════════════════════════════════════════════════════
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
    C_R="\033[0m" C_B="\033[1m"
    C_GRN="\033[1;32m" C_BLU="\033[1;34m"
    C_YLW="\033[1;33m" C_RED="\033[1;31m"
    C_CYN="\033[1;36m" C_MAG="\033[1;35m"
    C_DIM="\033[2m"
else
    C_R="" C_B="" C_GRN="" C_BLU="" C_YLW="" C_RED="" C_CYN="" C_MAG="" C_DIM=""
fi

# ── Resolve _LIB_DIR early so we can source _output_common.sh from it ────
if [ -f "${SCRIPT_DIR}/neutron-build-core.sh" ]; then
    _LIB_DIR="$SCRIPT_DIR"
elif [ -f "${SCRIPT_DIR}/../lib/mythix-neutron_builder/neutron-build-core.sh" ]; then
    _LIB_DIR="$(cd "${SCRIPT_DIR}/../lib/mythix-neutron_builder" && pwd)"
else
    _LIB_DIR=""
fi

# Source common output helpers (uses the C_* color variables set above)
if [ -n "$_LIB_DIR" ] && [ -f "${_LIB_DIR}/_output_common.sh" ]; then
    . "${_LIB_DIR}/_output_common.sh"
elif [ -f "${SCRIPT_DIR}/_output_common.sh" ]; then
    . "${SCRIPT_DIR}/_output_common.sh"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Banner
# ══════════════════════════════════════════════════════════════════════════════
print_banner() {
    printf "\n${C_MAG}${C_B}"
    cat << 'WOLF'
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠸⠁⠸⢳⡄⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢠⠃⠀⠀⢸⠸⠀⡠⣄⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡠⠃⠀⠀⢠⣞⣀⡿⠀⠀⣧⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣠⡖⠁⠀⠀⠀⢸⠈⢈⡇⠀⢀⡏⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⡴⠩⢠⡴⠀⠀⠀⠀⠀⠈⡶⠉⠀⠀⡸⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⢀⠎⢠⣇⠏⠀⠀⠀⠀⠀⠀⠀⠁⠀⢀⠄⡇⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⢠⠏⠀⢸⣿⣴⠀⠀⠀⠀⠀⠀⣆⣀⢾⢟⠴⡇⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⢀⣿⠀⠠⣄⠸⢹⣦⠀⠀⡄⠀⠀⢋⡟⠀⠀⠁⣇⠀⠀⠀⠀⠀
⠀⠀⠀⠀⢀⡾⠁⢠⠀⣿⠃⠘⢹⣦⢠⣼⠀⠀⠉⠀⠀⠀⠀⢸⡀⠀⠀⠀⠀
⠀⠀⢀⣴⠫⠤⣶⣿⢀⡏⠀⠀⠘⢸⡟⠋⠀⠀⠀⠀⠀⠀⠀⠀⢳⠀⠀⠀⠀
⠐⠿⢿⣿⣤⣴⣿⣣⢾⡄⠀⠀⠀⠀⠳⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢣⠀⠀⠀
⠀⠀⠀⣨⣟⡍⠉⠚⠹⣇⡄⠀⠀⠀⠀⠀⠀⠀⠀⠈⢦⠀⠀⢀⡀⣾⡇⠀⠀
⠀⠀⢠⠟⣹⣧⠃⠀⠀⢿⢻⡀⢄⠀⠀⠀⠀⠐⣦⡀⣸⣆⠀⣾⣧⣯⢻⠀⠀
⠀⠀⠘⣰⣿⣿⡄⡆⠀⠀⠀⠳⣼⢦⡘⣄⠀⠀⡟⡷⠃⠘⢶⣿⡎⠻⣆⠀⠀
⠀⠀⠀⡟⡿⢿⡿⠀⠀⠀⠀⠀⠙⠀⠻⢯⢷⣼⠁⠁⠀⠀⠀⠙⢿⡄⡈⢆⠀
⠀⠀⠀⠀⡇⣿⡅⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠙⠦⠀⠀⠀⠀⠀⠀⡇⢹⢿⡀
⠀⠀⠀⠀⠁⠛⠓⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠼⠇⠁
WOLF
    printf "\n"
    printf "  ╔═══════════════════════════════════════════════════════════════╗\n"
    printf "  ║                                                               ║\n"
    printf "  ║  🎮  mythix-neutron_builder  •  multi-component v1.0.0         ║\n"
    printf "  ║      proton-wine  •  DXVK  •  VKD3D-Proton  •  package        ║\n"
    printf "  ║                                                               ║\n"
    printf "  ╚═══════════════════════════════════════════════════════════════╝\n"
    printf "${C_R}\n"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Source catalogues
# ══════════════════════════════════════════════════════════════════════════════

# ── Wine source (required, pick one) ─────────────────────────────────────────
declare -A WINE_SOURCE_URL=(
    [mainline]="https://gitlab.winehq.org/wine/wine.git"
    [experimental]="https://gitlab.winehq.org/wine/wine.git"
    [staging]="https://gitlab.winehq.org/wine/wine.git"
    [proton-wine]="https://github.com/ValveSoftware/wine.git"
    [proton-wine-experimental]="https://github.com/ValveSoftware/wine.git"
    [ge-proton]="https://github.com/ValveSoftware/wine.git"
    [kron4ek-tkg]="https://github.com/Kron4ek/wine-tkg.git"
)
declare -A WINE_SOURCE_BRANCH=(
    [mainline]=""              # version picker selects the tag (wine-X.Y)
    [experimental]="master"   # WineHQ bleeding edge
    [staging]=""               # version picker queries wine-staging tags; clone at matching mainline tag
    [proton-wine]=""              # version picker selects the branch (proton_X.Y)
    [proton-wine-experimental]="bleeding-edge"
    [ge-proton]=""                # set by GE release picker → matching proton_X.Y branch
    [kron4ek-tkg]=""              # default branch tracks latest Wine + staging + TKG + ntsync
)
declare -A WINE_SOURCE_DESC=(
    [mainline]="WineHQ mainline       — official stable releases (version picker)"
    [experimental]="WineHQ experimental   — bleeding-edge master branch"
    [staging]="WineHQ + Staging      — mainline + community patches (version picker)"
    [proton-wine]="Valve proton-wine     — stable branches (version picker)"
    [proton-wine-experimental]="Valve proton-wine exp  — bleeding-edge (no version picker)"
    [ge-proton]="GE-Proton (GloriousEggroll) — proton-wine + GE gaming patches (version picker)"
    [kron4ek-tkg]="Kron4ek wine-tkg      — Wine source tree with Staging + TKG + ntsync patches"
)
declare -A WINE_SOURCE_HAS_VERSIONS=(
    [mainline]="true"
    [staging]="true"          # queries wine-staging repo for tags, then clones matching mainline
    [proton-wine]="true"
    [ge-proton]="true"        # queries GE release tags (GE-Proton9-20, etc.)
    [kron4ek-tkg]="true"
)
declare -A WINE_SOURCE_VERSION_REF_TYPE=(
    [mainline]="tags"         # wine-X.Y tags
    [staging]="tags"          # staging version picker queries wine-staging repo separately
    [proton-wine]="heads"     # branches, not tags
    [ge-proton]="tags"        # GE release tags
    [kron4ek-tkg]="tags"      # standard wine-X.Y tags
)
# Sources that need wine-staging patches applied after clone
declare -A WINE_SOURCE_NEEDS_STAGING=(
    [staging]="true"
)
# GE-Proton repo URL (separate from Wine source — used to fetch patches)
GE_PROTON_REPO="https://github.com/GloriousEggroll/proton-ge-custom.git"
WINE_SOURCE_KEYS=( mainline experimental staging proton-wine proton-wine-experimental ge-proton kron4ek-tkg )

# ── DXVK source ──────────────────────────────────────────────────────────────
declare -A DXVK_SOURCE_URL=(
    [dxvk]="https://github.com/doitsujin/dxvk.git"
    [dxvk-async]="https://github.com/Sporif/dxvk-async.git"
    [dxvk-release]=""       # download pre-built binaries from GitHub releases
    [none]=""
)
declare -A DXVK_SOURCE_DESC=(
    [dxvk]="DXVK         — D3D9/10/11 → Vulkan (doitsujin/dxvk)"
    [dxvk-async]="DXVK async   — DXVK + async pipeline compilation"
    [dxvk-release]="DXVK release — pre-built DLLs from GitHub releases (fastest)"
    [none]="None         — skip DXVK (falls back to WineD3D for D3D9/10/11)"
)

# ── VKD3D-Proton source ───────────────────────────────────────────────────────
declare -A VKD3D_SOURCE_URL=(
    [vkd3d-proton]="https://github.com/HansKristian-Work/vkd3d-proton.git"
    [vkd3d-proton-release]=""   # download pre-built binaries from GitHub releases
    [none]=""
)
declare -A VKD3D_SOURCE_DESC=(
    [vkd3d-proton]="VKD3D-Proton         — D3D12 → Vulkan (HansKristian-Work)"
    [vkd3d-proton-release]="VKD3D-Proton release — pre-built DLLs from GitHub releases (fastest)"
    [none]="None                 — skip VKD3D-Proton (D3D12 games will not work)"
)

# ══════════════════════════════════════════════════════════════════════════════
#  Defaults  —  all overridable by flags
# ══════════════════════════════════════════════════════════════════════════════
DEST_ROOT="${_DATA_DIR}/buildz"
SRC_ROOT="${_DATA_DIR}/src"

WINE_SOURCE_KEY=""
WINE_SOURCE_BRANCH_ARG=""

DXVK_SOURCE_KEY="dxvk"         # default: include DXVK
DXVK_BRANCH_ARG=""
VKD3D_SOURCE_KEY="vkd3d-proton" # default: include VKD3D-Proton
VKD3D_BRANCH_ARG=""

BUILD_NAME=""
JOBS="${JOBS:-$(nproc)}"
SKIP_32BIT=false
NO_PULL=false
RESUME=false
SKIP_WINE_BUILD=false      # set by --dxvk-only / --vkd3d-only
SKIP_DXVK=false           # set by --vkd3d-only
REINSTALL_COMPONENTS=false # set by --reinstall-components
SNIPER_MODE=false          # set by --sniper (Steam Runtime Sniper container)
CONTAINER_BUILD=""         # "" = ask interactively; "true" = container; "false" = native
DRY_RUN=0
CUSTOM_CFG="${_CFG_DIR}/neutron-customization.cfg"
BUILD_CORE="${_LIB_DIR}/neutron-build-core.sh"
PACKAGER="${_LIB_DIR}/neutron-package.sh"
DXVK_BUILDER="${_LIB_DIR}/neutron-dxvk-build.sh"
VKD3D_BUILDER="${_LIB_DIR}/neutron-vkd3d-build.sh"
PATCHER="${_LIB_DIR}/neutron-patcher.sh"
PATCHES_DIR="${_LIB_DIR}/patches"
PATCH_GROUPS=""            # space-separated group names, "all", "none", or "" (interactive)

# ── Build tuning toggles ──────────────────────────────────────────────────────
NO_CCACHE=false           # --no-ccache: disable ccache entirely
KEEP_SYMBOLS=false        # --keep-symbols: skip strip, keep debug info
BUILD_TYPE="release"      # --build-type release|debug|debugoptimized
NATIVE_MARCH=false        # --native: compile with -march=native (non-portable)
LTO=false                 # --lto: enable link-time optimisation (slow link)

# ══════════════════════════════════════════════════════════════════════════════
#  Usage
# ══════════════════════════════════════════════════════════════════════════════
print_usage() {
    cat <<USAGE
${C_B}Usage:${C_R} $0 [options]

${C_B}Wine source (required):${C_R}
  --source NAME         mainline | experimental | staging | ge-proton |
                        proton-wine | proton-wine-experimental | kron4ek-tkg
  --branch BRANCH       Pin to a specific branch or tag (e.g. proton_9.0, wine-10.6)
                        Skips the interactive version picker when provided.
  --no-pull             Skip git pull on an existing source tree

${C_B}Component selection:${C_R}
  --dxvk NAME           DXVK variant: dxvk (default) | dxvk-release | dxvk-async | none
                        dxvk-release downloads pre-built DLLs from GitHub — no compile needed
  --vkd3d NAME          VKD3D variant: vkd3d-proton (default) | vkd3d-proton-release | none
                        vkd3d-proton-release downloads pre-built DLLs from GitHub — no compile needed
  --dxvk-branch BRANCH  Pin DXVK to a specific tag
  --vkd3d-branch BRANCH Pin VKD3D-Proton to a specific tag

${C_B}Build method:${C_R}
  --container           Build inside a Podman/Docker container (no local deps needed)
  --no-container        Build natively on the host (requires all build dependencies)
                        If neither is given, you will be prompted interactively.

${C_B}Build options:${C_R}
  --name NAME           Build name for install path (default: mythix-neutron-<ver>)
  --dest DIR            Root for build artefacts   (default: <script-dir>/buildz)
  --src-dir DIR         Root for git clones         (default: <script-dir>/src)
  --jobs N              Parallel make threads        (default: nproc = $(nproc))
  --skip-32             Skip the 32-bit Wine build
  --no-ccache           Disable ccache even if installed
  --keep-symbols        Skip strip — keep debug symbols in binaries
  --build-type TYPE     release (default) | debug | debugoptimized
  --native              Compile with -march=native (faster but non-portable)
  --lto                 Enable link-time optimisation (slower link, smaller binary)
  --resume              Skip configure if Makefile already exists
  --dxvk-only           Skip Wine entirely — jump straight to DXVK build + package
                        (requires a prior successful Wine build in buildz/install/)
  --vkd3d-only          Skip Wine entirely — jump straight to VKD3D-Proton build + package
  --reinstall-components  Skip Wine + skip building DXVK/VKD3D — just copy already-built
                        DLLs from src/*/build/ into the package and re-run the packager.
                        Use this after a Wine-only rebuild to restore DXVK/VKD3D.
  --cfg PATH            Alternate neutron-customization.cfg
  --patches GROUPS      Patch groups to apply (comma-separated, "all", or "none")
                        Interactive picker if omitted. Groups: ntsync, performance,
                        fullscreen-hack, mouse-fixes, game-fixes, media-foundation
  --patches-dir PATH    Alternate patches directory (default: alongside this script)
  --sniper              Enable Steam Runtime Sniper mode (container isolation)

${C_B}General:${C_R}
  --list                Show all installed Neutron builds
  --dry-run             Print planned actions without executing them
  -h | --help           Show this help

${C_B}Examples:${C_R}
  $0                                          # interactive source + version menu
  $0 --source mainline                        # WineHQ stable (version picker)
  $0 --source staging                         # WineHQ + staging patches (version picker)
  $0 --source experimental                    # WineHQ bleeding-edge master
  $0 --source proton-wine                     # Valve proton-wine (version picker)
  $0 --source proton-wine --branch proton_9.0 # pin to proton_9.0
  $0 --source kron4ek-tkg                     # Kron4ek wine-tkg + ntsync
  $0 --source proton-wine --dxvk none         # Wine only, no DXVK
  $0 --source mainline --jobs 16              # more threads
  $0 --source proton-wine --resume            # resume an interrupted build

${C_B}DXVK / VKD3D-Proton:${C_R}
  DXVK and VKD3D-Proton are compiled from source by default alongside Wine.
  Use --dxvk dxvk-release / --vkd3d vkd3d-proton-release to download pre-built
  binaries from GitHub instead (faster, no meson/ninja deps needed).
  Use --dxvk none / --vkd3d none to skip them entirely.

${C_B}Steam installation:${C_R}
  After a successful build, copy the package directory from:
    buildz/install/<build-name>/
  into:
    ~/.steam/steam/compatibilitytools.d/
  Then restart Steam and enable your custom Neutron in the game's
  Compatibility settings (Properties → Compatibility).
USAGE
}

# ══════════════════════════════════════════════════════════════════════════════
#  Argument parsing
# ══════════════════════════════════════════════════════════════════════════════
while [ "$#" -gt 0 ]; do
    case "$1" in
        --source)       WINE_SOURCE_KEY="$2";    shift 2 ;;
        --branch)       WINE_SOURCE_BRANCH_ARG="$2"; shift 2 ;;
        --dxvk)         DXVK_SOURCE_KEY="$2";   shift 2 ;;
        --vkd3d)        VKD3D_SOURCE_KEY="$2";  shift 2 ;;
        --dxvk-branch)  DXVK_BRANCH_ARG="$2";   shift 2 ;;
        --vkd3d-branch) VKD3D_BRANCH_ARG="$2";  shift 2 ;;
        --dest)         DEST_ROOT="$2";          shift 2 ;;
        --src-dir)      SRC_ROOT="$2";           shift 2 ;;
        --name)         BUILD_NAME="$2";         shift 2 ;;
        --jobs)         JOBS="$2";               shift 2 ;;
        --skip-32)      SKIP_32BIT=true;         shift   ;;
        --no-ccache)    NO_CCACHE=true;          shift   ;;
        --keep-symbols) KEEP_SYMBOLS=true;       shift   ;;
        --build-type)   BUILD_TYPE="$2";         shift 2 ;;
        --native)       NATIVE_MARCH=true;       shift   ;;
        --lto)          LTO=true;                shift   ;;
        --resume)       RESUME=true;             shift   ;;
        --verbose)      export VERBOSE_BUILD=true; shift   ;;
        --no-pull)      NO_PULL=true;            shift   ;;
        --dxvk-only)    SKIP_WINE_BUILD=true; DXVK_SOURCE_KEY="${DXVK_SOURCE_KEY:-dxvk}"; shift ;;
        --vkd3d-only)   SKIP_WINE_BUILD=true; SKIP_DXVK=true; VKD3D_SOURCE_KEY="${VKD3D_SOURCE_KEY:-vkd3d-proton}"; shift ;;
        --reinstall-components) SKIP_WINE_BUILD=true; REINSTALL_COMPONENTS=true; shift ;;
        --container)    CONTAINER_BUILD=true;        shift   ;;
        --no-container) CONTAINER_BUILD=false;       shift   ;;
        --kron4ek-redist)
            # Run just the compat redist function against an existing build dir
            # Usage: ./neutron-builder.sh --kron4ek-redist <BUILD_DIR> [NEUTRON_PKG_DIR]
            _KRON4EK_REDIST_BUILD="${2:-}"
            _KRON4EK_REDIST_PKG="${3:-}"
            shift; [ -n "$_KRON4EK_REDIST_BUILD" ] && shift || true
            [ -n "$_KRON4EK_REDIST_PKG" ] && shift || true
            ;;
        --cfg)          CUSTOM_CFG="$2";         shift 2 ;;
        --patches)      PATCH_GROUPS="$2";       shift 2 ;;
        --patches-dir)  PATCHES_DIR="$2";        shift 2 ;;
        --sniper)       SNIPER_MODE=true;        shift   ;;
        --dry-run)      DRY_RUN=1;               shift   ;;
        --list)         _LIST_MODE=true;         shift   ;;
        -h|--help)      print_usage; exit 0               ;;
        *) printf "Unknown option: %s\n" "$1" >&2; print_usage; exit 1 ;;
    esac
done

# ══════════════════════════════════════════════════════════════════════════════
#  List mode
# ══════════════════════════════════════════════════════════════════════════════
if [ "${_LIST_MODE:-false}" = "true" ]; then
    section "Installed Neutron builds"
    install_dir="${DEST_ROOT}/install"
    if [ ! -d "$install_dir" ] || [ -z "$(ls -A "$install_dir" 2>/dev/null)" ]; then
        msg2 "No builds found in ${install_dir}"
        exit 0
    fi
    printf "\n${C_B}  %-36s  %-28s  %s${C_R}\n" "build name" "wine version" "size"
    printf "  %s\n" "$(printf '─%.0s' {1..78})"
    for d in "$install_dir"/*/; do
        [ -d "$d" ] || continue
        _name="$(basename "$d")"
        _wine="${d}files/bin/wine"
        if [ -x "$_wine" ]; then
            _ver="$("$_wine" --version 2>/dev/null || printf 'unknown')"
        else
            _ver="(binary not found)"
        fi
        _size="$(du -sh "$d" 2>/dev/null | cut -f1)"
        printf "  ${C_CYN}%-36s${C_R}  %-28s  %s\n" "$_name" "$_ver" "$_size"
    done
    printf "\n"
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Dependency check
# ══════════════════════════════════════════════════════════════════════════════
check_deps() {
    section "Dependency check"
    local -a missing=()
    local -a tools=(
        git make autoconf automake pkg-config
        flex bison
        gcc g++
        i686-linux-gnu-gcc
        x86_64-w64-mingw32-gcc
        i686-w64-mingw32-gcc
        meson ninja
    )
    for t in "${tools[@]}"; do
        if command -v "$t" >/dev/null 2>&1; then
            ok "$t"
        else
            warn "MISSING: $t"
            missing+=("$t")
        fi
    done

    # glslangValidator (needed for DXVK compilation)
    if command -v glslangValidator >/dev/null 2>&1; then
        ok "glslangValidator"
    else
        warn "glslangValidator not found (needed for DXVK compilation)"
        warn "  Install: sudo apt install glslang-tools"
    fi

    # ccache (optional but strongly recommended)
    if command -v ccache >/dev/null 2>&1; then
        ok "ccache  (rebuilds will be much faster)"
    else
        warn "ccache not found — rebuilds will not be cached"
        warn "  Install: sudo apt install ccache"
    fi

    if [ "${#missing[@]}" -gt 0 ]; then
        err "Missing required tools: ${missing[*]}
     Use the Containerfile.neutron environment or install the above.
     See the README for distro-specific install commands."
    fi
    ok "All required tools present"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Disk space preflight  (warn at < 15 GB free — Neutron needs more than Wine)
# ══════════════════════════════════════════════════════════════════════════════
check_disk_space() {
    local dir="$1"
    mkdir -p "$dir"
    local avail_kb
    avail_kb=$(df --output=avail "$dir" 2>/dev/null | tail -1 || true)
    [ -n "$avail_kb" ] || return 0
    local avail_gb=$(( avail_kb / 1024 / 1024 ))
    if [ "$avail_gb" -lt 15 ]; then
        warn "Only ~${avail_gb} GB free in ${dir}"
        warn "A full Proton build (Wine + DXVK + VKD3D-Proton) needs ~20 GB."
        warn "Use --dest to point to a filesystem with more space."
        if ( : >/dev/tty ) 2>/dev/null; then
            printf "  ${C_B}Continue anyway? [y/N]:${C_R} "
            local ans
            read -r ans
            [[ "$ans" =~ ^[yY] ]] || exit 0
        else
            warn "Non-interactive — continuing anyway."
        fi
    else
        ok "Disk space: ~${avail_gb} GB free"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  Container build support
#
#  pick_build_method  — interactively ask native vs container (if not set via CLI)
#  _detect_container_engine — find podman or docker
#  _run_container_build — build image if needed, re-exec inside the container
# ══════════════════════════════════════════════════════════════════════════════
_detect_container_engine() {
    if command -v podman >/dev/null 2>&1; then
        printf 'podman'
    elif command -v docker >/dev/null 2>&1; then
        printf 'docker'
    else
        printf ''
    fi
}

pick_build_method() {
    # Already set by --container / --native flag
    [ -n "$CONTAINER_BUILD" ] && return 0
    # No interactive terminal — default to native (we may already be inside the container)
    ( : >/dev/tty ) 2>/dev/null || { CONTAINER_BUILD=false; return 0; }

    local _engine
    _engine="$(_detect_container_engine)"

    section "Build method"

    local _native_desc="Native     — build directly on this machine (requires deps)"
    local _container_desc="Container  — build inside Podman/Docker (no local deps)"
    [ -n "$_engine" ] && _container_desc="${_container_desc}  [${_engine}]"
    [ -z "$_engine" ] && _container_desc="${_container_desc}  (not available — install podman/docker)"

    if command -v fzf >/dev/null 2>&1; then
        local picked
        picked=$(
            printf 'native\t%s\n' "$_native_desc"
            printf 'container\t%s\n' "$_container_desc"
        ) && picked=$(
            printf '%s\n' "$picked" \
            | fzf \
                --prompt="Build method > " \
                --header="Select build method" \
                --with-nth=2 \
                --delimiter=$'\t' \
                --height=10% \
                --border \
            || true
        )
        [ -n "$picked" ] || { CONTAINER_BUILD=false; ok "Build method: native (default)"; return 0; }
        local _key; _key="$(printf '%s' "$picked" | cut -d$'\t' -f1)"
    else
        printf "  ${C_B}1) ${_native_desc}${C_R}\n"
        printf "  ${C_B}2) ${_container_desc}${C_R}\n\n"
        printf "  ${C_CYN}Build method [1=native, 2=container]:${C_R} "
        local _pick; read -r _pick </dev/tty
        case "$_pick" in
            2) _key="container" ;;
            *) _key="native" ;;
        esac
    fi

    case "$_key" in
        container)
            if [ -z "$_engine" ]; then
                err "No container engine found. Install podman or docker first.
     Podman (recommended): sudo apt install podman
     Docker: https://docs.docker.com/engine/install/"
            fi
            CONTAINER_BUILD=true
            ok "Build method: container (${_engine})"
            ;;
        *)
            CONTAINER_BUILD=false
            ok "Build method: native"
            ;;
    esac
}

_run_container_build() {
    local engine
    engine="$(_detect_container_engine)"
    [ -n "$engine" ] || err "No container engine found (podman or docker required)."

    local image_name="mythix-neutron_builder"
    local containerfile="${_LIB_DIR}/Containerfile.neutron"

    # If running from the source tree, Containerfile is alongside us.
    # If installed, it's in the lib dir.
    if [ ! -f "$containerfile" ]; then
        containerfile="${SCRIPT_DIR}/Containerfile.neutron"
    fi
    [ -f "$containerfile" ] || \
        err "Containerfile not found: $containerfile
     Expected in the source tree or lib directory."

    # ntsync.h must be in the build context alongside the Containerfile
    local _build_context
    _build_context="$(dirname "$containerfile")"

    # ── Build or rebuild the container image ──────────────────────────────
    # The image bakes in UID/GID/username at build time.  If it was built on
    # a different machine (or by a different user), the baked-in UID won't
    # match the current user and podman/docker will fail with "no matching
    # entries in the password file".  Detect this and auto-rebuild.
    local _need_build=false
    if ! "$engine" image exists "$image_name" 2>/dev/null; then
        _need_build=true
        msg "Image not found — will build."
    else
        # Check whether the image's baked-in UID matches ours
        local _image_uid
        _image_uid=$("$engine" run --rm "$image_name" id -u 2>/dev/null || true)
        if [ "$_image_uid" != "$(id -u)" ]; then
            warn "Image was built for UID ${_image_uid:-?} but you are UID $(id -u)"
            msg "Rebuilding image for current user..."
            "$engine" rmi -f "$image_name" >/dev/null 2>&1 || true
            _need_build=true
        else
            ok "Container image found: ${image_name}  (UID matches)"
        fi
    fi

    if [ "$_need_build" = "true" ]; then
        section "Building container image"
        msg "Building ${image_name} (this takes a few minutes)..."
        msg2 "Containerfile: $containerfile"
        msg2 "BUILD_USER=$(whoami)  BUILD_UID=$(id -u)  BUILD_GID=$(id -g)"

        run "$engine" build \
            --build-arg "BUILD_USER=$(whoami)" \
            --build-arg "BUILD_UID=$(id -u)" \
            --build-arg "BUILD_GID=$(id -g)" \
            -t "$image_name" \
            -f "$containerfile" \
            "$_build_context"

        ok "Container image built: ${image_name}"
    fi

    # ── Volume flags ─────────────────────────────────────────────────────
    # :z is needed for SELinux relabelling (harmless on non-SELinux systems)
    local vol_flag=":z"

    # ── Build the command to run inside the container ────────────────────
    # Re-invoke neutron-builder.sh with --no-container (skip the method
    # picker inside the container) plus all the user's original arguments.
    local -a inner_args=( "--no-container" )

    [ -n "$WINE_SOURCE_KEY" ]        && inner_args+=( "--source" "$WINE_SOURCE_KEY" )
    [ -n "$WINE_SOURCE_BRANCH_ARG" ] && inner_args+=( "--branch" "$WINE_SOURCE_BRANCH_ARG" )
    [ -n "$BUILD_NAME" ]             && inner_args+=( "--name" "$BUILD_NAME" )
    [ "$DXVK_SOURCE_KEY" != "dxvk" ] && inner_args+=( "--dxvk" "$DXVK_SOURCE_KEY" )
    [ "$VKD3D_SOURCE_KEY" != "vkd3d-proton" ] && inner_args+=( "--vkd3d" "$VKD3D_SOURCE_KEY" )
    [ -n "$DXVK_BRANCH_ARG" ]        && inner_args+=( "--dxvk-branch" "$DXVK_BRANCH_ARG" )
    [ -n "$VKD3D_BRANCH_ARG" ]       && inner_args+=( "--vkd3d-branch" "$VKD3D_BRANCH_ARG" )
    [ "$JOBS" != "$(nproc)" ]        && inner_args+=( "--jobs" "$JOBS" )
    [ "$SKIP_32BIT" = "true" ]       && inner_args+=( "--skip-32" )
    [ "$NO_CCACHE" = "true" ]        && inner_args+=( "--no-ccache" )
    [ "$KEEP_SYMBOLS" = "true" ]     && inner_args+=( "--keep-symbols" )
    [ "$BUILD_TYPE" != "release" ]   && inner_args+=( "--build-type" "$BUILD_TYPE" )
    [ "$NATIVE_MARCH" = "true" ]     && inner_args+=( "--native" )
    [ "$LTO" = "true" ]              && inner_args+=( "--lto" )
    [ "$RESUME" = "true" ]           && inner_args+=( "--resume" )
    [ "$NO_PULL" = "true" ]          && inner_args+=( "--no-pull" )
    [ "$DRY_RUN" -eq 1 ]            && inner_args+=( "--dry-run" )
    [ "$SNIPER_MODE" = "true" ]      && inner_args+=( "--sniper" )
    [ -n "$PATCH_GROUPS" ]           && inner_args+=( "--patches" "$PATCH_GROUPS" )

    # ── Resolve mount paths ──────────────────────────────────────────────
    # Two bind mounts:
    #   1. _LIB_DIR  → WORKDIR  (scripts: neutron-builder.sh + helpers)
    #   2. _DATA_DIR → /data    (persistent: buildz/ + src/)
    # We pass --dest and --src-dir so the build writes to /data inside the
    # container, which maps back to _DATA_DIR on the host.
    local container_home="/home/$(whoami)/mythix-neutron_builder"
    local container_data="/data"
    mkdir -p "$_DATA_DIR"

    inner_args+=( "--dest" "${container_data}/buildz" )
    inner_args+=( "--src-dir" "${container_data}/src" )

    section "Launching container build"
    # ── Engine-specific flags ────────────────────────────────────────────
    # Podman rootless needs --userns=keep-id so the host UID is mapped
    # into the container with a proper /etc/passwd entry.
    local -a engine_flags=()
    if [ "$engine" = "podman" ]; then
        engine_flags+=( "--userns=keep-id" )
    else
        # Docker: run as the current user so file ownership matches the host
        engine_flags+=( "--user" "$(id -u):$(id -g)" )
    fi

    msg2 "Engine     : ${engine}"
    msg2 "Image      : ${image_name}"
    msg2 "Scripts    : ${_LIB_DIR} → ${container_home}"
    msg2 "Config     : ${CUSTOM_CFG}"
    msg2 "Data dir   : ${_DATA_DIR} → ${container_data}"
    msg2 "Inner args : $(printf '%s ' "${inner_args[@]}")"

    # Mount _LIB_DIR as the WORKDIR (helper scripts), then overlay the main
    # script on top.  In the installed layout the main script lives in bin/
    # (as "neutron-builder", no .sh) while helpers live in lib/.  The file
    # bind mount adds it into the directory mount so both are visible.
    local _self
    _self="$(readlink -f "${BASH_SOURCE[0]}")"

    # ── Config file mount ──────────────────────────────────────────────
    # Inside the container _CFG_DIR resolves to ~/.config/mythix-build,
    # so mount the host cfg file to that same path inside the container.
    local container_cfg="/home/$(whoami)/.config/mythix-build/neutron-customization.cfg"
    local -a cfg_mount=()
    if [ -f "$CUSTOM_CFG" ]; then
        cfg_mount=( -v "${CUSTOM_CFG}:${container_cfg}:ro,${vol_flag#:}" )
        inner_args+=( "--cfg" "$container_cfg" )
    fi

    # Only allocate a TTY when stdin is a real terminal; without this,
    # running via nohup/redirection causes podman to exit silently.
    local tty_flag="-i"
    [ -t 0 ] && tty_flag="-it"

    "$engine" run --rm $tty_flag \
        "${engine_flags[@]}" \
        -v "${_LIB_DIR}:${container_home}${vol_flag}" \
        -v "${_self}:${container_home}/neutron-builder.sh:ro,${vol_flag#:}" \
        "${cfg_mount[@]}" \
        -v "${_DATA_DIR}:${container_data}${vol_flag}" \
        -v "mythix-neutron_builder-ccache:/home/$(whoami)/.ccache${vol_flag}" \
        "$image_name" \
        bash neutron-builder.sh "${inner_args[@]}"
    local _container_exit=$?

    # Fix output ownership: if we ran as root but the script dir is owned by
    # another user (e.g. ember2442), chown the data dir to match so the user
    # can copy/move the finished package without needing sudo.
    local _dir_uid _dir_gid
    _dir_uid=$(stat -c '%u' "$_LIB_DIR")
    _dir_gid=$(stat -c '%g' "$_LIB_DIR")
    if [ "$_dir_uid" != "0" ] && [ "$(id -u)" = "0" ]; then
        msg "Fixing output ownership → ${_dir_uid}:${_dir_gid}"
        chown -R "${_dir_uid}:${_dir_gid}" "$_DATA_DIR" 2>/dev/null || true
    fi

    exit "$_container_exit"
}

# ══════════════════════════════════════════════════════════════════════════════
#  fetch_source  — clone or update a git repo
#
#  Usage: fetch_source <url> <branch> <dest_dir> <shallow>
#         branch  — empty string → use default branch
#         shallow — "true" for --depth=1, "false" for full clone
# ══════════════════════════════════════════════════════════════════════════════
fetch_source() {
    local url="$1"
    local branch="$2"
    local dest="$3"
    local shallow="${4:-true}"

    # Allow git to operate on bind-mounted directories owned by a different UID
    # (common when running as root or in a container with --userns=keep-id).
    git config --global --add safe.directory '*' 2>/dev/null || true

    local depth_flag=()
    [ "$shallow" = "true" ] && depth_flag=( "--depth=1" )

    if [ ! -d "$dest/.git" ]; then
        msg "Cloning: $url"
        [ -n "$branch" ] && msg2 "Branch: $branch"
        local branch_flag=()
        [ -n "$branch" ] && branch_flag=( "--branch" "$branch" )
        run git clone \
            "${depth_flag[@]+"${depth_flag[@]}"}" \
            "${branch_flag[@]+"${branch_flag[@]}"}" \
            "$url" "$dest"
    else
        if [ "$NO_PULL" = "true" ]; then
            msg2 "--no-pull: skipping git pull in $dest"
        else
            msg "Updating: $dest"
            run git -C "$dest" fetch origin
            if [ -n "$branch" ]; then
                run git -C "$dest" checkout "$branch"
                run git -C "$dest" pull --ff-only origin "$branch" 2>/dev/null || true
            else
                run git -C "$dest" pull --ff-only 2>/dev/null || true
            fi
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  pick_wine_version  — interactive branch/version picker for proton-wine
#
#  Proton-wine uses branches (proton_9.0, proton_8.0, …) not tags.
#  Sets global _wine_branch.
# ══════════════════════════════════════════════════════════════════════════════
pick_wine_version() {
    local url="$1" key="$2"

    [ "${WINE_SOURCE_HAS_VERSIONS[$key]:-false}" = "true" ] || return 0
    [ -z "$WINE_SOURCE_BRANCH_ARG" ]                        || return 0

    # Detect whether we have an interactive terminal (fzf opens /dev/tty directly,
    # so this is more reliable than [ -t 0 ] when stdin is redirected).
    local _have_tty=false
    ( : >/dev/tty ) 2>/dev/null && _have_tty=true

    section "Version selection"
    msg2 "Fetching available versions from remote…"
    msg2 "(querying $url)"

    local ref_type="${WINE_SOURCE_VERSION_REF_TYPE[$key]:-tags}"
    local -a versions=()
    local raw_refs

    if [ "$_have_tty" = "false" ] && [ "$ref_type" = "heads" ]; then
        # No TTY, branch-based source — default branch is a valid build target
        warn "No interactive terminal — using default branch for ${key}."
        return 0
    fi

    # Temporarily disable pipefail — grep returns 1 when no lines match,
    # which would make the whole pipeline fail under pipefail even when
    # git ls-remote succeeds.  We check for empty output below instead.
    set +o pipefail

    if [ "$ref_type" = "heads" ]; then
        # Valve proton-wine: branches named proton_X.Y
        raw_refs=$(
            git ls-remote --heads --refs "$url" 2>/dev/null \
            | awk '{print $2}' \
            | sed 's|refs/heads/||' \
            | grep -E '^proton_[0-9]+\.[0-9]' \
            | sort -Vr
        ) || true
        if [ -z "$raw_refs" ]; then
            set -o pipefail
            warn "Could not fetch branch list — using default branch."
            return 0
        fi
    else
        # Tag pattern varies by source:
        #   kron4ek-tkg — bare version numbers: 9.22, 9.21 …
        #   others      — wine-X.Y prefix: wine-10.0, wine-9.22 …
        local _tag_pattern
        case "$key" in
            kron4ek-tkg) _tag_pattern='^[0-9]+\.[0-9]' ;;
            staging)     _tag_pattern='^v[0-9]+\.[0-9]' ;;
            ge-proton)   _tag_pattern='^GE-Proton[0-9]+-[0-9]+' ;;
            *)           _tag_pattern='^wine-[0-9]+\.[0-9]' ;;
        esac
        raw_refs=$(
            git ls-remote --tags --refs "$url" 2>/dev/null \
            | awk '{print $2}' \
            | sed 's|refs/tags/||' \
            | grep -E "$_tag_pattern" \
            | grep -v -- '-rc' \
            | { case "$key" in
                    # Only show 10.x+ tags — older 9.x tags lack configure.ac
                    kron4ek-tkg) awk -F. '$1 >= 10' ;;
                    *)           cat ;;
                esac; } \
            | sort -Vr
        ) || true
        if [ -z "$raw_refs" ]; then
            set -o pipefail
            warn "Could not fetch tag list — using default branch."
            return 0
        fi
    fi

    set -o pipefail

    while IFS= read -r v; do
        [ -n "$v" ] && versions+=("$v")
    done <<< "$raw_refs"

    if [ "${#versions[@]}" -eq 0 ]; then
        warn "No versions found — using default branch."
        return 0
    fi

    ok "Found ${#versions[@]} version(s) — showing newest first"

    # No interactive terminal — auto-select the latest tag.
    # Tag-based sources (kron4ek-tkg) MUST have a tag; the default branch may
    # lack configure.ac.  versions[] is sorted newest-first, so [0] is latest.
    if [ "$_have_tty" = "false" ]; then
        _wine_branch="${versions[0]}"
        ok "No interactive terminal — auto-selected latest: ${_wine_branch}"
        return 0
    fi

    local latest_label="Latest  (default — most recent commit)"

    if command -v fzf >/dev/null 2>&1; then
        local picked
        picked=$(
            { printf '%s\n' "__latest__"$'\t'"${latest_label}";
              for v in "${versions[@]}"; do
                  case "$key" in
                      kron4ek-tkg)
                          ver="$v"
                          label="Kron4ek TKG Wine ${ver}  (tag: ${v})"
                          ;;
                      mainline)
                          ver="${v#wine-}"
                          label="WineHQ ${ver}  (tag: ${v})"
                          ;;
                      staging)
                          ver="${v#v}"
                          label="Wine Staging ${ver}  (tag: ${v})"
                          ;;
                      ge-proton)
                          ver="$v"
                          label="GE-Proton ${ver}  (GloriousEggroll)"
                          ;;
                      *)
                          ver="${v#proton_}"
                          label="Valve Proton ${ver}  (branch: ${v})"
                          ;;
                  esac
                  printf '%s\n' "${v}"$'\t'"${label}"
              done; } \
            | fzf \
                --prompt="Version > " \
                --header="Select a version" \
                --with-nth=2 \
                --delimiter=$'\t' \
                --height=20% \
                --border \
            || true
        )
        [ -n "$picked" ] || { ok "Using latest (default branch)"; return 0; }
        local raw
        raw="$(printf '%s' "$picked" | cut -d$'\t' -f1)"
        if [ "$raw" = "__latest__" ]; then
            ok "Using latest (default branch)"
            return 0
        fi
        _wine_branch="$raw"
        ok "Selected: ${_wine_branch}"
        return 0
    fi

    # bash select fallback — keep raw tag values separate from display labels
    local -a menu_labels=( "$latest_label" )
    local -a menu_raws=( "__latest__" )
    for v in "${versions[@]}"; do
        case "$key" in
            kron4ek-tkg)
                ver="$v"
                label="Kron4ek TKG Wine ${ver}  (tag: ${v})"
                ;;
            mainline)
                ver="${v#wine-}"
                label="WineHQ ${ver}  (tag: ${v})"
                ;;
            staging)
                ver="${v#v}"
                label="Wine Staging ${ver}  (tag: ${v})"
                ;;
            ge-proton)
                ver="$v"
                label="GE-Proton ${ver}  (GloriousEggroll)"
                ;;
            *)
                ver="${v#proton_}"
                label="Valve Proton ${ver}  (branch: ${v})"
                ;;
        esac
        menu_labels+=( "$label" )
        menu_raws+=( "$v" )
    done
    PS3="  Version: "
    local picked_label
    select picked_label in "${menu_labels[@]}"; do
        local _idx=$(( REPLY - 1 ))
        if [ -z "$picked_label" ] || [ "${menu_raws[$_idx]:-__latest__}" = "__latest__" ]; then
            ok "Using latest (default branch)"; break
        fi
        _wine_branch="${menu_raws[$_idx]}"
        ok "Selected: ${_wine_branch}"; break
    done
    PS3=""
}

# ══════════════════════════════════════════════════════════════════════════════
#  run_autoreconf  — regenerate configure from configure.ac
# ══════════════════════════════════════════════════════════════════════════════
run_autoreconf() {
    local src="$1"
    section "autoreconf"
    msg2 "Running autoreconf in: $src"
    run autoreconf -fvi "$src"
    ok "autoreconf complete"
}

# ══════════════════════════════════════════════════════════════════════════════
#  fix_opencl_headers
#  Wine's configure looks for /usr/include/OpenCL/opencl.h (macOS layout).
#  On Linux the header lives at /usr/include/CL/cl.h — create a symlink.
# ══════════════════════════════════════════════════════════════════════════════
fix_opencl_headers() {
    local linux_h="/usr/include/CL/cl.h"
    local compat_h="/usr/include/OpenCL/opencl.h"

    if [ -f "$compat_h" ]; then
        ok "OpenCL compat header present"
        return
    fi

    if [ ! -f "$linux_h" ]; then
        warn "OpenCL headers not found — OpenCL will be disabled in this build."
        warn "Install with: sudo apt install ocl-icd-opencl-dev"
        return
    fi

    msg2 "Creating OpenCL compat symlink (macOS path expected by configure)..."
    if [ "$DRY_RUN" -eq 0 ]; then
        if ! mkdir -p /usr/include/OpenCL 2>/dev/null; then
            if command -v sudo >/dev/null 2>&1; then
                sudo mkdir -p /usr/include/OpenCL
            else
                warn "Could not create /usr/include/OpenCL — OpenCL may be disabled"
                return
            fi
        fi
        if ! ln -sf "$linux_h" "$compat_h" 2>/dev/null; then
            if command -v sudo >/dev/null 2>&1; then
                sudo ln -sf "$linux_h" "$compat_h" || \
                    { warn "Could not create $compat_h — OpenCL may be disabled"; return; }
            else
                warn "Could not create $compat_h — OpenCL may be disabled"
                return
            fi
        fi
        ok "OpenCL compat symlink created"
    else
        dim "  [dry-run] ln -sf $linux_h $compat_h"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  _kron4ek_tkg_compat_redist  <BUILD_DIR>
#
#  Applies all compatibility patches needed to run proton-tkg's  make redist
#  against a Kron4ek wine build (which lacks several Valve-only APIs) and
#  runs the build inside the umu-sdk container.
#
#  Encodes every fix discovered during the mythix Neutron 11 build session:
#    1. Wine binary stubs  (wine64 / preloaders missing in unified builds)
#    2. Valve makedep      (Kron4ek makedep segfaults on Valve source syntax)
#    3. wine_unix_to_nt_file_name stub  (lsteamclient/vrclient)
#    4. __chkstk_ms stub   (MinGW 14 stack-probe symbol not in libgcc)
#    5. wineopenxr stubs   (Valve-only VkCreateInfoWine* types)
#    6. Stamp freeze       (prevent config.status / makedep clobber loops)
#    7. Destination dirs   (pre-create so /usr/bin/install succeeds)
#    8. install-sh fix     (noexec homefs — redirect to /usr/bin/install)
#    9. gst_plugins_rs skip (needs internet to download Rust crates)
#   10. wineopenxr skip    (Valve-only Vulkan extensions, VR not needed)
#   11. Component Makefile patching  (winecrt0 path, install-sh → /usr/bin/install)
#   12. Retry loop         (up to 5 attempts; re-freezes stamps each time)
#   13. DLL rename         (vrclient.dll → vrclient_x64.dll for Proton compat)
# ══════════════════════════════════════════════════════════════════════════════
_kron4ek_tkg_compat_redist() {
    local BUILD="$1"
    local PROTON_ROOT
    PROTON_ROOT="$(dirname "$BUILD")"
    local VALVE_SRC="/tmp/mythix-valve-wine-src"
    local VALVE_BUILD="/tmp/mythix-valve-wine-build"

    section "Kron4ek TKG compat redist"
    msg2 "BUILD dir  : $BUILD"
    msg2 "PROTON root: $PROTON_ROOT"

    # ── 1. Wine binary stubs ──────────────────────────────────────────────────
    msg2 "Step 1/13: wine binary stubs"
    local DST_X64="$BUILD/dst-wine-x86_64"
    local DST_I386="$BUILD/dst-wine-i386"
    for dir in "$DST_X64/bin" "$DST_I386/bin"; do
        [ -d "$dir" ] || continue
        [ -f "$dir/wine" ] || continue
        [ -f "$dir/wine64" ]           || { cp -f "$dir/wine" "$dir/wine64";           ok "  created wine64 in $dir"; }
        [ -f "$dir/wine64-preloader" ] || { cp -f "$dir/wine" "$dir/wine64-preloader"; ok "  created wine64-preloader"; }
        [ -f "$dir/wine-preloader" ]   || { cp -f "$dir/wine" "$dir/wine-preloader";   ok "  created wine-preloader"; }
    done
    # Touch build stamps so make doesn't try to rebuild wine
    for stamp in \
        "$BUILD/.wine-x86_64-post-build" "$BUILD/.wine-i386-post-build" \
        "$BUILD/.wine-x86_64-build"      "$BUILD/.wine-i386-build"; do
        [ -f "$stamp" ] || touch "$stamp"
    done

    # ── 2. Valve makedep ─────────────────────────────────────────────────────
    msg2 "Step 2/13: Valve makedep"
    local MAKEDEP="$BUILD/obj-wine-x86_64/tools/makedep"
    mkdir -p "$(dirname "$MAKEDEP")"
    # Check if we already have a good Valve makedep
    local needs_makedep=1
    if [ -f "$VALVE_BUILD/tools/makedep" ]; then
        needs_makedep=0
    fi
    if [ "$needs_makedep" -eq 1 ]; then
        msg2 "  Cloning Valve wine source for makedep..."
        if [ ! -d "$VALVE_SRC/.git" ]; then
            git clone --depth=1 https://github.com/ValveSoftware/wine.git "$VALVE_SRC" \
                || { warn "Could not clone Valve wine — makedep may fail"; }
        fi
        if [ -d "$VALVE_SRC" ]; then
            podman run --rm \
                -v "$VALVE_SRC":"$VALVE_SRC" \
                -v "$VALVE_BUILD":"$VALVE_BUILD" \
                ghcr.io/open-wine-components/umu-sdk:latest \
                bash -c "
                    set -e
                    cd '$VALVE_SRC'
                    python3 dlls/winevulkan/make_vulkan 2>/dev/null || true
                    perl tools/make_specfiles 2>/dev/null || true
                    perl tools/make_requests 2>/dev/null || true
                    autoreconf -fiv 2>/dev/null
                    mkdir -p '$VALVE_BUILD'
                    cd '$VALVE_BUILD'
                    '$VALVE_SRC/configure' --enable-win64 2>/dev/null
                    make -j\$(nproc) tools/makedep
                " && ok "  Valve makedep built" || warn "  Valve makedep build failed — will retry without"
        fi
    fi
    if [ -f "$VALVE_BUILD/tools/makedep" ]; then
        cp "$VALVE_BUILD/tools/makedep" "$MAKEDEP"
        chmod +x "$MAKEDEP"
        ok "  Valve makedep installed"
    else
        warn "  Valve makedep not available — configure segfaults may occur"
    fi

    # ── 3–5. Patch source files ───────────────────────────────────────────────
    msg2 "Step 3-5/13: patching source files"
    python3 - "$BUILD" "$PROTON_ROOT" << 'PYEOF'
import sys, os, subprocess
BUILD, PROTON_ROOT = sys.argv[1], sys.argv[2]

unix_stub = """\n/* mythix compat: stub wine_unix_to_nt_file_name for Kron4ek wine */\n#ifndef STATUS_NOT_IMPLEMENTED\n#define STATUS_NOT_IMPLEMENTED ((NTSTATUS)0xC0000002L)\n#endif\nstatic inline NTSTATUS wine_unix_to_nt_file_name(const char *n, void *b, unsigned int *s)\n{ (void)n; (void)b; (void)s; return STATUS_NOT_IMPLEMENTED; }\n/* mythix compat end */\n"""

chkstk_stub = """\n/* mythix compat: __chkstk_ms stub for MinGW 14 */\n#if defined(__i386__) || defined(__x86_64__)\nvoid __chkstk_ms(void) {}\nvoid ___chkstk_ms(void) {}\n#endif\n/* mythix chkstk end */\n"""

openxr_stub_h = """\
/* mythix compat: stub Valve wine Vulkan extensions for Kron4ek wine */
#ifndef LOONI_WINE_VK_STUBS_H
#define LOONI_WINE_VK_STUBS_H
#ifndef VK_STRUCTURE_TYPE_CREATE_INFO_WINE_INSTANCE_CALLBACK
#define VK_STRUCTURE_TYPE_CREATE_INFO_WINE_INSTANCE_CALLBACK ((VkStructureType)1000467000)
#endif
#ifndef VK_STRUCTURE_TYPE_CREATE_INFO_WINE_DEVICE_CALLBACK
#define VK_STRUCTURE_TYPE_CREATE_INFO_WINE_DEVICE_CALLBACK   ((VkStructureType)1000467001)
#endif
typedef struct VkCreateInfoWineInstanceCallback {
    VkStructureType sType; const void *pNext;
    UINT64 native_create_callback; void *context;
} VkCreateInfoWineInstanceCallback;
typedef struct VkCreateInfoWineDeviceCallback {
    VkStructureType sType; const void *pNext;
    UINT64 native_create_callback; void *context;
} VkCreateInfoWineDeviceCallback;
static inline void __wine_set_unix_env(const char *v, const char *val)
{ (void)v; (void)val; }
#endif /* LOONI_WINE_VK_STUBS_H */
"""

def patch_prepend(path, stub, marker):
    if not os.path.exists(path): return
    lines = open(path).readlines()
    if any(marker in l for l in lines):
        print(f'  already patched: {os.path.basename(path)}'); return
    last_inc = max((i for i,l in enumerate(lines) if l.strip().startswith('#include')), default=0)
    lines.insert(last_inc + 1, stub)
    open(path, 'w').write(''.join(lines))
    print(f'  patched: {os.path.basename(path)}')

# unix_to_nt stub — lsteamclient unixlib + vrclient json_converter
for name in ['unixlib.cpp', 'json_converter.cpp']:
    r = subprocess.run(['find', PROTON_ROOT, '-name', name], capture_output=True, text=True)
    for f in r.stdout.strip().split('\n'):
        if f.strip():
            patch_prepend(f.strip(), unix_stub, 'mythix compat: stub wine_unix')

# chkstk stub — steamclient_main + vrclient_main
r = subprocess.run(['find', PROTON_ROOT, '(', '-name', 'steamclient_main.c', '-o', '-name', 'vrclient_main.c', ')'],
                   capture_output=True, text=True)
for f in r.stdout.strip().split('\n'):
    if f.strip():
        patch_prepend(f.strip(), chkstk_stub, 'mythix compat: __chkstk')

# wineopenxr stub header + include injection
r = subprocess.run(['find', PROTON_ROOT, '-name', 'openxr_loader.c'], capture_output=True, text=True)
for f in r.stdout.strip().split('\n'):
    if not f.strip(): continue
    d = os.path.dirname(f.strip())
    open(os.path.join(d, 'mythix-wine-vk-stubs.h'), 'w').write(openxr_stub_h)
    content = open(f.strip()).read()
    if 'mythix-wine-vk-stubs.h' not in content:
        open(f.strip(), 'w').write('#include "mythix-wine-vk-stubs.h"\n' + content)
        print(f'  patched: openxr_loader.c in {d}')

print('Source patching done.')
PYEOF

    # ── 6. Stamp freeze helper (called repeatedly) ────────────────────────────
    _freeze_all_stamps() {
        local B="$1"
        local V="${2:-/tmp/mythix-valve-wine-build}"
        # makedep
        [ -f "$V/tools/makedep" ] && {
            cp "$V/tools/makedep" "$B/obj-wine-x86_64/tools/makedep" 2>/dev/null || true
            chmod +x "$B/obj-wine-x86_64/tools/makedep" 2>/dev/null || true
        }
        touch -t 203001010000 \
            "$B/obj-wine-x86_64/tools/makedep" \
            "$B/.wine-x86_64-configure"  "$B/.wine-x86_64-tools" \
            "$B/.wine-x86_64-build"      "$B/.wine-x86_64-post-build" \
            "$B/.wine-i386-configure"    "$B/.wine-i386-tools" \
            "$B/.wine-i386-build"        "$B/.wine-i386-post-build" \
            "$B/.lsteamclient-x86_64-configure" "$B/.lsteamclient-i386-configure" \
            "$B/.vrclient-x86_64-configure"     "$B/.vrclient-i386-configure" \
            "$B/.wineopenxr-x86_64-configure"   "$B/.wineopenxr-x86_64-build" \
            "$B/.wineopenxr-x86_64-dist"        "$B/.wineopenxr-x86_64-post-build" \
            "$B/.steamexe-x86_64-configure"     "$B/.steamexe-i386-configure" \
            "$B/.steamexe-x86_64-build"         "$B/.steamexe-x86_64-post-build" \
            "$B/.steamexe-i386-build"            "$B/.steamexe-i386-post-build" \
            "$B/.gst_plugins_rs-i386-configure"  "$B/.gst_plugins_rs-i386-build" \
            "$B/.gst_plugins_rs-i386-dist"       "$B/.gst_plugins_rs-i386-post-build" \
            "$B/.gst_plugins_rs-x86_64-configure" "$B/.gst_plugins_rs-x86_64-build" \
            "$B/.gst_plugins_rs-x86_64-dist"     "$B/.gst_plugins_rs-x86_64-post-build" \
            2>/dev/null || true
        find "$B/obj-wine-x86_64" "$B/obj-wine-i386" \
            -name "Makefile" 2>/dev/null | xargs touch -t 203001010000 2>/dev/null || true
    }

    msg2 "Step 6/13: freezing stamps"
    _freeze_all_stamps "$BUILD" "$VALVE_BUILD"

    # ── 7. Pre-create destination directories ─────────────────────────────────
    msg2 "Step 7/13: pre-creating destination dirs"
    mkdir -p \
        "$BUILD/dst-lsteamclient-i386/lib/wine/i386-windows" \
        "$BUILD/dst-lsteamclient-i386/lib/wine/i386-unix" \
        "$BUILD/dst-lsteamclient-x86_64/lib/wine/x86_64-windows" \
        "$BUILD/dst-lsteamclient-x86_64/lib/wine/x86_64-unix" \
        "$BUILD/dst-vrclient-i386/lib/wine/i386-windows" \
        "$BUILD/dst-vrclient-i386/lib/wine/i386-unix" \
        "$BUILD/dst-vrclient-x86_64/lib/wine/x86_64-windows" \
        "$BUILD/dst-vrclient-x86_64/lib/wine/x86_64-unix" \
        "$BUILD/dst-steamexe-x86_64/lib/wine/x86_64-windows" \
        "$BUILD/dst-steamexe-i386/lib/wine/i386-windows"

    # ── 8. install-sh fix (noexec homefs) ────────────────────────────────────
    msg2 "Step 8/13: install-sh fix"
    mkdir -p "$BUILD/src-wine/tools"
    python3 -c "
import os, stat
path = '$BUILD/src-wine/tools/install-sh'
script = '#!/bin/sh\nmode=\"\" src=\"\" dst=\"\"\nwhile [ \$# -gt 0 ]; do\n  case \"\$1\" in\n    -m) mode=\"\$2\"; shift 2;;\n    -d) shift; mkdir -p \"\$1\"; shift;;\n    -*) shift;;\n    *) if [ -z \"\$src\" ]; then src=\"\$1\"; else dst=\"\$1\"; fi; shift;;\n  esac\ndone\n[ -n \"\$src\" ] && [ -n \"\$dst\" ] && cp \"\$src\" \"\$dst\"\n[ -n \"\$mode\" ] && [ -n \"\$dst\" ] && chmod \"\$mode\" \"\$dst\"\nexit 0\n'
open(path, 'w', newline='\n').write(script)
os.chmod(path, 0o755)
print('  install-sh written')
"

    # ── 9–10. Skip gst_plugins_rs and wineopenxr (done via stamps above) ─────
    msg2 "Step 9-10/13: gst_plugins_rs and wineopenxr skipped via stamps"

    # ── 11–12. Redist build with retry loop ───────────────────────────────────
    msg2 "Step 11-12/13: running make CONTAINER=1 redist (up to 5 attempts)"
    local attempt=1
    local max_attempts=5
    local exit_code=1
    local WINECRT_W64="$BUILD/dst-wine-x86_64/lib/wine/x86_64-windows"
    local WINECRT_LIB="$BUILD/dst-wine-x86_64/lib/x86_64-linux-gnu"
    local LOG_BASE="/tmp/mythix-redist"

    _patch_component_makefiles() {
        local B="$1"
        local CRT_W64="$2"
        local CRT_LIB="$3"
        for mf in \
            "$B/obj-lsteamclient-x86_64/Makefile" \
            "$B/obj-lsteamclient-i386/Makefile" \
            "$B/obj-vrclient-x86_64/Makefile" \
            "$B/obj-vrclient-i386/Makefile" \
            "$B/obj-steamexe-x86_64/Makefile" \
            "$B/obj-steamexe-i386/Makefile"; do
            [ -f "$mf" ] || continue
            sed -i \
                "s|[^ ]*/src-wine/tools/install-sh[^ ]*|/usr/bin/install|g;
                 s|-lwinecrt0|-L${CRT_W64} -L${CRT_LIB} -lwinecrt0|g" \
                "$mf" 2>/dev/null || true
            touch -t 203001010000 "$mf" 2>/dev/null || true
        done
    }

    while [ "$attempt" -le "$max_attempts" ] && [ "$exit_code" -ne 0 ]; do
        msg2 "  redist attempt $attempt/$max_attempts..."
        _freeze_all_stamps "$BUILD" "$VALVE_BUILD"
        _patch_component_makefiles "$BUILD" "$WINECRT_W64" "$WINECRT_LIB"

        podman run --rm \
            -v "$BUILD":"$BUILD" \
            -v "$(dirname "$BUILD")":"$(dirname "$BUILD")" \
            -w "$BUILD" -e MAKEFLAGS \
            ghcr.io/open-wine-components/umu-sdk:latest \
            make -j"$(nproc)" CONTAINER=1 redist \
            > "${LOG_BASE}-${attempt}.log" 2>&1
        exit_code=$?

        if [ "$exit_code" -eq 0 ]; then
            ok "  redist succeeded on attempt $attempt"
        else
            warn "  attempt $attempt failed (exit $exit_code) — see ${LOG_BASE}-${attempt}.log"
            grep -E "error:|Error [0-9]|undefined ref|not found|No such" \
                "${LOG_BASE}-${attempt}.log" 2>/dev/null | tail -5 >&2 || true
            attempt=$((attempt + 1))
            # Touch any new stamps the failed run created
            find "$BUILD" -name ".*-build" -newer "$BUILD/.wine-x86_64-build" \
                2>/dev/null | xargs touch -t 203001010000 2>/dev/null || true
        fi
    done

    if [ "$exit_code" -ne 0 ]; then
        warn "redist failed after $max_attempts attempts"
        warn "Last log: ${LOG_BASE}-$((attempt-1)).log"
        return 1
    fi

    # ── 13. DLL rename (vrclient.dll → vrclient_x64.dll) ─────────────────────
    msg2 "Step 13/13: renaming vrclient.dll → vrclient_x64.dll"
    local VRCLIENT_W64="$BUILD/dst-vrclient-x86_64/lib/wine/x86_64-windows"
    local VRCLIENT_UNIX="$BUILD/dst-vrclient-x86_64/lib/wine/x86_64-unix"
    if [ -f "$VRCLIENT_W64/vrclient.dll" ] && [ ! -f "$VRCLIENT_W64/vrclient_x64.dll" ]; then
        cp "$VRCLIENT_W64/vrclient.dll" "$VRCLIENT_W64/vrclient_x64.dll"
        ok "  vrclient.dll → vrclient_x64.dll"
    fi
    if [ -f "$VRCLIENT_UNIX/vrclient.so" ] && [ ! -f "$VRCLIENT_UNIX/vrclient_x64.so" ]; then
        cp "$VRCLIENT_UNIX/vrclient.so" "$VRCLIENT_UNIX/vrclient_x64.so" 2>/dev/null || true
    fi

    ok "Kron4ek TKG compat redist complete"
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  _kron4ek_tkg_install_redist_to_proton  <BUILD_DIR> <PROTON_PKG_DIR>
#
#  Copies the redist output (lsteamclient, vrclient, steamexe) from the
#  proton-tkg build tree into the assembled Neutron package.
# ══════════════════════════════════════════════════════════════════════════════
_kron4ek_tkg_install_redist_to_proton() {
    local BUILD="$1"
    local PKG="$2"

    section "Installing TKG redist into Neutron package"

    local WINE_LIB="$PKG/files/lib/wine"
    mkdir -p \
        "$WINE_LIB/x86_64-windows" "$WINE_LIB/x86_64-unix" \
        "$WINE_LIB/i386-windows"   "$WINE_LIB/i386-unix"

    local copied=0
    for src_dir in \
        "$BUILD/dst-lsteamclient-x86_64/lib/wine/x86_64-windows" \
        "$BUILD/dst-vrclient-x86_64/lib/wine/x86_64-windows" \
        "$BUILD/dst-steamexe-x86_64/lib/wine/x86_64-windows"; do
        [ -d "$src_dir" ] || continue
        find "$src_dir" -name "*.dll" | while read -r f; do
            cp -f "$f" "$WINE_LIB/x86_64-windows/" && copied=$((copied+1))
        done
    done
    for src_dir in \
        "$BUILD/dst-lsteamclient-x86_64/lib/wine/x86_64-unix" \
        "$BUILD/dst-vrclient-x86_64/lib/wine/x86_64-unix"; do
        [ -d "$src_dir" ] || continue
        find "$src_dir" -name "*.so" | while read -r f; do
            cp -f "$f" "$WINE_LIB/x86_64-unix/" 2>/dev/null || true
        done
    done
    for src_dir in \
        "$BUILD/dst-lsteamclient-i386/lib/wine/i386-windows" \
        "$BUILD/dst-vrclient-i386/lib/wine/i386-windows"; do
        [ -d "$src_dir" ] || continue
        find "$src_dir" -name "*.dll" | while read -r f; do
            cp -f "$f" "$WINE_LIB/i386-windows/" && copied=$((copied+1))
        done
    done

    # Ensure vrclient_x64.dll name exists
    [ -f "$WINE_LIB/x86_64-windows/vrclient.dll" ] && \
    [ ! -f "$WINE_LIB/x86_64-windows/vrclient_x64.dll" ] && \
        cp "$WINE_LIB/x86_64-windows/vrclient.dll" \
           "$WINE_LIB/x86_64-windows/vrclient_x64.dll" && \
        ok "  vrclient.dll → vrclient_x64.dll"

    ok "Redist DLLs installed into Neutron package"
}

# ══════════════════════════════════════════════════════════════════════════════
#  pregen_headers
#  Pre-generate headers that makedep needs before configure/autoreconf runs.
#  Must be called on the source tree BEFORE run_autoreconf.
#
#  Generates three files using scripts bundled in the source tree:
#    include/wine/vulkan.h      — from dlls/winevulkan/make_vulkan  (Python)
#    dlls/ntdll/ntsyscalls.h    — from tools/make_specfiles          (Perl)
#    include/wine/server_protocol.h — from tools/make_requests       (Perl)
# ══════════════════════════════════════════════════════════════════════════════
pregen_headers() {
    local src="$1"
    section "Pre-generating headers"

    # ── wine/vulkan.h ─────────────────────────────────────────────────────────
    local vulkan_out="${src}/include/wine/vulkan.h"
    local vulkan_script="${src}/dlls/winevulkan/make_vulkan"
    if [ ! -f "$vulkan_out" ]; then
        msg2 "Generating wine/vulkan.h ..."
        if [ -f "$vulkan_script" ]; then
            if [ "$DRY_RUN" -eq 0 ]; then
                ( cd "$src" && python3 dlls/winevulkan/make_vulkan ) \
                    || err "make_vulkan failed.
     The script needs python3 and the Vulkan registry XML.
     Inside the container these should both be present.
     Check: python3 --version  and  ls ${src}/dlls/winevulkan/"
                ok "wine/vulkan.h generated"
            else
                dim "  [dry-run] python3 dlls/winevulkan/make_vulkan"
            fi
        else
            warn "make_vulkan not found at ${vulkan_script}"
            warn "wine/vulkan.h will be missing — configure will likely fail."
        fi
    else
        ok "wine/vulkan.h  (already present)"
    fi

    # ── ntsyscalls.h  (Wine 10.x+, not present in all trees) ─────────────────
    local ntsys_out="${src}/dlls/ntdll/ntsyscalls.h"
    local specfiles="${src}/tools/make_specfiles"
    if [ ! -f "$ntsys_out" ] && [ -f "$specfiles" ]; then
        msg2 "Generating ntsyscalls.h ..."
        if [ "$DRY_RUN" -eq 0 ]; then
            ( cd "$src" && perl tools/make_specfiles ) \
                || err "make_specfiles failed. Install: sudo apt install perl"
            ok "ntsyscalls.h generated"
        else
            dim "  [dry-run] perl tools/make_specfiles"
        fi
    else
        ok "ntsyscalls.h  (present or not required by this tree)"
    fi

    # ── server_protocol.h ─────────────────────────────────────────────────────
    local proto_out="${src}/include/wine/server_protocol.h"
    local make_req="${src}/tools/make_requests"
    if [ -f "$make_req" ]; then
        if [ ! -f "$proto_out" ] || [ "$make_req" -nt "$proto_out" ]; then
            msg2 "Generating server_protocol.h ..."
            if [ "$DRY_RUN" -eq 0 ]; then
                ( cd "$src" && perl tools/make_requests ) \
                    || err "make_requests failed. Install: sudo apt install perl"
                ok "server_protocol.h generated"
            else
                dim "  [dry-run] perl tools/make_requests"
            fi
        else
            ok "server_protocol.h  (up to date)"
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  _install_logged  — run make install with a magenta/cyan progress bar
#
#  Tracks lines matching "tools/install" to count files being installed.
#  Falls back to plain output in non-interactive or --verbose mode.
# ══════════════════════════════════════════════════════════════════════════════
_install_logged() {
    # $@ = make -C <dir> install args

    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        run make "$@" install; return
    fi

    # Count total install operations via dry-run
    local _total=0
    if [ -t 1 ] && [ "${VERBOSE_BUILD:-false}" != "true" ]; then
        printf "${C_DIM}  Counting install steps...${C_R}"
        _total=$(
            make "$@" install -n 2>/dev/null \
            | grep -c 'tools/install' || true
        )
        printf "\r\033[K"
        [ "$_total" -eq 0 ] && _total=1
    fi

    if [ -t 1 ] && [ "${VERBOSE_BUILD:-false}" != "true" ]; then
        local _cur=0 _start _make_exit
        _start=$(date +%s)

        # Print 2 reserved lines for the install HUD
        printf "\n\n"

        _draw_install() {
            local cur="$1" tot="$2" phase="$3" start="$4"
            [ "$tot" -eq 0 ] && tot=1
            local w=50 f pct bar="" i=0
            f=$(( cur * w / tot )); pct=$(( cur * 100 / tot ))
            while [ "$i" -lt "$f" ]; do bar="${bar}█"; i=$(( i+1 )); done
            while [ "$i" -lt "$w" ]; do bar="${bar}░"; i=$(( i+1 )); done
            local now e estr="0s"
            now=$(date +%s); e=$(( now - start ))
            if   [ "$e" -ge 3600 ]; then estr="$(( e/3600 ))h$(( (e%3600)/60 ))m$(( e%60 ))s"
            elif [ "$e" -ge 60   ]; then estr="$(( e/60 ))m$(( e%60 ))s"
            else                         estr="${e}s"; fi
            printf "\033[2A\033[K${C_MAG}  [%s] %3d%%${C_R}  ${C_DIM}(%d / %d)${C_R}\n" \
                "$bar" "$pct" "$cur" "$tot"
            printf "\033[K  ${C_CYN}elapsed${C_R} %-10s  ${C_CYN}installing${C_R} %s\n" \
                "$estr" "$phase"
        }

        _draw_install 0 "$_total" "starting..." "$_start"

        set +e
        make "$@" install 2>&1 | while IFS= read -r _line; do
            printf '%s\n' "$_line" >> "${BUILD_LOG:-/dev/null}"
            if printf '%s' "$_line" | grep -q 'tools/install'; then
                _cur=$(( _cur + 1 ))
                local _dest
                _dest=$(printf '%s' "$_line" | grep -oE '[^ ]+$' | tail -1)
                _dest="${_dest##*/}"
                _draw_install "$_cur" "$_total" "$_dest" "$_start"
            fi
        done
        _make_exit=${PIPESTATUS[0]}
        set -e

        _draw_install "$_total" "$_total" "complete ✓" "$_start"
        printf "\n"

        return "$_make_exit"
    else
        make "$@" install 2>&1 | tee -a "${BUILD_LOG:-/dev/null}"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  install_wine  — make install the built Wine into the files/ directory
# ══════════════════════════════════════════════════════════════════════════════
install_wine() {
    local build_run_dir="$1"
    local install_prefix="$2"

    section "Installing Wine"
    mkdir -p "$install_prefix"

    local build64="${build_run_dir}/wine64"
    local build32="${build_run_dir}/wine32"

    if [ -d "$build64" ]; then
        msg2 "make install  (64-bit)"
        _install_logged -C "$build64"
        ok "64-bit Wine installed"
    fi

    if [ "${SKIP_32BIT}" != "true" ] && [ -d "$build32" ]; then
        msg2 "make install  (32-bit)"
        _install_logged -C "$build32"
        ok "32-bit Wine installed"
    fi

    ok "Wine installed to: $install_prefix"
}

# ══════════════════════════════════════════════════════════════════════════════
#  _write_build_manifest  — record this build in buildz/builds.log
# ══════════════════════════════════════════════════════════════════════════════
_write_build_manifest() {
    local install_prefix="$1"
    local elapsed_fmt="$2"
    local manifest="${DEST_ROOT}/builds.log"
    mkdir -p "${DEST_ROOT}"
    {
        printf '%-25s  source=%-30s  elapsed=%s  date=%s\n' \
            "$(basename "$install_prefix")" \
            "${WINE_SOURCE_KEY}" \
            "$elapsed_fmt" \
            "$(date '+%Y-%m-%d %H:%M:%S')"
    } >> "$manifest"
}

# ══════════════════════════════════════════════════════════════════════════════
#  print_summary
# ══════════════════════════════════════════════════════════════════════════════
print_summary() {
    local install_prefix="$1"
    local elapsed_fmt="$2"

    section "Build Summary"
    ok "Build complete in ${elapsed_fmt}"
    printf "\n"
    printf "  ${C_B}Neutron name :${C_R} %s\n" "$(basename "$install_prefix")"
    printf "  ${C_B}Install path :${C_R} %s\n" "$install_prefix"

    local wine_bin="${install_prefix}/files/bin/wine"
    if [ -x "$wine_bin" ]; then
        local wine_ver
        wine_ver="$("$wine_bin" --version 2>/dev/null || printf 'unknown')"
        printf "  ${C_B}Wine version :${C_R} %s\n" "$wine_ver"
    fi

    # Component status — check actual DLL presence, not just source key
    printf "\n  ${C_B}Component status:${C_R}\n"
    if [ "$WINE_SOURCE_KEY" = "ge-proton" ]; then
        printf "    ${C_GRN}✓${C_R}  GE-Proton     — proton-wine + GloriousEggroll patches\n"
    else
        printf "    ${C_GRN}✓${C_R}  proton-wine   — built and installed\n"
    fi
    if [ "${DXVK_SOURCE_KEY}" = "none" ]; then
        printf "    ${C_DIM}-${C_R}  DXVK          — skipped (--dxvk none)\n"
    elif [ -n "$(find "${install_prefix}/files/lib64/wine/dxvk" -name '*.dll' 2>/dev/null | head -1)" ]; then
        printf "    ${C_GRN}✓${C_R}  DXVK          — installed (${DXVK_SOURCE_KEY})\n"
    else
        printf "    ${C_YLW}◌${C_R}  DXVK          — will compile from source\n"
    fi
    if [ "${VKD3D_SOURCE_KEY}" = "none" ]; then
        printf "    ${C_DIM}-${C_R}  VKD3D-Proton  — skipped (--vkd3d none)\n"
    elif [ -n "$(find "${install_prefix}/files/lib64/wine/vkd3d-proton" -name '*.dll' 2>/dev/null | head -1)" ]; then
        printf "    ${C_GRN}✓${C_R}  VKD3D-Proton  — installed (${VKD3D_SOURCE_KEY})\n"
    else
        printf "    ${C_YLW}◌${C_R}  VKD3D-Proton  — will compile from source\n"
    fi
    if [ "${SNIPER_MODE}" = "true" ]; then
        printf "    ${C_GRN}✓${C_R}  Sniper mode   — Steam Runtime 3.0 container isolation enabled\n"
    else
        printf "    ${C_DIM}-${C_R}  Sniper mode   — disabled (standard host mode)\n"
    fi
    if [ -f "${BUILD_RUN_DIR:-/dev/null}/neutron-patch.log" ]; then
        local _pcount
        _pcount="$(grep -c '✓' "${BUILD_RUN_DIR}/neutron-patch.log" 2>/dev/null || echo 0)"
        printf "    ${C_GRN}✓${C_R}  Patches       — ${_pcount} patches applied\n"
    elif [ -n "${PATCH_GROUPS:-}" ] && [ "$PATCH_GROUPS" != "none" ]; then
        printf "    ${C_GRN}✓${C_R}  Patches       — groups: ${PATCH_GROUPS}\n"
    fi

    printf "\n  ${C_B}To use with Steam:${C_R}\n"
    printf "    cp -r %s\n" "$install_prefix"
    printf "       ~/.steam/steam/compatibilitytools.d/\n"
    printf "    Then restart Steam and enable in game Properties → Compatibility.\n"
    printf "\n"
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

# ── Early dispatch: --kron4ek-redist standalone mode ─────────────────────────
if [ -n "${_KRON4EK_REDIST_BUILD:-}" ]; then
    [ -d "$_KRON4EK_REDIST_BUILD" ] || \
        err "BUILD dir not found: $_KRON4EK_REDIST_BUILD"
    _kron4ek_tkg_compat_redist "$_KRON4EK_REDIST_BUILD"
    if [ -n "${_KRON4EK_REDIST_PKG:-}" ] && [ -d "$_KRON4EK_REDIST_PKG" ]; then
        _kron4ek_tkg_install_redist_to_proton "$_KRON4EK_REDIST_BUILD" \
            "$_KRON4EK_REDIST_PKG"
    fi
    exit 0
fi

# Validate wine source key if provided
if [ -n "$WINE_SOURCE_KEY" ]; then
    if [ -z "${WINE_SOURCE_URL[$WINE_SOURCE_KEY]+x}" ]; then
        err "Unknown --source: '${WINE_SOURCE_KEY}'
     Valid options: ${WINE_SOURCE_KEYS[*]}"
    fi
else
    # Interactive source picker
    if [ -t 0 ]; then
        pick_source
    else
        err "--source is required in non-interactive mode.
     Use: --source proton-wine  or  --source proton-wine-experimental"
    fi
fi

# Validate DXVK key
if [ -z "${DXVK_SOURCE_URL[$DXVK_SOURCE_KEY]+x}" ]; then
    err "Unknown --dxvk: '${DXVK_SOURCE_KEY}'
 Valid options: dxvk | dxvk-async | none"
fi

# Validate VKD3D key
if [ -z "${VKD3D_SOURCE_URL[$VKD3D_SOURCE_KEY]+x}" ]; then
    err "Unknown --vkd3d: '${VKD3D_SOURCE_KEY}'
 Valid options: vkd3d-proton | none"
fi

# ── Steam Runtime Sniper mode ─────────────────────────────────────────────────
# If not set via --sniper, ask interactively
if [ "$SNIPER_MODE" = "false" ] && [ -t 0 ]; then
    _sniper_items=(
        $'no\tStandard mode — runs on host (broader compatibility)'
        $'yes\tSniper mode — runs inside Steam Runtime 3.0 container (SteamOS-like isolation)'
    )
    if command -v fzf >/dev/null 2>&1; then
        _sniper_choice="$(printf '%s\n' "${_sniper_items[@]}" \
            | fzf --prompt="Steam Runtime Sniper mode? " \
                  --header="Enable Steam Runtime container isolation?" \
                  --height=12% --reverse --delimiter=$'\t' --with-nth=2 \
            | cut -f1)" || true
    else
        printf "\n  ${C_B}Steam Runtime Sniper mode?${C_R}\n"
        printf "    1) Standard mode — runs on host (broader compatibility)\n"
        printf "    2) Sniper mode — Steam Runtime 3.0 container isolation\n"
        read -rp "  Choice [1-2, default=1]: " _sniper_choice
        case "$_sniper_choice" in
            2) _sniper_choice="yes" ;;
            *) _sniper_choice="no"  ;;
        esac
    fi
    [ "$_sniper_choice" = "yes" ] && SNIPER_MODE=true
fi
msg2 "Sniper mode: ${SNIPER_MODE}"

# ── Build method (native vs container) ────────────────────────────────────────
pick_build_method

# If container build was chosen, hand off to the container now.
# _run_container_build execs into the container — this script does not continue.
if [ "$CONTAINER_BUILD" = "true" ]; then
    _run_container_build
    # exec replaces this process — if we reach here, something went wrong
    err "Container build failed to launch."
fi

# ── Dependency check (native builds only) ─────────────────────────────────────
check_deps

# ── Build name ────────────────────────────────────────────────────────────────
pick_build_name

# ══════════════════════════════════════════════════════════════════════════════
#  pick_build_options  — interactive wizard for build tuning
#
#  Opens with a single yes/no: "change build options?"
#  Answering N (or Enter) skips all questions and keeps defaults — no more
#  answering 6 questions just to accept everything.
#  Skipped entirely when --jobs / --no-ccache / etc. were given on the CLI,
#  or in non-interactive mode.
# ══════════════════════════════════════════════════════════════════════════════
pick_build_options() {
    # Skip when running as the inner container invocation — host already handled options.
    [ "$CONTAINER_BUILD" = "false" ] && return 0
    ( : >/dev/tty ) 2>/dev/null || return 0

    # If any tuning flag was set explicitly on the CLI, skip the wizard —
    # the user already knows what they want.
    if [ "$NO_CCACHE" = "true" ] || [ "$KEEP_SYMBOLS" = "true" ] || \
       [ "$BUILD_TYPE" != "release" ] || [ "$NATIVE_MARCH" = "true" ] || \
       [ "$LTO" = "true" ]; then
        return 0
    fi

    local _cpu_count; _cpu_count=$(nproc)

    section "Build options"
    printf "  Current defaults:  jobs=${C_B}${JOBS}${C_R}  32-bit=${C_B}$([ "$SKIP_32BIT" = true ] && echo skip || echo yes)${C_R}"
    printf "  build=${C_B}release${C_R}  ccache=${C_B}$(command -v ccache >/dev/null 2>&1 && echo on || echo n/a)${C_R}  symbols=${C_B}stripped${C_R}  native=${C_B}no${C_R}  lto=${C_B}no${C_R}\n\n"
    printf "  ${C_CYN}Change build options?${C_R}  [y/N]: "
    local _change; read -r _change </dev/tty
    case "$_change" in
        [yY]*) ;;
        *) ok "Using defaults"; return 0 ;;
    esac
    printf "\n"

    # Jobs
    printf "  ${C_CYN}Jobs${C_R} (parallel compile threads)\n"
    printf "  Your CPU has ${C_B}${_cpu_count}${C_R} threads.\n"
    printf "  ${C_DIM}Suggestions: all=${_cpu_count}  leave-one-free=$(( _cpu_count - 1 ))  half=$(( _cpu_count / 2 ))${C_R}\n"
    printf "  Jobs [default: ${_cpu_count}]: "
    local _j; read -r _j </dev/tty
    if [ -n "$_j" ] && [ "$_j" -gt 0 ] 2>/dev/null; then
        JOBS="$_j"; ok "Jobs: ${JOBS}"
    else
        JOBS="$_cpu_count"; ok "Jobs: ${JOBS}  (default)"
    fi
    printf "\n"

    # 32-bit
    printf "  ${C_CYN}32-bit build${C_R}  Needed for 32-bit games.\n"
    printf "  Skip 32-bit? [y/N]: "
    local _s32; read -r _s32 </dev/tty
    case "$_s32" in
        [yY]*) SKIP_32BIT=true;  ok "32-bit: skipped" ;;
        *)     SKIP_32BIT=false; ok "32-bit: enabled" ;;
    esac
    printf "\n"

    # Build type
    printf "  ${C_CYN}Build type${C_R}\n"
    printf "    ${C_B}release${C_R}         — optimised, stripped  ${C_DIM}(default)${C_R}\n"
    printf "    ${C_B}debugoptimized${C_R}  — optimised + debug symbols\n"
    printf "    ${C_B}debug${C_R}           — no optimisation, full symbols\n"
    printf "  Build type [release]: "
    local _bt; read -r _bt </dev/tty
    case "$_bt" in
        debug|debugoptimized) BUILD_TYPE="$_bt"; ok "Build type: ${BUILD_TYPE}" ;;
        *) BUILD_TYPE="release"; ok "Build type: release  (default)" ;;
    esac
    printf "\n"

    # ccache
    if command -v ccache >/dev/null 2>&1; then
        printf "  ${C_CYN}ccache${C_R}  Disable ccache? [y/N]: "
        local _cc; read -r _cc </dev/tty
        case "$_cc" in
            [yY]*) NO_CCACHE=true;  ok "ccache: disabled" ;;
            *)     NO_CCACHE=false; ok "ccache: enabled" ;;
        esac
        printf "\n"
    fi

    # Symbols
    printf "  ${C_CYN}Debug symbols${C_R}  Keep symbols? (larger binaries)  [y/N]: "
    local _ks; read -r _ks </dev/tty
    case "$_ks" in
        [yY]*) KEEP_SYMBOLS=true;  ok "Symbols: kept" ;;
        *)     KEEP_SYMBOLS=false; ok "Symbols: stripped  (default)" ;;
    esac
    printf "\n"

    # -march=native
    printf "  ${C_CYN}-march=native${C_R}  Optimise for this CPU only? (non-portable)  [y/N]: "
    local _nm; read -r _nm </dev/tty
    case "$_nm" in
        [yY]*) NATIVE_MARCH=true;  ok "-march=native: enabled" ;;
        *)     NATIVE_MARCH=false; ok "-march=native: disabled  (default)" ;;
    esac
    printf "\n"

    # LTO
    printf "  ${C_CYN}LTO${C_R}  Link-time optimisation? (slow link, smaller binary)  [y/N]: "
    local _lto; read -r _lto </dev/tty
    case "$_lto" in
        [yY]*) LTO=true;  ok "LTO: enabled" ;;
        *)     LTO=false; ok "LTO: disabled  (default)" ;;
    esac
    printf "\n"

    ok "Build options set:"
    msg2 "Jobs=${JOBS}  32bit=$([ "$SKIP_32BIT" = true ] && echo skip || echo yes)  type=${BUILD_TYPE}  ccache=$([ "$NO_CCACHE" = true ] && echo off || echo on)  symbols=$([ "$KEEP_SYMBOLS" = true ] && echo keep || echo strip)  native=${NATIVE_MARCH}  lto=${LTO}"
}

# ── Build options wizard ──────────────────────────────────────────────────────
pick_build_options

# ── Export toggles for build-core and packager ────────────────────────────────
export JOBS NO_CCACHE KEEP_SYMBOLS BUILD_TYPE NATIVE_MARCH LTO SKIP_32BIT

# ── Disk space preflight ──────────────────────────────────────────────────────
section "System preflight"
check_disk_space "$DEST_ROOT"

# ── Resolve build directories ─────────────────────────────────────────────────
# BUILD_NAME is either from --name, pick_build_name, or the source key default.
# The Wine version number is appended to the final package dir after the build.
if [ -z "$BUILD_NAME" ]; then
    case "$WINE_SOURCE_KEY" in
        ge-proton) BUILD_NAME="mythix-ge-neutron" ;;
        *)         BUILD_NAME="mythix-neutron" ;;
    esac
fi
WINE_SOURCE_DIR="${SRC_ROOT}/${WINE_SOURCE_KEY}"
BUILD_RUN_DIR="${DEST_ROOT}/build-run/${BUILD_NAME}"
# Neutron's Wine installs to <package>/files/ — not the package root
NEUTRON_PACKAGE_DIR="${DEST_ROOT}/install/${BUILD_NAME}"
WINE_INSTALL_PREFIX="${NEUTRON_PACKAGE_DIR}/files"
BUILD_LOG="${BUILD_RUN_DIR}/build.log"

msg2 "Wine source dir  : ${WINE_SOURCE_DIR}"
msg2 "Build run dir    : ${BUILD_RUN_DIR}"
msg2 "Neutron package  : ${NEUTRON_PACKAGE_DIR}"
msg2 "Wine prefix      : ${WINE_INSTALL_PREFIX}"

mkdir -p "$DEST_ROOT" "$SRC_ROOT" "$BUILD_RUN_DIR" "$WINE_INSTALL_PREFIX"

# ── Determine wine branch ─────────────────────────────────────────────────────
_wine_branch="${WINE_SOURCE_BRANCH[$WINE_SOURCE_KEY]}"
[ -n "$WINE_SOURCE_BRANCH_ARG" ] && _wine_branch="$WINE_SOURCE_BRANCH_ARG"

# Interactive version picker
# Special case: staging queries the wine-staging repo for version tags (v10.4 etc.)
# rather than mainline WineHQ, then we clone mainline at the matching tag.
if [ "$WINE_SOURCE_KEY" = "staging" ]; then
    _staging_query_url="https://github.com/wine-staging/wine-staging.git"
    pick_wine_version "$_staging_query_url" "$WINE_SOURCE_KEY"
    # _wine_branch is now e.g. "v10.4" — convert to mainline tag "wine-10.4"
    if [ -n "$_wine_branch" ]; then
        export STAGING_BRANCH="$_wine_branch"
        _wine_branch="wine-${_wine_branch#v}"
        msg2 "Staging tag ${STAGING_BRANCH} → cloning mainline at ${_wine_branch}"
    fi
elif [ "$WINE_SOURCE_KEY" = "ge-proton" ]; then
    # GE-Proton: pick a GE release tag, then resolve the proton-wine branch it targets
    pick_wine_version "$GE_PROTON_REPO" "$WINE_SOURCE_KEY"
    # _wine_branch is now e.g. "GE-Proton9-20" — save it and resolve proton-wine branch
    if [ -n "$_wine_branch" ]; then
        GE_RELEASE_TAG="$_wine_branch"
        # GE-ProtonX-Y targets proton_X.0 branch (e.g. GE-Proton9-20 → proton_9.0)
        _ge_major="${GE_RELEASE_TAG#GE-Proton}"
        _ge_major="${_ge_major%%-*}"
        _wine_branch="proton_${_ge_major}.0"
        msg2 "GE release ${GE_RELEASE_TAG} → proton-wine branch ${_wine_branch}"
    else
        # No version picked — use latest GE release, default to proton_9.0
        GE_RELEASE_TAG=""
        _wine_branch="proton_9.0"
        msg2 "Using default proton-wine branch: ${_wine_branch}"
    fi
    export GE_RELEASE_TAG
else
    pick_wine_version "${WINE_SOURCE_URL[$WINE_SOURCE_KEY]}" "$WINE_SOURCE_KEY"
fi
# _wine_branch may have been updated by pick_wine_version

# ── Fetch Wine source ────────────────────────────────────────────────────────
section "Fetching Wine source"

# Clone strategy: Valve's fork needs full history for git describe;
# WineHQ sources can use shallow clones for speed.
case "$WINE_SOURCE_KEY" in
    proton-wine|proton-wine-experimental|ge-proton)
        msg2 "Full clone — required for Valve version strings (git describe)"
        _shallow="false"
        ;;
    *)
        _shallow="true"
        ;;
esac

fetch_source \
    "${WINE_SOURCE_URL[$WINE_SOURCE_KEY]}" \
    "$_wine_branch" \
    "$WINE_SOURCE_DIR" \
    "$_shallow"

[ -d "$WINE_SOURCE_DIR" ] || \
    err "Wine source directory not found after fetch: $WINE_SOURCE_DIR"

[ -f "${WINE_SOURCE_DIR}/configure.ac" ] || \
    err "configure.ac not found in: $WINE_SOURCE_DIR
     This does not look like a Wine source tree."

# ── GE-Proton patch application ──────────────────────────────────────────────
# When source is ge-proton, clone the GE repo and run protonprep.sh to apply
# all of GloriousEggroll's gaming patches on top of proton-wine.
if [ "$WINE_SOURCE_KEY" = "ge-proton" ]; then
    section "GE-Proton patches (GloriousEggroll)"

    GE_CACHE_DIR="${SRC_ROOT}/proton-ge-custom"
    _ge_branch_flag=()
    [ -n "${GE_RELEASE_TAG:-}" ] && _ge_branch_flag=( "--branch" "$GE_RELEASE_TAG" )

    if [ ! -d "${GE_CACHE_DIR}/.git" ]; then
        msg "Cloning proton-ge-custom…"
        [ -n "${GE_RELEASE_TAG:-}" ] && msg2 "Release: ${GE_RELEASE_TAG}"
        run git clone --depth=1 \
            "${_ge_branch_flag[@]+"${_ge_branch_flag[@]}"}" \
            "$GE_PROTON_REPO" "$GE_CACHE_DIR"
    else
        msg "Updating proton-ge-custom…"
        if [ -n "${GE_RELEASE_TAG:-}" ]; then
            run git -C "$GE_CACHE_DIR" fetch --depth=1 origin "refs/tags/${GE_RELEASE_TAG}:refs/tags/${GE_RELEASE_TAG}" 2>/dev/null || \
                run git -C "$GE_CACHE_DIR" fetch origin
            run git -C "$GE_CACHE_DIR" checkout "$GE_RELEASE_TAG"
        else
            run git -C "$GE_CACHE_DIR" pull --ff-only 2>/dev/null || true
        fi
    fi

    ok "GE source ready: ${GE_CACHE_DIR}"

    # ── Apply GE patches via protonprep.sh ──────────────────────────────
    # protonprep.sh expects to be run from the GE repo root with the wine
    # source tree as a subdirectory or sibling.  We adapt to work with our
    # layout: symlink our wine source as "wine" in the GE tree, then run
    # protonprep.sh from within it.
    _ge_patches_dir="${GE_CACHE_DIR}/patches"

    # Find the protonprep script — GE names it differently across releases
    _ge_prep=""
    for _candidate in \
        "${_ge_patches_dir}/protonprep-valve-staging.sh" \
        "${_ge_patches_dir}/protonprep.sh" \
        "${_ge_patches_dir}/protonprep-nofshack.sh"; do
        [ -f "$_candidate" ] && { _ge_prep="$_candidate"; break; }
    done

    if [ -n "$_ge_prep" ]; then
        msg "Applying GE patches via $(basename "$_ge_prep")…"
        msg2 "This applies GE's full gaming patch set on top of proton-wine"

        # protonprep does 'pushd wine' — create a symlink so it finds our tree
        _ge_wine_link="${GE_CACHE_DIR}/wine"
        rm -rf "$_ge_wine_link"
        ln -sf "$WINE_SOURCE_DIR" "$_ge_wine_link"

        # Clone wine-staging — protonprep applies staging patches with exclusions
        _ge_staging_link="${GE_CACHE_DIR}/wine-staging"
        rm -rf "$_ge_staging_link"
        _ge_staging_dir="${SRC_ROOT}/wine-staging-ge"
        if [ ! -d "${_ge_staging_dir}/.git" ]; then
            msg2 "Cloning wine-staging for GE patch application…"
            run git clone --depth=1 \
                "https://github.com/wine-staging/wine-staging.git" \
                "$_ge_staging_dir"
        fi
        ln -sf "$_ge_staging_dir" "$_ge_staging_link"

        # Create dummy dirs for components we don't use (protonprep resets them)
        for _dummy in dxvk vkd3d-proton dxvk-nvapi; do
            _dummy_dir="${GE_CACHE_DIR}/${_dummy}"
            if [ ! -d "$_dummy_dir" ]; then
                mkdir -p "$_dummy_dir"
                ( cd "$_dummy_dir" && git init -q && git commit --allow-empty -m "dummy" -q ) 2>/dev/null || true
            fi
        done

        _ge_patch_log="${BUILD_RUN_DIR}/ge-protonprep.log"
        msg2 "Script: $(basename "$_ge_prep")"
        msg2 "Log: ${_ge_patch_log}"

        if [ "${DRY_RUN:-0}" -eq 1 ]; then
            dim "  [dry-run] Would run $(basename "$_ge_prep")"
        else
            set +e
            ( cd "$GE_CACHE_DIR" && bash "$_ge_prep" ) \
                > "$_ge_patch_log" 2>&1
            _ge_exit=$?
            set -e

            if [ "$_ge_exit" -eq 0 ]; then
                ok "GE-Proton patches applied successfully"
            else
                warn "$(basename "$_ge_prep") exited with code ${_ge_exit}"
                warn "Some GE patches may have failed — check: ${_ge_patch_log}"
                msg2 "Continuing build (partial patches are usually fine)…"
            fi

            # Show summary of what was applied
            if [ -f "$_ge_patch_log" ]; then
                _ge_applied=$(grep -c 'patching file\|WINE:' "$_ge_patch_log" 2>/dev/null || echo 0)
                _ge_fails=$(grep -ciE 'FAILED|error|can.t find file' "$_ge_patch_log" 2>/dev/null || echo 0)
                msg2 "Patch log: ~${_ge_applied} operations, ${_ge_fails} potential issues"
            fi
        fi

        # ── Post-patch fixups for known GE/proton-wine incompatibilities ──
        # GE's ntsync patch adds close_inproc_sync_obj() call but the function
        # doesn't exist in all proton-wine branches. Replace with NtClose().
        _thread_c="${WINE_SOURCE_DIR}/dlls/ntdll/unix/thread.c"
        if [ -f "$_thread_c" ] && grep -q 'close_inproc_sync_obj' "$_thread_c"; then
            sed -i 's/close_inproc_sync_obj( wait_handle );/NtClose( wait_handle );/' "$_thread_c"
            ok "Post-patch fixup: close_inproc_sync_obj → NtClose"
        fi

        # Clean up symlinks (leave dummy dirs, they're harmless)
        rm -rf "$_ge_wine_link"
        rm -rf "$_ge_staging_link"
    elif [ -d "$_ge_patches_dir" ]; then
        # No protonprep.sh — try applying .patch files directly
        msg "No protonprep.sh found — applying GE .patch files directly"
        _ge_patch_count=0
        _ge_patch_fail=0
        for _pf in "${_ge_patches_dir}"/**/*.patch "${_ge_patches_dir}"/*.patch; do
            [ -f "$_pf" ] || continue
            _pname="$(basename "$_pf")"
            if (cd "$WINE_SOURCE_DIR" && git apply --check "$_pf" 2>/dev/null); then
                (cd "$WINE_SOURCE_DIR" && git apply "$_pf" 2>/dev/null) && \
                    { printf "  ${C_GRN}✓${C_R}  %s\n" "$_pname"; (( _ge_patch_count++ )) || true; } || \
                    { printf "  ${C_RED}✗${C_R}  %s\n" "$_pname"; (( _ge_patch_fail++ )) || true; }
            elif (cd "$WINE_SOURCE_DIR" && patch -p1 --dry-run < "$_pf" >/dev/null 2>&1); then
                (cd "$WINE_SOURCE_DIR" && patch -p1 < "$_pf" >/dev/null 2>&1) && \
                    { printf "  ${C_GRN}✓${C_R}  %s\n" "$_pname"; (( _ge_patch_count++ )) || true; } || \
                    { printf "  ${C_RED}✗${C_R}  %s\n" "$_pname"; (( _ge_patch_fail++ )) || true; }
            else
                printf "  ${C_YLW}⊘${C_R}  %s (skipped)\n" "$_pname"
            fi
        done
        ok "GE patches: ${_ge_patch_count} applied, ${_ge_patch_fail} failed"
    else
        warn "No patches directory found in proton-ge-custom"
        warn "GE patches could not be applied — building plain proton-wine"
    fi
fi

# ── Apply neutron patch groups ────────────────────────────────────────────────
if [ -x "$PATCHER" ] && [ -d "$PATCHES_DIR" ]; then
    section "Neutron patch system"
    export WINE_SOURCE_KEY PATCH_LOG="${BUILD_RUN_DIR}/neutron-patch.log" DRY_RUN
    mkdir -p "$BUILD_RUN_DIR"

    _patch_args=()
    if [ -n "$PATCH_GROUPS" ]; then
        # Convert comma-separated to space-separated args
        IFS=',' read -ra _pg_list <<< "$PATCH_GROUPS"
        _patch_args=("${_pg_list[@]}")
    fi

    "$PATCHER" "$WINE_SOURCE_DIR" "$PATCHES_DIR" "${_patch_args[@]}" || {
        warn "Some patches may have failed — check ${BUILD_RUN_DIR}/neutron-patch.log"
    }
elif [ -d "$PATCHES_DIR" ] && [ ! -x "$PATCHER" ]; then
    warn "neutron-patcher.sh not found or not executable: $PATCHER"
    warn "Skipping patch application"
fi

# ── Apply wine-staging patches (staging source only) ─────────────────────────
if [ "${WINE_SOURCE_NEEDS_STAGING[$WINE_SOURCE_KEY]:-false}" = "true" ]; then
    section "Applying wine-staging patches"

    # Locate the patcher script — check neutron's own copy first, then wine-builder's
    _PATCHER=""
    for _p in "${_LIB_DIR}/wine-tkg-patcher.sh" \
              "${SCRIPT_DIR}/wine-tkg-patcher.sh" \
              "${SCRIPT_DIR}/../mythix-wine_builder/wine-tkg-patcher.sh" \
              "${SCRIPT_DIR%/bin}/../mythix-wine_builder/wine-tkg-patcher.sh"; do
        [ -f "$_p" ] && { _PATCHER="$_p"; break; }
    done

    if [ -z "$_PATCHER" ]; then
        # Inline fallback: clone wine-staging and apply via patchinstall.py
        msg2 "wine-tkg-patcher.sh not found — applying staging patches inline"
        _STAGING_CACHE="${SRC_ROOT}/wine-staging-patches"
        _STAGING_URL="https://github.com/wine-staging/wine-staging.git"
        _staging_ref="${STAGING_BRANCH:-}"

        if [ -d "${_STAGING_CACHE}/.git" ]; then
            msg2 "Updating staging cache..."
            git -C "$_STAGING_CACHE" fetch --prune
            [ -n "$_staging_ref" ] && git -C "$_STAGING_CACHE" checkout "$_staging_ref" --
        else
            msg2 "Cloning wine-staging → $_STAGING_CACHE"
            mkdir -p "$(dirname "$_STAGING_CACHE")"
            if [ -n "$_staging_ref" ]; then
                git clone --depth=1 --branch "$_staging_ref" "$_STAGING_URL" "$_STAGING_CACHE"
            else
                git clone --depth=1 "$_STAGING_URL" "$_STAGING_CACHE"
            fi
        fi

        _PATCHINSTALL="${_STAGING_CACHE}/staging/patchinstall.py"
        if [ -f "$_PATCHINSTALL" ]; then
            msg2 "Applying full staging patchset via patchinstall.py..."
            _patch_log="${BUILD_RUN_DIR}/staging-patch.log"
            (
                cd "$_STAGING_CACHE"
                python3 staging/patchinstall.py \
                    --all \
                    DESTDIR="$WINE_SOURCE_DIR" \
                    >> "$_patch_log" 2>&1
            ) || {
                warn "Staging patch application had errors — see ${_patch_log}"
                tail -10 "$_patch_log" >&2
            }
            ok "wine-staging patches applied"
        else
            warn "patchinstall.py not found in staging cache — skipping patches"
        fi
    else
        # Use the shared patcher from wine-builder
        msg2 "Using patcher: $_PATCHER"
        [ -x "$_PATCHER" ] || chmod +x "$_PATCHER"
        export DRY_RUN NO_PULL
        export PATCH_LOG="${BUILD_RUN_DIR}/staging-patch.log"
        export STAGING_BRANCH_HINT="${_wine_branch:-}"
        mkdir -p "$BUILD_RUN_DIR"
        "$_PATCHER" "$WINE_SOURCE_DIR" "${SRC_ROOT}/wine-staging-patches"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  _download_dxvk_release  — install pre-built DXVK DLLs from GitHub releases
#  _download_vkd3d_release — install pre-built VKD3D-Proton DLLs from GitHub releases
#
#  Usage: _download_dxvk_release  <dest_64> <dest_32>
#         _download_vkd3d_release <dest_64> <dest_32>
# ══════════════════════════════════════════════════════════════════════════════
_download_dxvk_release() {
    local dest_64="$1" dest_32="$2"

    msg "Fetching latest DXVK release info from GitHub..."
    local release_json
    release_json=$(curl -fsSL \
        "https://api.github.com/repos/doitsujin/dxvk/releases/latest") \
        || err "Failed to fetch DXVK release info from GitHub API"

    local version tarball_url
    version=$(printf '%s' "$release_json" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")
    tarball_url=$(printf '%s' "$release_json" \
        | python3 -c "
import sys, json
rel = json.load(sys.stdin)
url = next((a['browser_download_url'] for a in rel['assets']
            if a['name'].endswith('.tar.gz')), None)
if not url: raise SystemExit('No .tar.gz asset in DXVK release')
print(url)")
    msg2 "DXVK version : ${version}"
    msg2 "Downloading  : ${tarball_url}"

    local tmpdir
    tmpdir=$(mktemp -d)
    curl -fsSL "$tarball_url" | tar -xz -C "$tmpdir" \
        || err "Failed to download/extract DXVK tarball"

    mkdir -p "$dest_64" "$dest_32"
    local c64=0 c32=0
    while IFS= read -r f; do cp "$f" "$dest_64/"; c64=$(( c64+1 )); done \
        < <(find "$tmpdir" -path '*/x64/*.dll' 2>/dev/null | sort)
    while IFS= read -r f; do cp "$f" "$dest_32/"; c32=$(( c32+1 )); done \
        < <(find "$tmpdir" -path '*/x32/*.dll' 2>/dev/null | sort)
    rm -rf "$tmpdir"

    [ "$c64" -gt 0 ] || err "No x64 DLLs found in DXVK release tarball"
    ok "DXVK ${version} installed: ${c64} x64 DLLs, ${c32} x32 DLLs"
}

_download_vkd3d_release() {
    local dest_64="$1" dest_32="$2"

    msg "Fetching latest VKD3D-Proton release info from GitHub..."
    local release_json
    release_json=$(curl -fsSL \
        "https://api.github.com/repos/HansKristian-Work/vkd3d-proton/releases/latest") \
        || err "Failed to fetch VKD3D-Proton release info from GitHub API"

    local version tarball_url
    version=$(printf '%s' "$release_json" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")
    tarball_url=$(printf '%s' "$release_json" \
        | python3 -c "
import sys, json
rel = json.load(sys.stdin)
url = next((a['browser_download_url'] for a in rel['assets']
            if a['name'].endswith('.tar.zst')), None)
if not url: raise SystemExit('No .tar.zst asset in VKD3D-Proton release')
print(url)")
    msg2 "VKD3D-Proton version : ${version}"
    msg2 "Downloading          : ${tarball_url}"

    local tmpdir
    tmpdir=$(mktemp -d)
    curl -fsSL "$tarball_url" | tar -I zstd -x -C "$tmpdir" \
        || err "Failed to download/extract VKD3D-Proton tarball"

    mkdir -p "$dest_64" "$dest_32"
    local c64=0 c32=0
    while IFS= read -r f; do cp "$f" "$dest_64/"; c64=$(( c64+1 )); done \
        < <(find "$tmpdir" -path '*/x64/*.dll' 2>/dev/null | sort)
    while IFS= read -r f; do cp "$f" "$dest_32/"; c32=$(( c32+1 )); done \
        < <(find "$tmpdir" \( -path '*/x86/*.dll' -o -path '*/x32/*.dll' \) 2>/dev/null | sort)
    rm -rf "$tmpdir"

    [ "$c64" -gt 0 ] || err "No x64 DLLs found in VKD3D-Proton release tarball"
    ok "VKD3D-Proton ${version} installed: ${c64} x64 DLLs, ${c32} x86 DLLs"
}

# ── Fetch DXVK ────────────────────────────────────────────────────────────────
if [ "${DXVK_SOURCE_KEY}" != "none" ] && [ "${DXVK_SOURCE_KEY}" != "dxvk-release" ]; then
    section "DXVK source  "
    DXVK_SOURCE_DIR="${SRC_ROOT}/dxvk-${DXVK_SOURCE_KEY}"
    _dxvk_branch="${DXVK_BRANCH_ARG:-}"
    msg2 "Source key : ${DXVK_SOURCE_KEY}"
    msg2 "Source dir : ${DXVK_SOURCE_DIR}"
    msg2 "URL        : ${DXVK_SOURCE_URL[$DXVK_SOURCE_KEY]}"
    fetch_source \
        "${DXVK_SOURCE_URL[$DXVK_SOURCE_KEY]}" \
        "$_dxvk_branch" \
        "$DXVK_SOURCE_DIR" \
        "true"
    ok "DXVK source fetched"
    export DXVK_SOURCE_DIR DXVK_SOURCE_KEY
fi

# ── Fetch VKD3D-Proton ────────────────────────────────────────────────────────
if [ "${VKD3D_SOURCE_KEY}" != "none" ] && [ "${VKD3D_SOURCE_KEY}" != "vkd3d-proton-release" ]; then
    section "VKD3D-Proton source  "
    VKD3D_SOURCE_DIR="${SRC_ROOT}/vkd3d-proton"
    _vkd3d_branch="${VKD3D_BRANCH_ARG:-}"
    msg2 "Source key : ${VKD3D_SOURCE_KEY}"
    msg2 "Source dir : ${VKD3D_SOURCE_DIR}"
    msg2 "URL        : ${VKD3D_SOURCE_URL[$VKD3D_SOURCE_KEY]}"
    fetch_source \
        "${VKD3D_SOURCE_URL[$VKD3D_SOURCE_KEY]}" \
        "$_vkd3d_branch" \
        "$VKD3D_SOURCE_DIR" \
        "true"
    ok "VKD3D-Proton source fetched"
    export VKD3D_SOURCE_DIR VKD3D_SOURCE_KEY
fi

# ── Start build timer ─────────────────────────────────────────────────────────
_BUILD_START=$(date +%s)

# ══════════════════════════════════════════════════════════════════════════════
#  COMPILE + INSTALL  — proton-wine  (skipped with --dxvk-only / --vkd3d-only)
# ══════════════════════════════════════════════════════════════════════════════
if [ "$SKIP_WINE_BUILD" = "true" ]; then
    section "Skipping Wine build (--dxvk-only / --vkd3d-only)"
    # Verify a prior Wine install actually exists before proceeding
    [ -f "${WINE_INSTALL_PREFIX}/bin/wine" ] || \
        err "No prior Wine install found at: ${WINE_INSTALL_PREFIX}/bin/wine
     Run a full build first before using --dxvk-only / --vkd3d-only."
    ok "Using existing Wine install at: ${WINE_INSTALL_PREFIX}"
else
    # ── Pre-build fixes and header generation ──────────────────────────────
    section "Pre-build headers"
    fix_opencl_headers
    pregen_headers "$WINE_SOURCE_DIR"

    # ── autoreconf ──────────────────────────────────────────────────────────
    if [ "$RESUME" = "true" ] && [ -f "${BUILD_RUN_DIR}/wine64/Makefile" ]; then
        msg2 "--resume: skipping autoreconf"
    else
        run_autoreconf "$WINE_SOURCE_DIR"
    fi

    # ── Validate build scripts ──────────────────────────────────────────────
    [ -f "$BUILD_CORE" ] || \
        err "Build core script not found: $BUILD_CORE
     Expected alongside neutron-builder.sh as neutron-build-core.sh"
    [ -x "$BUILD_CORE" ] || chmod +x "$BUILD_CORE"

    [ -f "$PACKAGER" ] || \
        err "Packager script not found: $PACKAGER
     Expected alongside neutron-builder.sh as neutron-package.sh"
    [ -x "$PACKAGER" ] || chmod +x "$PACKAGER"

    # ── Load configuration ──────────────────────────────────────────────────
    # Fallback: if the cfg isn't in _CFG_DIR, check alongside the script
    if [ ! -f "$CUSTOM_CFG" ] && [ -f "${_LIB_DIR}/neutron-customization.cfg" ]; then
        CUSTOM_CFG="${_LIB_DIR}/neutron-customization.cfg"
        msg2 "Config found alongside script: $CUSTOM_CFG"
    fi
    [ -f "$CUSTOM_CFG" ] || \
        err "Configuration file not found: $CUSTOM_CFG
     Copy and edit neutron-customization.cfg — see the README for details.
     (HOME=$HOME, _CFG_DIR=$_CFG_DIR, _LIB_DIR=$_LIB_DIR)"
    # shellcheck source=/dev/null
    source "$CUSTOM_CFG"

    # ── Export env to build-core ────────────────────────────────────────────
    export WINE_SOURCE="$WINE_SOURCE_DIR"
    export PREFIX="$WINE_INSTALL_PREFIX"
    export WINE_BUILD="${BUILD_NAME//-/_}"
    export NEUTRON_SOURCE_KEY="$WINE_SOURCE_KEY"
    export JOBS
    export SKIP_32BIT
    export BUILD_RUN_DIR
    export CUSTOM_CFG
    export RESUME
    export BUILD_LOG

    # ── Compile ─────────────────────────────────────────────────────────────
    section "Compiling proton-wine"
    msg "Handing off to: $BUILD_CORE"
    mkdir -p "$BUILD_RUN_DIR"
    cd "$DEST_ROOT"
    "$BUILD_CORE"

    # ── Install ─────────────────────────────────────────────────────────────
    install_wine "$BUILD_RUN_DIR" "$WINE_INSTALL_PREFIX"

fi

# ══════════════════════════════════════════════════════════════════════════════
#  Build DXVK
#
#  Calls neutron-dxvk-build.sh to cross-compile DXVK with Meson + MinGW.
#  Output .dll files are placed under:
#    ${NEUTRON_PACKAGE_DIR}/files/lib/wine/dxvk/   (32-bit)
#    ${NEUTRON_PACKAGE_DIR}/files/lib64/wine/dxvk/  (64-bit)
# ══════════════════════════════════════════════════════════════════════════════
section "DXVK build  "
if [ "${SKIP_DXVK:-false}" = "true" ]; then
    msg2 "Skipping DXVK (--vkd3d-only)"
elif [ "${REINSTALL_COMPONENTS:-false}" = "true" ]; then
    section "DXVK reinstall from existing build"
    _dxvk_build_64="${SRC_ROOT}/dxvk-${DXVK_SOURCE_KEY}/build/x64"
    _dxvk_build_32="${SRC_ROOT}/dxvk-${DXVK_SOURCE_KEY}/build/x32"
    _dxvk_dest_64="${WINE_INSTALL_PREFIX}/lib64/wine/dxvk"
    _dxvk_dest_32="${WINE_INSTALL_PREFIX}/lib/wine/dxvk"
    if [ ! -d "$_dxvk_build_64" ]; then
        warn "DXVK 64-bit build dir not found: $_dxvk_build_64"
        warn "Run --dxvk-only first to build DXVK"
    else
        mkdir -p "$_dxvk_dest_64" "$_dxvk_dest_32"
        find "$_dxvk_build_64" -name '*.dll' -exec cp {} "$_dxvk_dest_64/" \;
        _n=$(find "$_dxvk_dest_64" -name '*.dll' | wc -l)
        ok "DXVK 64-bit: ${_n} DLLs installed"
        if [ -d "$_dxvk_build_32" ]; then
            find "$_dxvk_build_32" -name '*.dll' -exec cp {} "$_dxvk_dest_32/" \;
            _n=$(find "$_dxvk_dest_32" -name '*.dll' | wc -l)
            ok "DXVK 32-bit: ${_n} DLLs installed"
        fi
    fi
elif [ "${DXVK_SOURCE_KEY}" = "dxvk-release" ]; then
    section "DXVK  — downloading pre-built release"
    _download_dxvk_release \
        "${WINE_INSTALL_PREFIX}/lib64/wine/dxvk" \
        "${WINE_INSTALL_PREFIX}/lib/wine/dxvk"
elif [ "${DXVK_SOURCE_KEY}" != "none" ]; then
    if [ -x "$DXVK_BUILDER" ]; then
        export NEUTRON_PACKAGE_DIR
        "$DXVK_BUILDER"
    else
        warn "neutron-dxvk-build.sh not found or not executable: $DXVK_BUILDER"
        warn "D3D9/D3D10/D3D11 games will fall back to WineD3D (slower)"
        warn "Try: --dxvk dxvk-release  to download pre-built DLLs instead"
    fi
else
    msg2 "DXVK skipped (--dxvk none)"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Build VKD3D-Proton
#
#  It compiles VKD3D-Proton with Meson + MinGW and places d3d12.dll under:
#    ${NEUTRON_PACKAGE_DIR}/files/lib/wine/vkd3d-proton/   (32-bit)
#    ${NEUTRON_PACKAGE_DIR}/files/lib64/wine/vkd3d-proton/  (64-bit)
# ══════════════════════════════════════════════════════════════════════════════
section "VKD3D-Proton build  "
if [ "${REINSTALL_COMPONENTS:-false}" = "true" ]; then
    section "VKD3D-Proton reinstall from existing build"
    _vkd3d_build_64="${SRC_ROOT}/vkd3d-proton/build/x64"
    _vkd3d_build_32="${SRC_ROOT}/vkd3d-proton/build/x32"
    _vkd3d_dest_64="${WINE_INSTALL_PREFIX}/lib64/wine/vkd3d-proton"
    _vkd3d_dest_32="${WINE_INSTALL_PREFIX}/lib/wine/vkd3d-proton"
    if [ ! -d "$_vkd3d_build_64" ]; then
        warn "VKD3D-Proton 64-bit build dir not found: $_vkd3d_build_64"
        warn "Run --vkd3d-only first to build VKD3D-Proton"
    else
        mkdir -p "$_vkd3d_dest_64" "$_vkd3d_dest_32"
        find "$_vkd3d_build_64" -name '*.dll' -exec cp {} "$_vkd3d_dest_64/" \;
        _n=$(find "$_vkd3d_dest_64" -name '*.dll' | wc -l)
        ok "VKD3D-Proton 64-bit: ${_n} DLLs installed"
        if [ -d "$_vkd3d_build_32" ]; then
            find "$_vkd3d_build_32" -name '*.dll' -exec cp {} "$_vkd3d_dest_32/" \;
            _n=$(find "$_vkd3d_dest_32" -name '*.dll' | wc -l)
            ok "VKD3D-Proton 32-bit: ${_n} DLLs installed"
        fi
    fi
elif [ "${VKD3D_SOURCE_KEY}" = "vkd3d-proton-release" ]; then
    section "VKD3D-Proton  — downloading pre-built release"
    _download_vkd3d_release \
        "${WINE_INSTALL_PREFIX}/lib64/wine/vkd3d-proton" \
        "${WINE_INSTALL_PREFIX}/lib/wine/vkd3d-proton"
elif [ "${VKD3D_SOURCE_KEY}" != "none" ]; then
    if [ -x "$VKD3D_BUILDER" ]; then
        export NEUTRON_PACKAGE_DIR
        "$VKD3D_BUILDER"
    else
        warn "neutron-vkd3d-build.sh not found or not executable: $VKD3D_BUILDER"
        warn "DirectX 12 games will not work without VKD3D-Proton"
        warn "Try: --vkd3d vkd3d-proton-release  to download pre-built DLLs instead"
    fi
else
    msg2 "VKD3D-Proton skipped (--vkd3d none)"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  PACKAGE  — generate Steam Neutron layout
# ══════════════════════════════════════════════════════════════════════════════
section "Packaging Neutron"
export NEUTRON_PACKAGE_DIR WINE_INSTALL_PREFIX
export DXVK_SOURCE_KEY VKD3D_SOURCE_KEY
export BUILD_NAME SNIPER_MODE
"$PACKAGER"

# ══════════════════════════════════════════════════════════════════════════════
#  Version rename  — append actual wine version string to the package dir
#  Final name: <BUILD_NAME>-<version>  e.g. mythix-neutron-11.4.r0.gabcdef
# ══════════════════════════════════════════════════════════════════════════════
_wine_bin="${WINE_INSTALL_PREFIX}/bin/wine"
if [ -x "$_wine_bin" ]; then
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
