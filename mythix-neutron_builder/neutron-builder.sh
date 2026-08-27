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
    C_CYN="\033[1;35m" C_MAG="\033[1;36m"
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
    [mythix-wine]="https://github.com/ValveSoftware/wine.git"
)
declare -A WINE_SOURCE_BRANCH=(
    [mainline]=""              # version picker selects the tag (wine-X.Y)
    [experimental]="master"   # WineHQ bleeding edge
    [staging]=""               # version picker queries wine-staging tags; clone at matching mainline tag
    [proton-wine]=""              # version picker selects the branch (proton_X.Y)
    [proton-wine-experimental]="bleeding-edge"
    [ge-proton]=""                # set by GE release picker → matching proton_X.Y branch
    [kron4ek-tkg]=""              # default branch tracks latest Wine + staging + TKG + ntsync
    [mythix-wine]=""              # set by MYTHIX_WINE_BASE (default: proton_10.0)
)
declare -A WINE_SOURCE_DESC=(
    [mainline]="WineHQ mainline       — official stable releases (version picker)"
    [experimental]="WineHQ experimental   — bleeding-edge master branch"
    [staging]="WineHQ + Staging      — mainline + community patches (version picker)"
    [proton-wine]="Valve proton-wine     — stable branches (version picker)"
    [proton-wine-experimental]="Valve proton-wine exp  — bleeding-edge (no version picker)"
    [ge-proton]="GE-Proton (GloriousEggroll) — proton-wine + GE gaming patches (version picker)"
    [kron4ek-tkg]="Kron4ek wine-tkg      — Wine source tree with Staging + TKG + ntsync patches"
    [mythix-wine]="Mythix Wine           — Valve proton-wine + TkG + Staging + GE (the works)"
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
# Kron4ek wine-tkg repo URL (used by mythix-wine to fetch TkG patches)
KRON4EK_TKG_REPO="https://github.com/Kron4ek/wine-tkg.git"
WINE_SOURCE_KEYS=( mainline experimental staging proton-wine proton-wine-experimental ge-proton kron4ek-tkg mythix-wine )

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

DXVK_SOURCE_KEY="dxvk-release"         # default: download pre-built from GitHub
DXVK_BRANCH_ARG=""
VKD3D_SOURCE_KEY="vkd3d-proton-release" # default: download pre-built from GitHub
VKD3D_BRANCH_ARG=""

BUILD_NAME=""
MYTHIX_WINE_BASE="${MYTHIX_WINE_BASE:-proton_10.0}"  # proton_10.0 | bleeding-edge
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
                        proton-wine | proton-wine-experimental | kron4ek-tkg |
                        mythix-wine
  --branch BRANCH       Pin to a specific branch or tag (e.g. proton_9.0, wine-10.6)
                        Skips the interactive version picker when provided.
  --wine-base BASE      Mythix Wine base branch: proton_10.0 (default) | bleeding-edge
                        proton_10.0 = Wine 10.0 + fsync (stable, wide compat)
                        bleeding-edge = latest experimental (ntsync, newest features)
  --no-pull             Skip git pull on an existing source tree

${C_B}Component selection:${C_R}
  --dxvk NAME           DXVK variant: dxvk-release (default) | dxvk | dxvk-async | none
                        dxvk-release downloads pre-built DLLs from GitHub (fastest)
                        dxvk / dxvk-async compile from source (requires MinGW)
  --vkd3d NAME          VKD3D variant: vkd3d-proton-release (default) | vkd3d-proton | none
                        vkd3d-proton-release downloads pre-built DLLs from GitHub (fastest)
                        vkd3d-proton compiles from source (requires MinGW)
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
  Pre-built DLLs are downloaded from GitHub by default (fastest).
  Use --dxvk dxvk / --vkd3d vkd3d-proton to compile from source instead
  (requires MinGW cross-compiler + meson/ninja).
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
        --wine-base)    MYTHIX_WINE_BASE="$2";   shift 2 ;;
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
        --dxvk-only)    SKIP_WINE_BUILD=true; DXVK_SOURCE_KEY="${DXVK_SOURCE_KEY:-dxvk-release}"; shift ;;
        --vkd3d-only)   SKIP_WINE_BUILD=true; SKIP_DXVK=true; VKD3D_SOURCE_KEY="${VKD3D_SOURCE_KEY:-vkd3d-proton-release}"; shift ;;
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
#  Disk space preflight  (warn at < 6 GB free)
# ══════════════════════════════════════════════════════════════════════════════
check_disk_space() {
    local dir="$1"
    mkdir -p "$dir"
    local avail_kb
    avail_kb=$(df --output=avail "$dir" 2>/dev/null | tail -1 || true)
    [ -n "$avail_kb" ] || return 0
    local avail_gb=$(( avail_kb / 1024 / 1024 ))
    if [ "$avail_gb" -lt 6 ]; then
        warn "Only ~${avail_gb} GB free in ${dir}"
        warn "A full Neutron build (Wine + DXVK + VKD3D-Proton + container) needs ~5-6 GB."
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
    [ "$MYTHIX_WINE_BASE" != "proton_10.0" ] && inner_args+=( "--wine-base" "$MYTHIX_WINE_BASE" )
    [ "$DXVK_SOURCE_KEY" != "dxvk-release" ] && inner_args+=( "--dxvk" "$DXVK_SOURCE_KEY" )
    [ "$VKD3D_SOURCE_KEY" != "vkd3d-proton-release" ] && inner_args+=( "--vkd3d" "$VKD3D_SOURCE_KEY" )
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
        local proto_def="${src}/server/protocol.def"
        if [ ! -f "$proto_out" ] || [ "$make_req" -nt "$proto_out" ] || [ "$proto_def" -nt "$proto_out" ]; then
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
    elif [ -n "$(find "${install_prefix}/files/lib/wine/dxvk" -name '*.dll' 2>/dev/null | head -1)" ]; then
        printf "    ${C_GRN}✓${C_R}  DXVK          — installed (${DXVK_SOURCE_KEY})\n"
    else
        printf "    ${C_YLW}◌${C_R}  DXVK          — will compile from source\n"
    fi
    if [ "${VKD3D_SOURCE_KEY}" = "none" ]; then
        printf "    ${C_DIM}-${C_R}  VKD3D-Proton  — skipped (--vkd3d none)\n"
    elif [ -n "$(find "${install_prefix}/files/lib/wine/vkd3d-proton" -name '*.dll' 2>/dev/null | head -1)" ]; then
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
# If not set via --sniper, ask interactively (skip inside container re-exec)
if [ "$SNIPER_MODE" = "false" ] && [ -t 0 ] && [ "$CONTAINER_BUILD" != "false" ]; then
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
        ge-proton)   BUILD_NAME="mythix-ge-neutron" ;;
        mythix-wine) BUILD_NAME="mythix-neutron" ;;
        *)           BUILD_NAME="mythix-neutron" ;;
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

# mythix-wine: resolve branch from MYTHIX_WINE_BASE if not set via --branch
if [ "$WINE_SOURCE_KEY" = "mythix-wine" ] && [ -z "$_wine_branch" ]; then
    _wine_branch="$MYTHIX_WINE_BASE"
    msg "Mythix Wine base: ${MYTHIX_WINE_BASE}"
fi

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
    proton-wine|proton-wine-experimental|ge-proton|mythix-wine)
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

# ── Mythix Wine: Valve proton-wine + TkG + Staging + GE ─────────────────────
# Layer 1 (base): Valve proton-wine branch (proton_10.0 or bleeding-edge)
# Layer 2: TkG patches — extracted by diffing Kron4ek wine-tkg against vanilla Wine
# Layer 3: Wine-Staging patches
# Layer 4: GE-Proton gaming patches
# Layer 5: Our own Mythix custom patches
if [ "$WINE_SOURCE_KEY" = "mythix-wine" ]; then

    # ── Wine base selection ──────────────────────────────────────────────
    # MYTHIX_WINE_BASE controls which Valve branch we build from:
    #   proton_10.0   — Valve's stable Wine 10.0 fork (fsync, wide compat)
    #   bleeding-edge — Valve's latest experimental (ntsync, newest features)
    case "$MYTHIX_WINE_BASE" in
        proton_10.0)
            _mythix_base_branch="proton_10.0"
            _mythix_base_label="Valve proton_10.0 (Wine 10.0, fsync)"
            _tkg_pin_commit="e022fa13cf0"  # "Add 10.17 with esync/fsync"
            _tkg_pin_label="10.17 (esync/fsync)"
            ;;
        bleeding-edge|bleeding_edge)
            _mythix_base_branch="bleeding-edge"
            _mythix_base_label="Valve bleeding-edge (latest experimental)"
            _tkg_pin_commit=""  # use latest
            _tkg_pin_label="latest"
            ;;
        *)
            die "Unknown MYTHIX_WINE_BASE: ${MYTHIX_WINE_BASE} (use proton_10.0 or bleeding-edge)"
            ;;
    esac

    section "Mythix Wine — ${_mythix_base_label} + TkG + Staging + GE"
    msg "Base: ${_mythix_base_label}"
    msg "TkG pin: ${_tkg_pin_label}"

    # Pin to a known-good commit on the selected branch (empty = use latest)
    BLEEDING_EDGE_PIN=""

    BLEEDING_EDGE_REVERTS=()
    BLEEDING_EDGE_CHERRIES=()

    # Fetch the target branch if not already available
    (cd "$WINE_SOURCE_DIR" && git fetch origin "$_mythix_base_branch" 2>/dev/null) || true

    # Hard reset to clean base before applying patches
    if [[ -n "$BLEEDING_EDGE_PIN" ]]; then
        msg "Resetting source tree to pinned commit: ${BLEEDING_EDGE_PIN:0:12}…"
        (cd "$WINE_SOURCE_DIR" && git reset --hard "$BLEEDING_EDGE_PIN") 2>/dev/null || true
    else
        msg "Resetting source tree to origin/${_mythix_base_branch}…"
        (cd "$WINE_SOURCE_DIR" && git reset --hard "origin/${_mythix_base_branch}") 2>/dev/null || true
    fi
    (cd "$WINE_SOURCE_DIR" && git clean -fdx -- '*.rej' '*.orig' 'autom4te.cache') 2>/dev/null || true
    # Tag the clean base state so fixups can reliably revert files later
    (cd "$WINE_SOURCE_DIR" && git tag -f mythix-base-clean) 2>/dev/null || true
    # Also stash copies of files that staging frequently breaks (git show fails on shallow clones)
    _base_stash="${WINE_SOURCE_DIR}/.mythix-base-stash"
    mkdir -p "$_base_stash"
    for _stash_file in \
        dlls/msado15/connection.c \
        dlls/d3dx9_36/effect.c \
        dlls/nsiproxy.sys/icmp_echo.c \
        dlls/nsiproxy.sys/device.c \
        dlls/odbc32/proxyodbc.c \
        server/queue.c \
        server/registry.c \
        server/fd.c \
        server/sock.c \
        dlls/xinput1_3/main.c \
        dlls/ntdll/unix/file.c \
        dlls/ntdll/unix/signal_x86_64.c \
        dlls/win32u/class.c \
        dlls/win32u/imm.c \
        dlls/win32u/input.c \
        dlls/win32u/message.c \
        dlls/win32u/window.c \
        dlls/win32u/cursoricon.c \
        dlls/win32u/defwnd.c \
        dlls/win32u/hook.c \
        dlls/win32u/menu.c \
        dlls/win32u/ntuser_private.h \
        dlls/win32u/win32u_private.h \
        dlls/win32u/sysparams.c \
        dlls/winepulse.drv/pulse.c \
        dlls/winex11.drv/mouse.c \
        dlls/ws2_32/socket.c \
        dlls/wow64/system.c \
        dlls/mf/scheme_handler.c \
        dlls/mf/main.c \
        dlls/krnl386.exe16/instr.c \
        server/sock.c; do
        if [ -f "${WINE_SOURCE_DIR}/${_stash_file}" ]; then
            mkdir -p "$_base_stash/$(dirname "$_stash_file")"
            cp "${WINE_SOURCE_DIR}/${_stash_file}" "$_base_stash/${_stash_file}"
        fi
    done
    # Stash entire directories that staging breaks wholesale
    for _stash_dir in libs/vkd3d/libs/vkd3d-shader; do
        if [ -d "${WINE_SOURCE_DIR}/${_stash_dir}" ]; then
            mkdir -p "$_base_stash/${_stash_dir}"
            cp -a "${WINE_SOURCE_DIR}/${_stash_dir}/." "$_base_stash/${_stash_dir}/"
        fi
    done
    ok "Source tree reset to ${BLEEDING_EDGE_PIN:+pinned }${_mythix_base_branch}"

    # Cherry-pick post-pin commits (skip failures silently — some may conflict)
    if [[ -n "$BLEEDING_EDGE_PIN" && ${#BLEEDING_EDGE_CHERRIES[@]} -gt 0 ]]; then
        _cp_ok=0; _cp_skip=0
        msg "Cherry-picking ${#BLEEDING_EDGE_CHERRIES[@]} post-pin commits…"
        for _cherry in "${BLEEDING_EDGE_CHERRIES[@]}"; do
            if (cd "$WINE_SOURCE_DIR" && git cherry-pick --no-commit "$_cherry") 2>/dev/null; then
                (( _cp_ok++ )) || true
            else
                (cd "$WINE_SOURCE_DIR" && git cherry-pick --abort) 2>/dev/null || true
                (( _cp_skip++ )) || true
                msg2 "Skipped ${_cherry:0:12} (conflict)"
            fi
        done
        ok "Cherry-picked $_cp_ok commits ($_cp_skip skipped)"
    fi

    _mythix_patch_log="${BUILD_RUN_DIR}/mythix-patches.log"
    mkdir -p "$BUILD_RUN_DIR"
    : > "$_mythix_patch_log"

    # Helper: apply a diff/patch with stats reporting
    _mythix_apply_patch() {
        local _pf="$1" _pname="$2" _applied_var="$3" _skipped_var="$4" _failed_var="$5"
        if (cd "$WINE_SOURCE_DIR" && git apply --check "$_pf" 2>/dev/null); then
            if (cd "$WINE_SOURCE_DIR" && git apply "$_pf" 2>>"$_mythix_patch_log"); then
                printf "  ${C_GRN}✓${C_R}  %s\n" "$_pname"
                eval "(( $_applied_var++ )) || true"
            else
                printf "  ${C_RED}✗${C_R}  %s (apply failed)\n" "$_pname"
                eval "(( $_failed_var++ )) || true"
            fi
        else
            printf "  ${C_DIM}↷${C_R}  %s (already applied or conflicts)\n" "$_pname"
            eval "(( $_skipped_var++ )) || true"
        fi
    }

    # ── Layer 2: TkG patches (extracted from Kron4ek wine-tkg) ────────────
    # Clone Kron4ek's wine-tkg, add vanilla Wine as a remote, fetch the
    # matching tag, then git diff to isolate TkG's additions cleanly.
    section "Layer 2: TkG patches"

    _tkg_dir="${SRC_ROOT}/wine-tkg-ref"
    _tkg_diff="${BUILD_RUN_DIR}/tkg-extracted.patch"

    if [ ! -d "${_tkg_dir}/.git" ]; then
        msg "Cloning Kron4ek wine-tkg (reference for patch extraction)…"
        run git clone "$KRON4EK_TKG_REPO" "$_tkg_dir"
    else
        msg "Updating Kron4ek wine-tkg reference…"
        run git -C "$_tkg_dir" fetch origin 2>/dev/null || true
        run git -C "$_tkg_dir" reset --hard origin/HEAD 2>/dev/null || true
    fi

    # Pin TkG to a specific commit if the base branch requires it
    if [[ -n "$_tkg_pin_commit" ]]; then
        msg "Pinning TkG reference to ${_tkg_pin_label} (${_tkg_pin_commit:0:12})…"
        (cd "$_tkg_dir" && git reset --hard "$_tkg_pin_commit") 2>/dev/null || true
        ok "TkG pinned to ${_tkg_pin_label}"
    fi

    # Determine what Wine version Kron4ek's tree is based on
    _tkg_wine_ver=""
    if [ -f "${_tkg_dir}/VERSION" ]; then
        # VERSION contains e.g. "Wine version 11.11" — extract the number
        _tkg_wine_ver="$(sed -n 's/.*[Ww]ine[- ]version[- ]*\([0-9][0-9.]*\).*/\1/p' "${_tkg_dir}/VERSION" | head -1)" || true
    fi
    if [ -z "$_tkg_wine_ver" ] && [ -f "${_tkg_dir}/configure.ac" ]; then
        _tkg_wine_ver="$(sed -n 's/.*m4_define(\[WINE_VERSION\],.*\[\([0-9][0-9.]*\)\].*/\1/p' "${_tkg_dir}/configure.ac" | head -1)" || true
    fi

    if [ -n "$_tkg_wine_ver" ]; then
        msg2 "Kron4ek wine-tkg is based on Wine ${_tkg_wine_ver}"
        _vanilla_tag="wine-${_tkg_wine_ver}"

        # Add vanilla Wine as a remote inside the Kron4ek clone for clean git diff
        _vanilla_remote_url="https://gitlab.winehq.org/wine/wine.git"
        if ! git -C "$_tkg_dir" remote get-url vanilla >/dev/null 2>&1; then
            msg "Adding vanilla Wine as remote for diff extraction…"
            run git -C "$_tkg_dir" remote add vanilla "$_vanilla_remote_url"
        fi

        msg "Fetching vanilla Wine tag ${_vanilla_tag}…"
        run git -C "$_tkg_dir" fetch vanilla \
            "refs/tags/${_vanilla_tag}:refs/tags/${_vanilla_tag}" 2>/dev/null || {
            warn "Could not fetch tag ${_vanilla_tag} — trying full fetch"
            run git -C "$_tkg_dir" fetch vanilla || true
        }

        # Generate the TkG diff using git diff (proper rename detection, binary handling)
        msg "Extracting TkG patches (git diff: ${_vanilla_tag} → Kron4ek HEAD)…"
        set +e
        git -C "$_tkg_dir" diff "${_vanilla_tag}" HEAD \
            -- . ':!.github' ':!.gitignore' \
            > "$_tkg_diff" 2>/dev/null
        _diff_exit=$?
        set -e

        _tkg_diff_size=$(wc -l < "$_tkg_diff" 2>/dev/null || echo 0)
        _tkg_diff_files=$(grep -c '^diff --git' "$_tkg_diff" 2>/dev/null || echo 0)
        msg2 "TkG diff: ${_tkg_diff_files} files changed, ${_tkg_diff_size} lines"

        if [ "$_tkg_diff_size" -gt 0 ] && [ "$_diff_exit" -eq 0 ]; then
            # Apply the TkG diff onto Valve bleeding-edge
            msg "Applying TkG patches onto Valve bleeding-edge…"
            set +e
            (cd "$WINE_SOURCE_DIR" && git apply --3way --ignore-space-change \
                "$_tkg_diff" >> "$_mythix_patch_log" 2>&1)
            _tkg_exit=$?
            set -e

            if [ "$_tkg_exit" -eq 0 ]; then
                ok "TkG patches applied cleanly: ${_tkg_diff_files} files"
            else
                # Count what applied vs what conflicted
                _tkg_conflicts=$(grep -c 'Applied patch .* with conflicts' "$_mythix_patch_log" 2>/dev/null || echo 0)
                _tkg_rejects=$(grep -c 'error: patch failed\|rejected hunk' "$_mythix_patch_log" 2>/dev/null || echo 0)
                warn "TkG patches partially applied: ${_tkg_diff_files} files, ${_tkg_conflicts} conflicts, ${_tkg_rejects} rejects"
                msg2 "Expected — Valve's proton-wine diverges from mainline Wine"

                # Fall back to patch for hunks that git apply --3way couldn't handle
                msg2 "Attempting fallback with patch -p1 for remaining hunks…"
                set +e
                (cd "$WINE_SOURCE_DIR" && patch -p1 --forward --no-backup-if-mismatch --force \
                    < "$_tkg_diff" >> "$_mythix_patch_log" 2>&1)
                set -e

                _tkg_patched=$(grep -c 'patching file' "$_mythix_patch_log" 2>/dev/null || echo 0)
                _tkg_skipped=$(grep -c 'Reversed (or previously applied)' "$_mythix_patch_log" 2>/dev/null || echo 0)
                msg2 "Fallback: ${_tkg_patched} patched, ${_tkg_skipped} already applied"
            fi

            # Clean up conflict markers and .rej files
            find "$WINE_SOURCE_DIR" -name "*.rej" -delete 2>/dev/null || true
            find "$WINE_SOURCE_DIR" -name "*.orig" -delete 2>/dev/null || true
        elif [ "$_tkg_diff_size" -eq 0 ]; then
            warn "TkG diff was empty — Kron4ek may match vanilla Wine at this version"
        else
            warn "git diff failed (exit ${_diff_exit}) — skipping TkG patches"
        fi
    else
        warn "Could not determine Kron4ek's Wine version — skipping TkG patch extraction"
        msg2 "You can still apply TkG patches manually via --patches-dir"
    fi

    # Commit the TkG layer so subsequent patches apply cleanly
    (cd "$WINE_SOURCE_DIR" && git add -A && \
        git commit -q -m "mythix-wine: TkG patch layer" --allow-empty) 2>/dev/null || true

    # ── Layer 3: Wine-Staging patches ─────────────────────────────────────
    section "Layer 3: Wine-Staging patches"

    _staging_dir="${SRC_ROOT}/wine-staging-mythix"
    if [ ! -d "${_staging_dir}/.git" ]; then
        msg "Cloning wine-staging…"
        run git clone "https://github.com/wine-staging/wine-staging.git" "$_staging_dir"
    else
        msg "Updating wine-staging…"
        run git -C "$_staging_dir" fetch origin 2>/dev/null || true
        run git -C "$_staging_dir" reset --hard origin/HEAD 2>/dev/null || true
    fi

    # Pin staging to a version matching the Wine base when not using bleeding-edge
    if [[ "$MYTHIX_WINE_BASE" == "proton_10.0" ]]; then
        _staging_tag="$(cd "$_staging_dir" && git tag -l 'v10.*' | sort -V | tail -1)"
        if [[ -n "$_staging_tag" ]]; then
            msg "Pinning wine-staging to ${_staging_tag} (matching Wine 10.x base)…"
            (cd "$_staging_dir" && git checkout "$_staging_tag") 2>/dev/null || true
            ok "Staging pinned to ${_staging_tag}"
        else
            warn "No v10.x staging tag found — using latest"
        fi
    fi

    _staging_script="${_staging_dir}/staging/patchinstall.py"
    if [ ! -f "$_staging_script" ]; then
        _staging_script="${_staging_dir}/patches/patchinstall.sh"
    fi

    if [ -f "$_staging_script" ]; then
        msg "Applying Wine-Staging patches…"
        msg2 "Using --all with --force (some patches may already exist in the base)"

        # Reset the staging log portion
        _staging_log="${BUILD_RUN_DIR}/mythix-staging.log"
        set +e
        if [[ "$_staging_script" == *.py ]]; then
            (cd "$WINE_SOURCE_DIR" && python3 "$_staging_script" --all --force --backend=git-apply) \
                > "$_staging_log" 2>&1
        else
            (cd "$WINE_SOURCE_DIR" && bash "$_staging_script" --all --force --backend=git-apply) \
                > "$_staging_log" 2>&1
        fi
        _staging_exit=$?
        set -e

        _staging_applied=$(grep -c 'Applied patch\|patching file' "$_staging_log" 2>/dev/null || echo 0)
        _staging_skipped=$(grep -c 'Skipping\|already applied' "$_staging_log" 2>/dev/null || echo 0)

        if [ "$_staging_exit" -eq 0 ]; then
            ok "Wine-Staging patches applied: ~${_staging_applied} patch operations"
        else
            warn "Staging patches partially applied (exit ${_staging_exit})"
            msg2 "Expected — Valve proton-wine already includes some staging work"
            msg2 "Log: ${_staging_log}"
        fi

        # Clean up rejects
        find "$WINE_SOURCE_DIR" -name "*.rej" -delete 2>/dev/null || true
    else
        warn "wine-staging patchinstall script not found — skipping"
        msg2 "Looked for: patchinstall.py / patchinstall.sh"
    fi

    # Commit the staging layer
    (cd "$WINE_SOURCE_DIR" && git add -A && \
        git commit -q -m "mythix-wine: Wine-Staging patch layer" --allow-empty) 2>/dev/null || true

    # ── Layer 4: GE-Proton gaming patches ─────────────────────────────────
    section "Layer 4: GE-Proton gaming patches"

    GE_CACHE_DIR="${SRC_ROOT}/proton-ge-custom"

    if [ ! -d "${GE_CACHE_DIR}/.git" ]; then
        msg "Cloning proton-ge-custom…"
        run git clone --depth=1 "$GE_PROTON_REPO" "$GE_CACHE_DIR"
    else
        msg "Updating proton-ge-custom…"
        run git -C "$GE_CACHE_DIR" pull --ff-only 2>/dev/null || true
    fi
    ok "GE source ready: ${GE_CACHE_DIR}"

    _ge_patches_dir="${GE_CACHE_DIR}/patches"
    _ge_applied=0
    _ge_skipped=0
    _ge_failed=0

    if [ -d "$_ge_patches_dir" ]; then
        msg "Applying GE patches from ${_ge_patches_dir}…"

        _patch_files=()
        while IFS= read -r -d '' _pf; do
            _patch_files+=("$_pf")
        done < <(find "$_ge_patches_dir" -name "*.patch" -print0 2>/dev/null | sort -z)

        for _pf in "${_patch_files[@]}"; do
            _pname="$(basename "$_pf")"
            case "$_pname" in
                *dxvk*|*vkd3d*|*nvapi*) continue ;;
                *winewayland*|*wayland*) continue ;;
                *amdxc*|*atidxx*) continue ;;
            esac
            _mythix_apply_patch "$_pf" "$_pname" _ge_applied _ge_skipped _ge_failed
        done

        ok "GE patches: ${_ge_applied} applied, ${_ge_skipped} skipped, ${_ge_failed} failed"
    else
        warn "No GE patches directory found — skipping GE layer"
    fi

    # Commit the GE layer
    (cd "$WINE_SOURCE_DIR" && git add -A && \
        git commit -q -m "mythix-wine: GE-Proton patch layer" --allow-empty) 2>/dev/null || true

    # ── Layer 5: Mythix custom patches ────────────────────────────────────
    _mythix_custom_patches="${PATCHES_DIR}/mythix-wine"
    if [ -d "$_mythix_custom_patches" ] && ls "${_mythix_custom_patches}"/*.patch >/dev/null 2>&1; then
        section "Layer 5: Mythix custom patches"
        _mc_applied=0
        _mc_skipped=0
        _mc_failed=0
        for _pf in "${_mythix_custom_patches}"/*.patch; do
            [ -f "$_pf" ] || continue
            _pname="$(basename "$_pf")"
            _mythix_apply_patch "$_pf" "$_pname" _mc_applied _mc_skipped _mc_failed
        done
        ok "Mythix custom: ${_mc_applied} applied, ${_mc_skipped} skipped, ${_mc_failed} failed"

        (cd "$WINE_SOURCE_DIR" && git add -A && \
            git commit -q -m "mythix-wine: custom patch layer" --allow-empty) 2>/dev/null || true
    fi

    # ── Post-patch compilation fixups ─────────────────────────────────────
    # GE/Staging patches can introduce code that depends on newer system
    # libraries than the build container has. Fix known issues here.
    section "Post-patch compatibility fixups"
    _fixups_applied=0

    # Fix 1: XKB_VMOD_NAME_SCROLL — needs libxkbcommon >= 1.7.0
    # GE's wayland keyboard patches use this constant; older xkbcommon
    # doesn't have it. Replace with the string literal it resolves to.
    _wayland_kbd="${WINE_SOURCE_DIR}/dlls/winewayland.drv/wayland_keyboard.c"
    if [ -f "$_wayland_kbd" ] && grep -q 'XKB_VMOD_NAME_SCROLL' "$_wayland_kbd"; then
        sed -i 's/XKB_VMOD_NAME_SCROLL/"ScrollLock"/g' "$_wayland_kbd"
        ok "Fixup: XKB_VMOD_NAME_SCROLL → \"ScrollLock\" (libxkbcommon compat)"
        (( _fixups_applied++ )) || true
    fi

    # Fix 2: XKB_VMOD_NAME_NUM — same issue as above
    if [ -f "$_wayland_kbd" ] && grep -q 'XKB_VMOD_NAME_NUM' "$_wayland_kbd"; then
        sed -i 's/XKB_VMOD_NAME_NUM/"NumLock"/g' "$_wayland_kbd"
        ok "Fixup: XKB_VMOD_NAME_NUM → \"NumLock\" (libxkbcommon compat)"
        (( _fixups_applied++ )) || true
    fi

    # Fix 3: XKB_VMOD_NAME_CAPS
    if [ -f "$_wayland_kbd" ] && grep -q 'XKB_VMOD_NAME_CAPS' "$_wayland_kbd"; then
        sed -i 's/XKB_VMOD_NAME_CAPS/"Caps Lock"/g' "$_wayland_kbd"
        ok "Fixup: XKB_VMOD_NAME_CAPS → \"Caps Lock\" (libxkbcommon compat)"
        (( _fixups_applied++ )) || true
    fi

    # Fix 4: wl_display_create_queue_with_name — needs libwayland >= 1.23
    # Fall back to wl_display_create_queue if the named version isn't available
    _wayland_c="${WINE_SOURCE_DIR}/dlls/winewayland.drv/wayland.c"
    if [ -f "$_wayland_c" ] && grep -q 'wl_display_create_queue_with_name' "$_wayland_c"; then
        sed -i 's/wl_display_create_queue_with_name(\([^,]*\),\s*"[^"]*")/wl_display_create_queue(\1)/g' "$_wayland_c"
        ok "Fixup: wl_display_create_queue_with_name → wl_display_create_queue (libwayland compat)"
        (( _fixups_applied++ )) || true
    fi

    # Fix 5: close_inproc_sync_obj → NtClose (GE ntsync compat)
    _thread_c="${WINE_SOURCE_DIR}/dlls/ntdll/unix/thread.c"
    if [ -f "$_thread_c" ] && grep -q 'close_inproc_sync_obj' "$_thread_c"; then
        sed -i 's/close_inproc_sync_obj( wait_handle );/NtClose( wait_handle );/' "$_thread_c"
        ok "Fixup: close_inproc_sync_obj → NtClose (ntsync compat)"
        (( _fixups_applied++ )) || true
    fi

    # Fix 7: Duplicate function definitions from TkG 3-way merge
    # Scan all C files under dlls/ntdll/unix/ for any function defined twice.
    # The Python script auto-detects duplicates and removes the second copy.
    while IFS= read -r _src_c; do
        [ -f "$_src_c" ] || continue
        python3 -c "
import re, sys, os
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
# Find all function definitions: type + name + ( at start of line
func_pat = re.compile(r'^(?:(?:static|extern|NTSYSAPI)\s+)*(?:(?:struct|enum|union)\s+)?(?:\w+)(?:\s+(?:WINAPI|CDECL|__cdecl|WINAPIV|CALLBACK))?(?:\s+DECLSPEC_HOTPATCH)?(?:\s+[A-Z_][A-Z0-9_]*\([^)]*\))?\s+\**(\w+)\s*\(')
_kw_skip = {'if','else','while','for','switch','return','sizeof','typeof','__typeof','defined','case','do','goto','ifdef','ifndef','include','define','undef','elif','pragma','error','warning'}
# Collect all function names and their definition line indices
func_defs = {}
for i, line in enumerate(lines):
    if line is None: continue
    m = func_pat.match(line)
    if not m: continue
    name = m.group(1)
    if name in _kw_skip: continue
    if line.rstrip().endswith(';'): continue
    if line.lstrip().startswith('typedef '): continue
    stripped = line.lstrip()
    if stripped.startswith('struct ') or stripped.startswith('enum ') or stripped.startswith('union '): continue
    # Verify it's a definition (has { within 5 lines, no ; before the {)
    is_fwd_decl = False
    for j in range(i, min(i+6, len(lines))):
        if lines[j] is None: continue
        stripped_j = lines[j].rstrip()
        if stripped_j.endswith(';'):
            is_fwd_decl = True
            break
        if '{' in lines[j]:
            func_defs.setdefault(name, []).append(i)
            break
# Build #ifdef/#else sibling map: identify lines that are in opposite arms of the same #if/#else
# Two functions are conditional duplicates ONLY if one is in #if and the other in #else of the SAME block
# Build preprocessor branch map: track all arms of #if/#elif/#else/#endif blocks
# Each block is a list of (arm_start, arm_end) ranges that are mutually exclusive
pp_blocks = []  # list of lists: [ [(arm1_start, arm1_end), (arm2_start, arm2_end), ...], ... ]
pp_regions = []  # every conditional region (start, end), incl. single-arm blocks
pp_stack2 = []
for i, line in enumerate(lines):
    if line is None: continue
    s = line.strip()
    if s.startswith('#ifdef') or s.startswith('#ifndef') or (s.startswith('#if ') and not s.startswith('#if 0')):
        pp_stack2.append({'arms': [i], 'start': i})
    elif (s.startswith('#elif') and (len(s)==5 or s[5] in ' \t')) and pp_stack2:
        pp_stack2[-1]['arms'].append(i)
    elif (s == '#else' or s.startswith('#else ') or s.startswith('#else\t')) and pp_stack2:
        pp_stack2[-1]['arms'].append(i)
    elif s.startswith('#endif') and pp_stack2:
        info = pp_stack2.pop()
        arms = info['arms']
        if len(arms) >= 2:
            arm_ranges = []
            for idx in range(len(arms)):
                a_start = arms[idx]
                a_end = arms[idx+1] if idx+1 < len(arms) else i
                arm_ranges.append((a_start, a_end))
            pp_blocks.append(arm_ranges)
        pp_regions.append((info['start'], i))

def all_in_separate_arms(line_indices):
    # Check if ALL line indices are in different arms of the same preprocessor block
    for block in pp_blocks:
        arm_assignments = {}
        all_found = True
        for li in line_indices:
            found_arm = False
            for arm_idx, (a_start, a_end) in enumerate(block):
                if a_start < li < a_end:
                    arm_assignments[li] = arm_idx
                    found_arm = True
                    break
            if not found_arm:
                all_found = False
                break
        if all_found and len(set(arm_assignments.values())) == len(line_indices):
            return True
    return False

def innermost_region(li):
    # Smallest enclosing conditional region, or None
    best = None
    for (r_start, r_end) in pp_regions:
        if r_start < li < r_end:
            if best is None or (r_end - r_start) < (best[1] - best[0]):
                best = (r_start, r_end)
    return best

def all_in_distinct_regions(line_indices):
    # Each copy inside some conditional region, no two sharing the same one
    # (e.g. sibling '#ifdef __arm__' / '#ifdef __x86_64__' blocks)
    seen = set()
    for li in line_indices:
        r = innermost_region(li)
        if r is None or r in seen:
            return False
        seen.add(r)
    return True

# Find duplicates — skip sets where all copies are in separate preprocessor arms
# or in entirely distinct conditional regions (arch-guarded siblings)
all_dups = {k: v for k, v in func_defs.items() if len(v) > 1}
dups = {}
for k, v in all_dups.items():
    if all_in_separate_arms(v):
        continue
    if all_in_distinct_regions(v):
        continue
    dups[k] = v
if not dups:
    sys.exit(1)
removed = []
for name, indices in dups.items():
    # Decide which copy to remove: count parameters in each definition line
    # Keep the one with more params (TkG updated version), remove the other
    def count_params(idx):
        # Collect the full signature (may span multiple lines until '{')
        sig = ''
        for j in range(idx, min(idx+6, len(lines))):
            if lines[j] is None: continue
            sig += lines[j]
            if '{' in lines[j]: break
        return sig.count(',')
    p0 = count_params(indices[0])
    p1 = count_params(indices[1])
    # If signatures differ, remove the one with fewer params; otherwise remove first (bleeding-edge original)
    if p0 != p1:
        start = indices[0] if p0 < p1 else indices[1]
    else:
        start = indices[1]
    # Scan back for comment block
    cs = start
    s = cs - 1
    while s >= 0 and lines[s] is not None and lines[s].strip() == '':
        s -= 1
    if s >= 0 and lines[s] is not None and lines[s].strip().endswith('*/'):
        while s >= 0 and lines[s] is not None and '/*' not in lines[s]:
            s -= 1
        cs = s
    # Don't scan back past preprocessor directives
    for j in range(cs, start):
        if lines[j] is not None and lines[j].lstrip().startswith('#'):
            cs = start
            break
    # Find function end via brace counting
    depth = 0; end = start; started = False
    for j in range(start, len(lines)):
        if lines[j] is None: continue
        depth += lines[j].count('{') - lines[j].count('}')
        if '{' in lines[j]: started = True
        if started and depth == 0:
            end = j; break
    for j in range(cs, end + 1):
        lines[j] = None
    removed.append(name)
with open(path, 'w') as f:
    f.writelines(l for l in lines if l is not None)
print(os.path.basename(path) + ': removed ' + ', '.join(removed))
" "$_src_c" && {
            ok "Fixup: removed duplicate functions in $(basename "$_src_c")"
            (( _fixups_applied++ )) || true
        }
    done < <(find "${WINE_SOURCE_DIR}/dlls" "${WINE_SOURCE_DIR}/server" "${WINE_SOURCE_DIR}/programs" -name '*.c' -type f 2>/dev/null \
        | grep -v 'server/queue\.c$\|server/registry\.c$\|server/fd\.c$\|nsiproxy\.sys/icmp_echo\.c$\|nsiproxy\.sys/device\.c$\|odbc32/proxyodbc\.c$\|ntdll/unix/file\.c$')

    # Fix 8: Missing int3_stub in kernel32/module.c — TkG patch references it but never defined it
    _module_c="${WINE_SOURCE_DIR}/dlls/kernel32/module.c"
    if [ -f "$_module_c" ] && grep -q 'int3_stub' "$_module_c" && ! grep -q 'static.*int3_stub' "$_module_c"; then
        sed -i '/^static BOOL int3_hack_enabled/i\static const unsigned char int3_stub[] = { 0xcc, 0xc3 }; /* int3; ret */\n' "$_module_c"
        ok "Fixup: added missing int3_stub definition in kernel32/module.c"
        (( _fixups_applied++ )) || true
    fi

    # Fix 9: battleye_launcher_redirect_hack stale call site
    # TkG added a 5th param (product_name) but a bleeding-edge call site wasn't updated
    _process_c="${WINE_SOURCE_DIR}/dlls/kernelbase/process.c"
    if [ -f "$_process_c" ] && grep -q 'battleye_launcher_redirect_hack.*&tidy_cmdline' "$_process_c"; then
        sed -i 's/battleye_launcher_redirect_hack( app_name, name, ARRAY_SIZE(name), &tidy_cmdline )/battleye_launcher_redirect_hack( app_name, name, ARRAY_SIZE(name), \&tidy_cmdline, product_name )/' "$_process_c"
        ok "Fixup: added missing product_name arg to battleye_launcher_redirect_hack call"
        (( _fixups_applied++ )) || true
    fi

    # Fix 9b: TkG merge gave set_sd_defaults_from_token the wrong name (set_sd_from_token_internal)
    _object_c="${WINE_SOURCE_DIR}/server/object.c"
    if [ -f "$_object_c" ] && grep -q 'set_sd_defaults_from_token' "${WINE_SOURCE_DIR}/server/object.h" 2>/dev/null; then
        _dup_count=$(grep -c '^struct security_descriptor \*set_sd_from_token_internal' "$_object_c" 2>/dev/null || echo 0)
        if [ "$_dup_count" -ge 2 ]; then
            python3 -c "
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
# Find the second occurrence and replace its signature
first = content.find('struct security_descriptor *set_sd_from_token_internal(')
if first >= 0:
    second = content.find('struct security_descriptor *set_sd_from_token_internal(', first + 1)
    if second >= 0:
        # Find the end of the old signature (next '{')
        brace = content.index('{', second)
        old_sig = content[second:brace]
        new_sig = 'int set_sd_defaults_from_token( struct object *obj, const struct security_descriptor *sd,\n                                unsigned int set_info, struct token *token )\n'
        content = content[:second] + new_sig + content[brace:]
        with open(path, 'w') as f:
            f.write(content)
        print('Fixed set_sd_defaults_from_token signature')
" "$_object_c" && {
                ok "Fixup: corrected set_sd_defaults_from_token name in server/object.c"
                (( _fixups_applied++ )) || true
            }
        fi
    fi

    # Fix 9c: Duplicate FreeThreadedDOMDocument60 coclass in msxml6.idl
    _msxml6="${WINE_SOURCE_DIR}/include/msxml6.idl"
    if [ -f "$_msxml6" ]; then
        _dup_count=$(grep -c 'coclass FreeThreadedDOMDocument60' "$_msxml6" 2>/dev/null || echo 0)
        if [ "$_dup_count" -ge 2 ]; then
            # Remove the second coclass block (attribute block + coclass + body)
            python3 -c "
import sys, re
with open(sys.argv[1]) as f:
    content = f.read()
# Find second occurrence of the coclass and its preceding attribute block
pattern = r'\n\[\s*\n\s*helpstring\(\"Free threaded XML DOM Document 6\.0\"\).*?\ncoclass FreeThreadedDOMDocument60\s*\{[^}]*\}'
matches = list(re.finditer(pattern, content, re.DOTALL))
if len(matches) >= 2:
    content = content[:matches[1].start()] + content[matches[1].end():]
    with open(sys.argv[1], 'w') as f:
        f.write(content)
    print('Removed duplicate FreeThreadedDOMDocument60')
" "$_msxml6" && {
                ok "Fixup: removed duplicate FreeThreadedDOMDocument60 in msxml6.idl"
                (( _fixups_applied++ )) || true
            }
        fi
    fi

    # Fix 9d: Add IInkOverlay interface to msinkaut.idl (patches add inkobj.c code using it)
    _msinkaut="${WINE_SOURCE_DIR}/include/msinkaut.idl"
    if [ -f "$_msinkaut" ] && ! grep -q 'IInkOverlay' "$_msinkaut"; then
        python3 -c "
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

idl_addition = '''
    typedef enum {
        IOEM_Ink = 0,
        IOEM_Delete = 1,
        IOEM_Select = 2,
    } InkOverlayEditingMode;

    typedef enum {
        IOERM_StrokeErase = 0,
        IOERM_PointErase = 1,
    } InkOverlayEraserMode;

    typedef enum {
        IOAM_Behind = 0,
        IOAM_InFront = 1,
    } InkOverlayAttachMode;

    typedef enum {
        ISHR_None = 0,
        ISHR_NW = 1,
        ISHR_SE = 2,
        ISHR_NE = 3,
        ISHR_SW = 4,
        ISHR_N = 5,
        ISHR_S = 6,
        ISHR_E = 7,
        ISHR_W = 8,
    } SelectionHitResult;

    [
        odl,
        uuid(B82A463B-C1C5-45A3-997C-DEAB5651B67A),
        dual,
        oleautomation
    ]
    interface IInkOverlay : IDispatch {
        [id(0x00000002), propget]    HRESULT hWnd([out, retval] long* CurrentWindow);
        [id(0x00000002), propput]    HRESULT hWnd([in] long CurrentWindow);
        [id(0x00000001), propget]    HRESULT Enabled([out, retval] VARIANT_BOOL* Collecting);
        [id(0x00000001), propput]    HRESULT Enabled([in] VARIANT_BOOL Collecting);
        [id(0x00000005), propget]    HRESULT DefaultDrawingAttributes([out, retval] IInkDrawingAttributes** CurrentAttributes);
        [id(0x00000005), propputref] HRESULT DefaultDrawingAttributes([in] IInkDrawingAttributes* CurrentAttributes);
        [id(0x00000006), propget]    HRESULT Renderer([out, retval] IInkRenderer** CurrentInkRenderer);
        [id(0x00000006), propputref] HRESULT Renderer([in] IInkRenderer* CurrentInkRenderer);
        [id(0x00000007), propget]    HRESULT Ink([out, retval] IInkDisp** Ink);
        [id(0x00000007), propputref] HRESULT Ink([in] IInkDisp* Ink);
        [id(0x00000008), propget]    HRESULT AutoRedraw([out, retval] VARIANT_BOOL* AutoRedraw);
        [id(0x00000008), propput]    HRESULT AutoRedraw([in] VARIANT_BOOL AutoRedraw);
        [id(0x00000009), propget]    HRESULT CollectingInk([out, retval] VARIANT_BOOL* Collecting);
        [id(0x0000001c), propget]    HRESULT CollectionMode([out, retval] InkCollectionMode* Mode);
        [id(0x0000001c), propput]    HRESULT CollectionMode([in] InkCollectionMode Mode);
        [id(0x0000001f), propget]    HRESULT DynamicRendering([out, retval] VARIANT_BOOL* Enabled);
        [id(0x0000001f), propput]    HRESULT DynamicRendering([in] VARIANT_BOOL Enabled);
        [id(0x00000020), propget]    HRESULT DesiredPacketDescription([out, retval] VARIANT* PacketGuids);
        [id(0x00000020), propput]    HRESULT DesiredPacketDescription([in] VARIANT PacketGuids);
        [id(0x00000023), propget]    HRESULT MouseIcon([out, retval] IPictureDisp** MouseIcon);
        [id(0x00000023), propput]    HRESULT MouseIcon([in] IPictureDisp* MouseIcon);
        [id(0x00000023), propputref] HRESULT MouseIcon([in] IPictureDisp* MouseIcon);
        [id(0x00000024), propget]    HRESULT MousePointer([out, retval] InkMousePointer* MousePointer);
        [id(0x00000024), propput]    HRESULT MousePointer([in] InkMousePointer MousePointer);
        [id(0x00000025), propget]    HRESULT EditingMode([out, retval] InkOverlayEditingMode* EditingMode);
        [id(0x00000025), propput]    HRESULT EditingMode([in] InkOverlayEditingMode EditingMode);
        [id(0x00000027), propget]    HRESULT Selection([out, retval] IInkStrokes** Selection);
        [id(0x00000027), propput]    HRESULT Selection([in] IInkStrokes* Selection);
        [id(0x00000028), propget]    HRESULT EraserMode([out, retval] InkOverlayEraserMode* EraserMode);
        [id(0x00000028), propput]    HRESULT EraserMode([in] InkOverlayEraserMode EraserMode);
        [id(0x00000029), propget]    HRESULT EraserWidth([out, retval] long* EraserWidth);
        [id(0x00000029), propput]    HRESULT EraserWidth([in] long EraserWidth);
        [id(0x0000002a), propget]    HRESULT AttachMode([out, retval] InkOverlayAttachMode* AttachMode);
        [id(0x0000002a), propput]    HRESULT AttachMode([in] InkOverlayAttachMode AttachMode);
        [id(0x00000014), propget]    HRESULT Cursors([out, retval] IInkCursors** Cursors);
        [id(0x00000015), propget]    HRESULT MarginX([out, retval] long* MarginX);
        [id(0x00000015), propput]    HRESULT MarginX([in] long MarginX);
        [id(0x00000016), propget]    HRESULT MarginY([out, retval] long* MarginY);
        [id(0x00000016), propput]    HRESULT MarginY([in] long MarginY);
        [id(0x00000019), propget]    HRESULT Tablet([out, retval] IInkTablet** SingleTablet);
        [id(0x00000026), propget]    HRESULT SupportHighContrastInk([out, retval] VARIANT_BOOL* Support);
        [id(0x00000026), propput]    HRESULT SupportHighContrastInk([in] VARIANT_BOOL Support);
        [id(0x0000002b), propget]    HRESULT SupportHighContrastSelectionUI([out, retval] VARIANT_BOOL* Support);
        [id(0x0000002b), propput]    HRESULT SupportHighContrastSelectionUI([in] VARIANT_BOOL Support);
        [id(0x0000002c)]             HRESULT HitTestSelection([in] long x, [in] long y, [out, retval] SelectionHitResult* SelArea);
        [id(0x0000002d)]             HRESULT Draw([in] IInkRectangle* Rect);
        [id(0x0000001d)]             HRESULT SetGestureStatus([in] InkApplicationGesture Gesture, [in] VARIANT_BOOL Listen);
        [id(0x0000001e)]             HRESULT GetGestureStatus([in] InkApplicationGesture Gesture, [out, retval] VARIANT_BOOL* Listening);
        [id(0x00000018)]             HRESULT GetWindowInputRectangle([in, out] IInkRectangle** WindowInputRectangle);
        [id(0x00000017)]             HRESULT SetWindowInputRectangle([in] IInkRectangle* WindowInputRectangle);
        [id(0x0000001a)]             HRESULT SetAllTabletsMode([in, defaultvalue(-1)] VARIANT_BOOL UseMouseForInput);
        [id(0x0000001b)]             HRESULT SetSingleTabletIntegratedMode([in] IInkTablet* Tablet);
        [id(0x0000000b)]             HRESULT GetEventInterest([in] InkCollectorEventInterest EventId, [out, retval] VARIANT_BOOL* Listen);
        [id(0x0000000a)]             HRESULT SetEventInterest([in] InkCollectorEventInterest EventId, [in] VARIANT_BOOL Listen);
    }

    [
        uuid(43FB1553-AD74-4EE8-88E4-3E6DAAC915DB)
    ]
    coclass InkDisp
    {
        [default] interface IInkDisp;
    }

    [
        uuid(65D00646-CDE3-4A88-9163-6770F0F657C4)
    ]
    coclass InkOverlay
    {
        [default] interface IInkOverlay;
    }
'''

# Insert before the closing '}'  of the library block (last '}' in the file)
last_brace = content.rstrip().rfind('}')
content = content[:last_brace] + idl_addition + '\n}\n'
with open(path, 'w') as f:
    f.write(content)
print('Added IInkOverlay interface')
" "$_msinkaut" && {
            ok "Fixup: added IInkOverlay interface to msinkaut.idl"
            (( _fixups_applied++ )) || true
        }
    fi

    # Fix 9e: Missing MFNETSOURCE_STATISTICS_SERVICE GUID in mfplat/network.c
    _network_c="${WINE_SOURCE_DIR}/dlls/mfplat/network.c"
    if [ -f "$_network_c" ] && grep -q 'MFNETSOURCE_STATISTICS_SERVICE' "$_network_c" && ! grep -q 'DEFINE_GUID.*MFNETSOURCE_STATISTICS_SERVICE' "$_network_c"; then
        sed -i '/#include "wine\/debug.h"/a\\nDEFINE_GUID(MFNETSOURCE_STATISTICS_SERVICE, 0x3cb1f28e, 0x0505, 0x4c5d, 0xae, 0x71, 0x0a, 0x55, 0x63, 0x44, 0xef, 0xa1);' "$_network_c"
        ok "Fixup: added MFNETSOURCE_STATISTICS_SERVICE GUID to mfplat/network.c"
        (( _fixups_applied++ )) || true
    fi

    # Fix 9f: Duplicate struct/vtbl block in msxml3/httprequest.c from TkG merge
    _httpreq="${WINE_SOURCE_DIR}/dlls/msxml3/httprequest.c"
    if [ -f "$_httpreq" ]; then
        _dup=$(grep -cn '^struct xml_http_request_2$' "$_httpreq" 2>/dev/null || echo 0)
        if [ "$_dup" -ge 2 ]; then
            python3 -c "
import sys
with open(sys.argv[1]) as f:
    lines = f.readlines()
# Find second 'static DWORD xhr2_work_queue;' which starts the dup block
first = None
second = None
for i, l in enumerate(lines):
    if l.strip() == 'static DWORD xhr2_work_queue;':
        if first is None: first = i
        else: second = i; break
if second is not None:
    # Find end: next 'static void init_httprequest' or similar non-dup line
    end = second
    for i in range(second, len(lines)):
        if lines[i].strip().startswith('static void init_httprequest'):
            end = i; break
    del lines[second:end]
    with open(sys.argv[1], 'w') as f:
        f.writelines(lines)
    print(f'Removed duplicate block lines {second+1}-{end}')
" "$_httpreq" && {
                ok "Fixup: removed duplicate xhr2 block in msxml3/httprequest.c"
                (( _fixups_applied++ )) || true
            }
        fi
    fi

    # Fix 9g: Missing CLSID_FreeThreadedXMLHTTP60 in msxml3/factory.c
    _factory_c="${WINE_SOURCE_DIR}/dlls/msxml3/factory.c"
    if [ -f "$_factory_c" ] && grep -q 'CLSID_FreeThreadedXMLHTTP60' "$_factory_c" && ! grep -q 'DEFINE_GUID.*CLSID_FreeThreadedXMLHTTP60' "$_factory_c"; then
        sed -i '/#include "msxml_private.h"/a\\nDEFINE_GUID(CLSID_FreeThreadedXMLHTTP60, 0x88d96a09, 0xf192, 0x11d4, 0xa6,0x5f, 0x00,0x40,0x96,0x32,0x51,0xe5);' "$_factory_c"
        ok "Fixup: added CLSID_FreeThreadedXMLHTTP60 to msxml3/factory.c"
        (( _fixups_applied++ )) || true
    fi

    # Fix 9h000: nsiproxy.sys fixups — TkG split icmp_data into icmp_socket+icmp_data
    _icmp_echo="${WINE_SOURCE_DIR}/dlls/nsiproxy.sys/icmp_echo.c"
    if [ -f "$_icmp_echo" ]; then
        if grep -q 'wine/nsi.h' "$_icmp_echo" && ! grep -q 'wine/list.h' "$_icmp_echo"; then
            sed -i '/#include "wine\/nsi.h"/a\#include "wine/list.h"' "$_icmp_echo"
            ok "Fixup: added wine/list.h include to icmp_echo.c"
            (( _fixups_applied++ )) || true
        fi
        # Add assert.h include (TkG patches use assert() but didn't add the include)
        if grep -q 'assert(' "$_icmp_echo" && ! grep -q 'assert\.h' "$_icmp_echo"; then
            sed -i '/#include <stdlib.h>/i\#include <assert.h>' "$_icmp_echo"
            ok "Fixup: added assert.h include to icmp_echo.c"
            (( _fixups_applied++ )) || true
        fi
        # Bulk redirect all icmp_socket fields through data->s->
        sed -i 's/data->id = getpid/data->s->id = getpid/g' "$_icmp_echo"
        sed -i 's/icmp_data->ping_socket/icmp_data->s->ping_socket/g' "$_icmp_echo"
        sed -i 's/icmp_data->src_storage/icmp_data->s->src_storage/g' "$_icmp_echo"
        sed -i 's/icmp_data->src_len/icmp_data->s->src_len/g' "$_icmp_echo"
        sed -i 's/data->ping_socket/data->s->ping_socket/g' "$_icmp_echo"
        sed -i "s/!= data->id)/!= data->s->id)/g" "$_icmp_echo"
        sed -i 's/data->socket/data->s->socket/g' "$_icmp_echo"
        # Fix options_data pointer → offset
        sed -i 's/ctx->options_data = ip_hdr + 1;/ctx->options_data_offset = sizeof(*ip_hdr);/g' "$_icmp_echo"
        sed -i 's/ctx->options_data = NULL;/ctx->options_data_offset = 0;/g' "$_icmp_echo"
        sed -i 's/ctx->options_data,/ctx->packet + ctx->options_data_offset,/g' "$_icmp_echo"
        sed -i 's/ctx->data, ctx->data_size/ctx->packet + ctx->data_offset, ctx->data_size/g' "$_icmp_echo"
        # Remove stale set_socket_opts call from icmp_get_socket (takes data+params now, not socket)
        sed -i '/s->ops->set_socket_opts( s );/d' "$_icmp_echo"
        # Add set_socket_opts call in icmp_send_echo after getting socket
        sed -i '/data->completion_event = params->completion_event;/i\    data->s->ops->set_socket_opts( data, params );' "$_icmp_echo"
        # Fix void fill_reply used in if condition
        if grep -q 'if (!data->s->ops->fill_reply' "$_icmp_echo"; then
            python3 -c "
import re
with open('$_icmp_echo') as f: t = f.read()
t = re.sub(
    r'if \(!data->s->ops->fill_reply\( params, &data->reply_ctx \)\)\n\s*\{[^}]*WARN[^}]*set_reply_ip_status[^}]*\}\n\s*else (TRACE)',
    r'data->s->ops->fill_reply( params, &data->reply_ctx );' + '\n        ' + r'\1',
    t, flags=re.DOTALL)
with open('$_icmp_echo','w') as f: f.write(t)
"
        fi
        ok "Fixup: comprehensive nsiproxy icmp_echo.c field redirections"
        (( _fixups_applied++ )) || true
    fi
    _nsi_private="${WINE_SOURCE_DIR}/dlls/nsiproxy.sys/nsiproxy_private.h"
    if [ -f "$_nsi_private" ]; then
        if grep -q 'icmp_listen_params' "$_nsi_private" && ! grep -q 'icmp_get_reply_params' "$_nsi_private"; then
            echo '#define icmp_get_reply_params icmp_listen_params' >> "$_nsi_private"
            ok "Fixup: aliased icmp_get_reply_params to icmp_listen_params"
            (( _fixups_applied++ )) || true
        fi
        # Add completion_event to icmp_send_echo_params
        if ! grep -q 'completion_event' "$_nsi_private"; then
            sed -i '/icmp_handle \*handle;/a\    HANDLE completion_event;' "$_nsi_private"
            ok "Fixup: added completion_event to icmp_send_echo_params"
            (( _fixups_applied++ )) || true
        fi
    fi
    _nsi_device="${WINE_SOURCE_DIR}/dlls/nsiproxy.sys/device.c"
    if [ -f "$_nsi_device" ]; then
        # Fix handle reference and add completion_event to params
        sed -i 's/params\.handle = &handle;/params.handle = \&data->handle;\n    params.completion_event = data->completion_event;/' "$_nsi_device"
        # Remove irp_set_icmp_handle call (function doesn't exist, handle already stored in data struct)
        sed -i '/irp_set_icmp_handle/d' "$_nsi_device"
        # Fix bare listen_thread_proc references (not the function definition which is already icmp_listen_thread_proc)
        sed -i 's/RtlQueueWorkItem( listen_thread_proc/RtlQueueWorkItem( icmp_listen_thread_proc/' "$_nsi_device"
        ok "Fixup: fixed device.c handle, completion_event, listen_thread_proc refs"
        (( _fixups_applied++ )) || true
    fi

    # Fix 9h00: Create inkobj.idl (patches add Makefile.in reference but not the file)
    _inkobj_idl="${WINE_SOURCE_DIR}/dlls/inkobj/inkobj.idl"
    if grep -q 'inkobj.idl' "${WINE_SOURCE_DIR}/dlls/inkobj/Makefile.in" 2>/dev/null && \
       ! grep -q 'library INKOBJLib' "$_inkobj_idl" 2>/dev/null; then
        cat > "$_inkobj_idl" << 'IDLEOF'
#pragma makedep regtypelib

import "oaidl.idl";

[
    uuid(7de4bb86-0b7d-4bb0-99e8-1b2ff3b06c66),
    version(1.0),
    helpstring("Microsoft Tablet PC Type Library")
]
library INKOBJLib
{
    importlib("stdole2.tlb");
}
IDLEOF
        ok "Fixup: created inkobj.idl (minimal typelib)"
        (( _fixups_applied++ )) || true
    fi

    # Fix 9h0: Create wine/heap.h stub (removed upstream, still used by some patches)
    _heap_h="${WINE_SOURCE_DIR}/include/wine/heap.h"
    if [ ! -f "$_heap_h" ] && grep -rq 'wine/heap.h' "${WINE_SOURCE_DIR}/dlls/" 2>/dev/null; then
        cat > "$_heap_h" << 'HEAPEOF'
/* Auto-generated stub — wine/heap.h was removed upstream */
#ifndef __WINE_WINE_HEAP_H
#define __WINE_WINE_HEAP_H

#include <stdlib.h>

static inline void *heap_alloc(size_t size) { return malloc(size); }
static inline void *heap_alloc_zero(size_t size) { return calloc(1, size); }
static inline void *heap_realloc(void *p, size_t size) { return realloc(p, size); }
static inline void heap_free(void *p) { free(p); }

#endif
HEAPEOF
        ok "Fixup: created wine/heap.h stub header"
        (( _fixups_applied++ )) || true
    fi
    _inc_makefile="${WINE_SOURCE_DIR}/include/Makefile.in"
    if [ -f "$_heap_h" ] && [ -f "$_inc_makefile" ] && ! grep -q 'wine/heap.h' "$_inc_makefile"; then
        sed -i '/wine\/glu\.h/a\\twine/heap.h \\' "$_inc_makefile"
        ok "Fixup: registered wine/heap.h in include/Makefile.in"
        (( _fixups_applied++ )) || true
    fi

    # Fix 9h: Add get/set_thread_layout server protocol + handlers + thread field
    _protocol_def="${WINE_SOURCE_DIR}/server/protocol.def"
    if [ -f "$_protocol_def" ] && ! grep -q 'get_thread_layout' "$_protocol_def"; then
        sed -i '/@REQ(set_user_input_time)/i\/* Get the keyboard layout for a thread */\n@REQ(get_thread_layout)\n    thread_id_t    tid;           /* id of thread */\n@REPLY\n    client_ptr_t   layout;        /* keyboard layout handle */\n@END\n\n\n/* Set the keyboard layout for a thread */\n@REQ(set_thread_layout)\n    thread_id_t    tid;           /* id of thread */\n    client_ptr_t   layout;        /* keyboard layout handle */\n@END\n\n' "$_protocol_def"
        ok "Fixup: added get/set_thread_layout to protocol.def"
        (( _fixups_applied++ )) || true
    fi
    # Only add handlers to queue.c if they don't already exist anywhere in server/
    _queue_c="${WINE_SOURCE_DIR}/server/queue.c"
    if [ -f "$_queue_c" ] && ! grep -rq 'DECL_HANDLER(get_thread_layout)' "${WINE_SOURCE_DIR}/server/"; then
        sed -i '/\/\* retrieve queue keyboard state/i\/* get the keyboard layout for a thread */\nDECL_HANDLER(get_thread_layout)\n{\n    struct thread *thread;\n    if (!(thread = get_thread_from_id( req->tid ))) return;\n    reply->layout = thread->layout;\n    release_object( thread );\n}\n\n\n/* set the keyboard layout for a thread */\nDECL_HANDLER(set_thread_layout)\n{\n    struct thread *thread;\n    if (!(thread = get_thread_from_id( req->tid ))) return;\n    thread->layout = req->layout;\n    release_object( thread );\n}\n\n' "$_queue_c"
        ok "Fixup: added get/set_thread_layout handlers to queue.c"
        (( _fixups_applied++ )) || true
    fi

    # Fix 9o: wow64/syscall.c — restore call_raise_user_exception_dispatcher removed by scanner
    _wow64_syscall="${WINE_SOURCE_DIR}/dlls/wow64/syscall.c"
    if [ -f "$_wow64_syscall" ]; then
        if grep -q 'call call_raise_user_exception_dispatcher' "$_wow64_syscall" && \
           ! grep -q 'static void.*call_raise_user_exception_dispatcher' "$_wow64_syscall"; then
            sed -i '/^\/\* based on RtlRaiseException/i\
/**********************************************************************\
 *           call_raise_user_exception_dispatcher\
 */\
static void __attribute__((used)) call_raise_user_exception_dispatcher( ULONG code )\
{\
    TEB32 *teb32 = (TEB32 *)((char *)NtCurrentTeb() + NtCurrentTeb()->WowTebOffset);\
\
    teb32->ExceptionCode = code;\
\
    switch (current_machine)\
    {\
    case IMAGE_FILE_MACHINE_I386:\
        {\
            I386_CONTEXT ctx = { CONTEXT_I386_ALL };\
\
            pBTCpuGetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );\
            ctx.Esp -= sizeof(ULONG);\
            *(ULONG *)ULongToPtr( ctx.Esp ) = ctx.Eip;\
            ctx.Eip = (ULONG_PTR)pKiRaiseUserExceptionDispatcher;\
            pBTCpuSetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );\
        }\
        break;\
\
    case IMAGE_FILE_MACHINE_ARMNT:\
        {\
            ARM_CONTEXT ctx = { CONTEXT_ARM_ALL };\
\
            pBTCpuGetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );\
            ctx.Pc = (ULONG_PTR)pKiRaiseUserExceptionDispatcher;\
            pBTCpuSetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );\
        }\
        break;\
    }\
}\
' "$_wow64_syscall"
            ok "Fixup: restored call_raise_user_exception_dispatcher in wow64/syscall.c"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 9p: wow64/system.c — add wow64___wine_needs_override_large_address_aware thunk
    _wow64_system="${WINE_SOURCE_DIR}/dlls/wow64/system.c"
    if [ -f "$_wow64_system" ]; then
        if ! grep -q 'wow64___wine_needs_override_large_address_aware' "$_wow64_system"; then
            cat >> "$_wow64_system" << 'WOWEOF'

BOOL WINAPI __wine_needs_override_large_address_aware(void);
NTSTATUS WINAPI wow64___wine_needs_override_large_address_aware( UINT *args )
{
    return __wine_needs_override_large_address_aware();
}
WOWEOF
            ok "Fixup: added wow64___wine_needs_override_large_address_aware thunk"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 9q: mfplat/network.c — MFNETSOURCE_STATISTICS_SERVICE GUID definition
    # EXTERN_GUID in mfidl.h declares it but doesn't define the value.
    # Remove our DEFINE_GUID and instead provide the value via the GUID struct directly,
    # placed after all includes so GUID_NULL etc. remain intact.
    _mfplat_net="${WINE_SOURCE_DIR}/dlls/mfplat/network.c"
    if [ -f "$_mfplat_net" ]; then
        # Remove any previous fixup attempts
        sed -i '/DEFINE_GUID(MFNETSOURCE_STATISTICS_SERVICE/d' "$_mfplat_net"
        sed -i '/static const GUID MFNETSOURCE_STATISTICS_SERVICE/d' "$_mfplat_net"
        sed -i '/#include <initguid.h>/d' "$_mfplat_net"
        # Add the GUID value after the debug channel line (after all includes)
        if grep -q 'MFNETSOURCE_STATISTICS_SERVICE' "$_mfplat_net" && \
           ! grep -q 'const GUID MFNETSOURCE_STATISTICS_SERVICE' "$_mfplat_net"; then
            sed -i '/WINE_DEFAULT_DEBUG_CHANNEL/a\\nconst GUID MFNETSOURCE_STATISTICS_SERVICE = {0x3cb1f28e, 0x0505, 0x4c5d, {0xae, 0x71, 0x0a, 0x55, 0x63, 0x44, 0xef, 0xa1}};' "$_mfplat_net"
            ok "Fixup: defined MFNETSOURCE_STATISTICS_SERVICE GUID in mfplat/network.c"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 9r: ntdll/threadpool.c — spec exports TpSetTimerEx but patch only changed TpSetTimer's body
    _tp_c="${WINE_SOURCE_DIR}/dlls/ntdll/threadpool.c"
    if [ -f "$_tp_c" ] && grep -q 'TpSetTimerEx' "${WINE_SOURCE_DIR}/dlls/ntdll/ntdll.spec" && \
       ! grep -q 'TpSetTimerEx' "$_tp_c"; then
        python3 - "$_tp_c" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f: t = f.read()
anchor = "/***********************************************************************\n *           TpSetWait    (NTDLL.@)"
shim = """/***********************************************************************
 *           TpSetTimerEx    (NTDLL.@)
 */
BOOL WINAPI TpSetTimerEx( TP_TIMER *timer, LARGE_INTEGER *timeout, LONG period, LONG window_length )
{
    return TpSetTimer( timer, timeout, period, window_length );
}

"""
t = t.replace(anchor, shim + anchor, 1)
with open(path, 'w') as f: f.write(t)
PYEOF
        ok "Fixup: added TpSetTimerEx to ntdll/threadpool.c"
        (( _fixups_applied++ )) || true
    fi

    # Fix 9s: odbc32/proxyodbc.c — patch calls driver_ansi_only() which never landed; use existing is_ansi_driver()
    _odbc_c="${WINE_SOURCE_DIR}/dlls/odbc32/proxyodbc.c"
    if [ -f "$_odbc_c" ] && grep -q 'driver_ansi_only(stmt->hdr.win32_funcs)' "$_odbc_c"; then
        sed -i 's/driver_ansi_only(stmt->hdr.win32_funcs)/is_ansi_driver(\&stmt->hdr)/' "$_odbc_c"
        ok "Fixup: replaced driver_ansi_only with is_ansi_driver in odbc32/proxyodbc.c"
        (( _fixups_applied++ )) || true
    fi

    # Fix 9u: inseng — GetICifFileFromFile called without prototype (stdcall decoration mismatch on i386)
    _inseng_priv="${WINE_SOURCE_DIR}/dlls/inseng/inseng_private.h"
    if [ -f "$_inseng_priv" ] && ! grep -q 'GetICifFileFromFile' "$_inseng_priv"; then
        sed -i 's|^char \*component_get_id(ICifComponent \*iface);$|&\n\nHRESULT WINAPI GetICifFileFromFile(ICifFile **icif, const char *path);|' "$_inseng_priv"
        ok "Fixup: added GetICifFileFromFile prototype to inseng_private.h"
        (( _fixups_applied++ )) || true
    fi

    # Fix 9v: sechost/service.c — make BEService fake-handle hack universal instead of ARK-only
    _sechost_svc="${WINE_SOURCE_DIR}/dlls/sechost/service.c"
    if [ -f "$_sechost_svc" ] && grep -q "346110" "$_sechost_svc"; then
        # OpenServiceW hack: remove SteamGameId check, keep BEService name check
        sed -i 's|if(GetEnvironmentVariableA("SteamGameId", str, sizeof(str)) && !strcmp(str, "346110") &&|if(|' "$_sechost_svc"
        sed -i 's|        !wcscmp(name, L"BEService"))|!wcscmp(name, L"BEService"))|' "$_sechost_svc"
        sed -i 's|HACK for ARK: Survivial Evolved checking|HACK (Mythix): any game checking|g' "$_sechost_svc"
        # QueryServiceStatusEx hack: remove SteamGameId check, keep deadbeef handle check
        sed -i 's|if(GetEnvironmentVariableA("SteamGameId", str, sizeof(str)) && !strcmp(str, "346110") &&|if(|' "$_sechost_svc"
        sed -i 's|        service == (void \*)0xdeadbeef)|service == (void *)0xdeadbeef)|' "$_sechost_svc"
        ok "Fixup: made BEService fake-handle hack universal in sechost/service.c"
        (( _fixups_applied++ )) || true
    fi

    # Fix 9t: kernel32/heap.c — static !_WIN64 impl conflicts with unguarded extern WINAPI decl on i386
    _k32_heap="${WINE_SOURCE_DIR}/dlls/kernel32/heap.c"
    if [ -f "$_k32_heap" ] && grep -q '^extern BOOL WINAPI __wine_needs_override_large_address_aware(void);' "$_k32_heap"; then
        python3 - "$_k32_heap" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f: t = f.read()
old = "\nextern BOOL WINAPI __wine_needs_override_large_address_aware(void);\n"
new = "\n#ifdef _WIN64\nextern BOOL WINAPI __wine_needs_override_large_address_aware(void);\n#endif\n"
if old in t and "#ifdef _WIN64\nextern BOOL WINAPI __wine_needs_override" not in t:
    with open(path, 'w') as f: f.write(t.replace(old, new, 1))
PYEOF
        ok "Fixup: guarded __wine_needs_override_large_address_aware extern in kernel32/heap.c"
        (( _fixups_applied++ )) || true
    fi

    # Fix 9n: windowscodecs/metadatahandler.c missing bytesread declaration
    _wic_meta="${WINE_SOURCE_DIR}/dlls/windowscodecs/metadatahandler.c"
    if [ -f "$_wic_meta" ] && grep -q 'bytesread' "$_wic_meta"; then
        if grep -q 'ULONG count, value, i;' "$_wic_meta"; then
            sed -i 's/ULONG count, value, i;/ULONG count, value, i, bytesread;/' "$_wic_meta"
            ok "Fixup: added bytesread declaration to metadatahandler.c"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 9m: opengl32/unixlib.h duplicate struct definitions (generated file, patch merge artifact)
    _gl_unixlib="${WINE_SOURCE_DIR}/dlls/opengl32/unixlib.h"
    if [ -f "$_gl_unixlib" ]; then
        _dup=$(grep -c 'struct wglShareLists_params' "$_gl_unixlib" 2>/dev/null || true)
        if [ "$_dup" -gt 1 ]; then
            python3 -c "
import re
with open('$_gl_unixlib') as f: t = f.read()
seen = set()
def dedup(m):
    name = m.group(1)
    if name in seen: return ''
    seen.add(name)
    return m.group(0)
t = re.sub(r'(struct \w+_params)\n\{[^}]*\};\n\n?', dedup, t)
with open('$_gl_unixlib','w') as f: f.write(t)
"
            ok "Fixup: deduplicated opengl32/unixlib.h struct definitions"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 9l: inseng.idl missing interface definitions (Wine-Staging patches add icif.c but not the IDL)
    _inseng_idl="${WINE_SOURCE_DIR}/include/inseng.idl"
    if [ -f "$_inseng_idl" ] && grep -q 'FIXME: Add full declarations' "$_inseng_idl"; then
        python3 -c "
with open('$_inseng_idl') as f: t = f.read()
old = '''/* FIXME: Add full declarations. */
interface ICifComponent;
interface IEnumCifComponents;
interface ICifGroup;
interface IEnumCifGroups;
interface ICifMode;
interface IEnumCifModes;'''
new = '''interface ICifComponent;
interface IEnumCifComponents;
interface ICifGroup;
interface IEnumCifGroups;
interface ICifMode;
interface IEnumCifModes;
interface ICifRWFile;

typedef enum {
    ActionNone = 0,
    ActionInstall = 1,
} InstallAction;

typedef enum {
    INSTALLSTATUS_INITIALIZING = 0,
    INSTALLSTATUS_DOWNLOADING = 1,
    INSTALLSTATUS_CHECKINGTRUST = 2,
    INSTALLSTATUS_DOWNLOADFINISHED = 3,
    INSTALLSTATUS_INSTALLING = 4,
} InstallStatus;

typedef enum {
    ENGINESTATUS_NOTREADY = 0,
    ENGINESTATUS_LOADING = 1,
    ENGINESTATUS_READY = 2,
    ENGINESTATUS_INSTALLING = 3,
} EngineStatus;

typedef enum {
    ENGINEPROBLEM_DOWNLOADFAIL = 0,
} EngineProblem;

cpp_quote(\"#define PLATFORM_ALL       0xffffffff\")
cpp_quote(\"#define PLATFORM_WIN98     0x00000001\")
cpp_quote(\"#define PLATFORM_NT4       0x00000002\")
cpp_quote(\"#define PLATFORM_NT5       0x00000004\")
cpp_quote(\"#define PLATFORM_MILLEN    0x00000008\")
cpp_quote(\"#define URLF_RELATIVEURL   0x00000001\")
cpp_quote(\"#define MAX_ID_LENGTH      128\")
cpp_quote(\"#define MAX_DISPLAYNAME_LENGTH  256\")

typedef struct {
    DWORD dwDownloadKBRemaining;
    DWORD dwInstallKBRemaining;
    DWORD dwDownloadSecsRemaining;
    DWORD dwInstallSecsRemaining;
} INSTALLPROGRESS;

cpp_quote(\"typedef struct ICifComponent ICifComponent;\")
cpp_quote(\"typedef struct ICifComponentVtbl {\")
cpp_quote(\"    HRESULT (WINAPI *GetID)(ICifComponent*,char*,DWORD);\")
cpp_quote(\"    HRESULT (WINAPI *GetGUID)(ICifComponent*,char*,DWORD);\")
cpp_quote(\"    HRESULT (WINAPI *GetDescription)(ICifComponent*,char*,DWORD);\")
cpp_quote(\"    HRESULT (WINAPI *GetDetails)(ICifComponent*,char*,DWORD);\")
cpp_quote(\"    HRESULT (WINAPI *GetUrl)(ICifComponent*,UINT,char*,DWORD,DWORD*);\")
cpp_quote(\"    HRESULT (WINAPI *GetFileExtractList)(ICifComponent*,UINT,char*,DWORD);\")
cpp_quote(\"    HRESULT (WINAPI *GetUrlCheckRange)(ICifComponent*,UINT,DWORD*,DWORD*);\")
cpp_quote(\"    HRESULT (WINAPI *GetCommand)(ICifComponent*,UINT,char*,DWORD,char*,DWORD,DWORD*);\")
cpp_quote(\"    HRESULT (WINAPI *GetVersion)(ICifComponent*,DWORD*,DWORD*);\")
cpp_quote(\"    HRESULT (WINAPI *GetLocale)(ICifComponent*,char*,DWORD);\")
cpp_quote(\"    HRESULT (WINAPI *GetUninstallKey)(ICifComponent*,char*,DWORD);\")
cpp_quote(\"    HRESULT (WINAPI *GetInstalledSize)(ICifComponent*,DWORD*,DWORD*);\")
cpp_quote(\"    DWORD   (WINAPI *GetDownloadSize)(ICifComponent*);\")
cpp_quote(\"    DWORD   (WINAPI *GetExtractSize)(ICifComponent*);\")
cpp_quote(\"    HRESULT (WINAPI *GetSuccessKey)(ICifComponent*,char*,DWORD);\")
cpp_quote(\"    HRESULT (WINAPI *GetProgressKeys)(ICifComponent*,char*,DWORD,char*,DWORD);\")
cpp_quote(\"    HRESULT (WINAPI *IsActiveSetupAware)(ICifComponent*);\")
cpp_quote(\"    HRESULT (WINAPI *IsRebootRequired)(ICifComponent*);\")
cpp_quote(\"    HRESULT (WINAPI *RequiresAdminRights)(ICifComponent*);\")
cpp_quote(\"    DWORD   (WINAPI *GetPriority)(ICifComponent*);\")
cpp_quote(\"    HRESULT (WINAPI *GetDependency)(ICifComponent*,UINT,char*,DWORD,char*,DWORD*,DWORD*);\")
cpp_quote(\"    DWORD   (WINAPI *GetPlatform)(ICifComponent*);\")
cpp_quote(\"    HRESULT (WINAPI *GetMode)(ICifComponent*,UINT,char*,DWORD);\")
cpp_quote(\"    HRESULT (WINAPI *GetGroup)(ICifComponent*,char*,DWORD);\")
cpp_quote(\"    HRESULT (WINAPI *IsUIVisible)(ICifComponent*);\")
cpp_quote(\"    HRESULT (WINAPI *GetPatchID)(ICifComponent*,char*,DWORD);\")
cpp_quote(\"    HRESULT (WINAPI *GetDetVersion)(ICifComponent*,char*,DWORD,char*,DWORD);\")
cpp_quote(\"    HRESULT (WINAPI *GetTreatAsOneComponents)(ICifComponent*,UINT,char*,DWORD);\")
cpp_quote(\"    HRESULT (WINAPI *GetCustomData)(ICifComponent*,char*,char*,DWORD);\")
cpp_quote(\"    DWORD   (WINAPI *IsComponentInstalled)(ICifComponent*);\")
cpp_quote(\"    HRESULT (WINAPI *IsComponentDownloaded)(ICifComponent*);\")
cpp_quote(\"    DWORD   (WINAPI *IsThisVersionInstalled)(ICifComponent*,DWORD,DWORD,DWORD*,DWORD*);\")
cpp_quote(\"    DWORD   (WINAPI *GetInstallQueueState)(ICifComponent*);\")
cpp_quote(\"    HRESULT (WINAPI *SetInstallQueueState)(ICifComponent*,DWORD);\")
cpp_quote(\"    DWORD   (WINAPI *GetActualDownloadSize)(ICifComponent*);\")
cpp_quote(\"    DWORD   (WINAPI *GetCurrentPriority)(ICifComponent*);\")
cpp_quote(\"    HRESULT (WINAPI *SetCurrentPriority)(ICifComponent*,DWORD);\")
cpp_quote(\"} ICifComponentVtbl;\")
cpp_quote(\"struct ICifComponent { const ICifComponentVtbl *lpVtbl; };\")
cpp_quote(\"#define ICifComponent_GetID(p,a,b) (p)->lpVtbl->GetID(p,a,b)\")
cpp_quote(\"#define ICifComponent_GetDescription(p,a,b) (p)->lpVtbl->GetDescription(p,a,b)\")
cpp_quote(\"#define ICifComponent_GetUrl(p,a,b,c,d) (p)->lpVtbl->GetUrl(p,a,b,c,d)\")
cpp_quote(\"#define ICifComponent_GetVersion(p,a,b) (p)->lpVtbl->GetVersion(p,a,b)\")
cpp_quote(\"#define ICifComponent_GetInstalledSize(p,a,b) (p)->lpVtbl->GetInstalledSize(p,a,b)\")
cpp_quote(\"#define ICifComponent_GetDownloadSize(p) (p)->lpVtbl->GetDownloadSize(p)\")
cpp_quote(\"#define ICifComponent_GetDependency(p,a,b,c,d,e,f) (p)->lpVtbl->GetDependency(p,a,b,c,d,e,f)\")
cpp_quote(\"#define ICifComponent_IsComponentInstalled(p) (p)->lpVtbl->IsComponentInstalled(p)\")
cpp_quote(\"#define ICifComponent_IsComponentDownloaded(p) (p)->lpVtbl->IsComponentDownloaded(p)\")
cpp_quote(\"#define ICifComponent_GetInstallQueueState(p) (p)->lpVtbl->GetInstallQueueState(p)\")
cpp_quote(\"#define ICifComponent_SetInstallQueueState(p,a) (p)->lpVtbl->SetInstallQueueState(p,a)\")
cpp_quote(\"#define ICifComponent_SetCurrentPriority(p,a) (p)->lpVtbl->SetCurrentPriority(p,a)\")

cpp_quote(\"typedef struct IEnumCifComponents IEnumCifComponents;\")
cpp_quote(\"typedef struct IEnumCifComponentsVtbl {\")
cpp_quote(\"    HRESULT (WINAPI *QueryInterface)(IEnumCifComponents*,REFIID,void**);\")
cpp_quote(\"    ULONG   (WINAPI *AddRef)(IEnumCifComponents*);\")
cpp_quote(\"    ULONG   (WINAPI *Release)(IEnumCifComponents*);\")
cpp_quote(\"    HRESULT (WINAPI *Next)(IEnumCifComponents*,ICifComponent**);\")
cpp_quote(\"    HRESULT (WINAPI *Reset)(IEnumCifComponents*);\")
cpp_quote(\"} IEnumCifComponentsVtbl;\")
cpp_quote(\"struct IEnumCifComponents { const IEnumCifComponentsVtbl *lpVtbl; };\")
cpp_quote(\"#define IEnumCifComponents_Next(p,a) (p)->lpVtbl->Next(p,a)\")
cpp_quote(\"#define IEnumCifComponents_Reset(p) (p)->lpVtbl->Reset(p)\")
cpp_quote(\"#define IEnumCifComponents_Release(p) (p)->lpVtbl->Release(p)\")

cpp_quote(\"typedef struct ICifGroup ICifGroup;\")
cpp_quote(\"typedef struct ICifGroupVtbl {\")
cpp_quote(\"    HRESULT (WINAPI *GetID)(ICifGroup*,char*,DWORD);\")
cpp_quote(\"    HRESULT (WINAPI *GetDescription)(ICifGroup*,char*,DWORD);\")
cpp_quote(\"    DWORD   (WINAPI *GetPriority)(ICifGroup*);\")
cpp_quote(\"    HRESULT (WINAPI *EnumComponents)(ICifGroup*,IEnumCifComponents**,DWORD,void*);\")
cpp_quote(\"    DWORD   (WINAPI *GetCurrentPriority)(ICifGroup*);\")
cpp_quote(\"} ICifGroupVtbl;\")
cpp_quote(\"struct ICifGroup { const ICifGroupVtbl *lpVtbl; };\")

cpp_quote(\"typedef struct IEnumCifGroups IEnumCifGroups;\")
cpp_quote(\"typedef struct IEnumCifGroupsVtbl {\")
cpp_quote(\"    HRESULT (WINAPI *QueryInterface)(IEnumCifGroups*,REFIID,void**);\")
cpp_quote(\"    ULONG   (WINAPI *AddRef)(IEnumCifGroups*);\")
cpp_quote(\"    ULONG   (WINAPI *Release)(IEnumCifGroups*);\")
cpp_quote(\"    HRESULT (WINAPI *Next)(IEnumCifGroups*,ICifGroup**);\")
cpp_quote(\"    HRESULT (WINAPI *Reset)(IEnumCifGroups*);\")
cpp_quote(\"} IEnumCifGroupsVtbl;\")
cpp_quote(\"struct IEnumCifGroups { const IEnumCifGroupsVtbl *lpVtbl; };\")

cpp_quote(\"typedef struct IInstallEngineTiming IInstallEngineTiming;\")
cpp_quote(\"typedef struct IInstallEngineTimingVtbl {\")
cpp_quote(\"    HRESULT (WINAPI *QueryInterface)(IInstallEngineTiming*,REFIID,void**);\")
cpp_quote(\"    ULONG   (WINAPI *AddRef)(IInstallEngineTiming*);\")
cpp_quote(\"    ULONG   (WINAPI *Release)(IInstallEngineTiming*);\")
cpp_quote(\"    HRESULT (WINAPI *GetRates)(IInstallEngineTiming*,DWORD*,DWORD*);\")
cpp_quote(\"    HRESULT (WINAPI *GetInstallProgress)(IInstallEngineTiming*,INSTALLPROGRESS*);\")
cpp_quote(\"} IInstallEngineTimingVtbl;\")
cpp_quote(\"struct IInstallEngineTiming { const IInstallEngineTimingVtbl *lpVtbl; };\")
cpp_quote(\"#define IID_IInstallEngineTiming IID_NULL\")'''
t = t.replace(old, new)
with open('$_inseng_idl','w') as f: f.write(t)
"
        # Delete stale generated header
        rm -f "${_DATA_DIR}/buildz/build-run/Mythix-Neutron/wine64/include/inseng.h" 2>/dev/null
        ok "Fixup: added full interface definitions to inseng.idl"
        (( _fixups_applied++ )) || true
    fi

    # Fix 9k: dsound duplicate normfunction member + duplicate f_to_* functions
    _dsound_priv="${WINE_SOURCE_DIR}/dlls/dsound/dsound_private.h"
    if [ -f "$_dsound_priv" ]; then
        _nf_count=$(grep -c 'normfunc normfunction;' "$_dsound_priv" 2>/dev/null || true)
        if [ "$_nf_count" -gt 1 ]; then
            sed -i '0,/normfunc normfunction;/{//!b;n;/normfunc normfunction;/d}' "$_dsound_priv"
            # fallback: just deduplicate the line
            if [ "$(grep -c 'normfunc normfunction;' "$_dsound_priv")" -gt 1 ]; then
                python3 -c "
with open('$_dsound_priv') as f: lines = f.readlines()
seen = False; out = []
for l in lines:
    if 'normfunc normfunction;' in l:
        if seen: continue
        seen = True
    out.append(l)
with open('$_dsound_priv','w') as f: f.writelines(out)
"
            fi
            ok "Fixup: removed duplicate normfunction member in dsound_private.h"
            (( _fixups_applied++ )) || true
        fi
    fi
    _dsound_conv="${WINE_SOURCE_DIR}/dlls/dsound/dsound_convert.c"
    if [ -f "$_dsound_conv" ]; then
        _f8_count=$(grep -c 'static inline.*f_to_8' "$_dsound_conv" 2>/dev/null || true)
        if [ "$_f8_count" -gt 1 ]; then
            # Find the line number of the second f_to_32 definition (end of first block)
            # then delete everything from the second f_to_8 definition to just before putieee32
            _second_f8=$(grep -n 'static inline.*f_to_8' "$_dsound_conv" | tail -1 | cut -d: -f1)
            _putieee=$(grep -n '^void putieee32' "$_dsound_conv" | head -1 | cut -d: -f1)
            if [ -n "$_second_f8" ] && [ -n "$_putieee" ] && [ "$_second_f8" -lt "$_putieee" ]; then
                sed -i "${_second_f8},$((_putieee - 1))d" "$_dsound_conv"
            fi
            ok "Fixup: removed duplicate f_to_* functions in dsound_convert.c"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 9j: Duplicate enum/struct in d3dcompiler_43/reflection.c
    _d3drefl="${WINE_SOURCE_DIR}/dlls/d3dcompiler_43/reflection.c"
    if [ -f "$_d3drefl" ]; then
        _dup_count=$(grep -c 'enum d3dcompiler_shader_type' "$_d3drefl" 2>/dev/null || true)
        if [ "$_dup_count" -gt 1 ]; then
            # Remove second copy of enum + struct block (lines after first struct closing)
            python3 -c "
import re
with open('$_d3drefl') as f: t = f.read()
pat = r'\nenum d3dcompiler_shader_type\n\{\n    D3DCOMPILER_SHADER_TYPE_CS = 5,\n\};\n\nstruct d3dcompiler_shader_signature\n\{[^}]*\};\n'
m = list(re.finditer(pat, t))
if len(m) > 1:
    t = t[:m[1].start()] + '\n' + t[m[1].end():]
with open('$_d3drefl','w') as f: f.write(t)
"
            ok "Fixup: removed duplicate enum/struct in d3dcompiler_43/reflection.c"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 9i: Duplicate KMTQAITYPE_WDDM_2_7_CAPS case in d3dkmt.c
    _d3dkmt="${WINE_SOURCE_DIR}/dlls/win32u/d3dkmt.c"
    if [ -f "$_d3dkmt" ]; then
        _case_count=$(grep -c 'case KMTQAITYPE_WDDM_2_7_CAPS:' "$_d3dkmt" 2>/dev/null | tail -1 || echo 0)
        if [ "$_case_count" -ge 2 ]; then
            python3 -c "
import sys
with open(sys.argv[1]) as f:
    lines = f.readlines()
# Find first 'case KMTQAITYPE_WDDM_2_7_CAPS:' and remove it through 'break;'
for i, l in enumerate(lines):
    if 'case KMTQAITYPE_WDDM_2_7_CAPS:' in l:
        # Find the break; ending this case
        end = i
        for j in range(i+1, min(i+25, len(lines))):
            if lines[j].strip() == 'break;':
                end = j + 1
                break
        # Remove lines i through end, plus any trailing blank lines
        while end < len(lines) and lines[end].strip() == '':
            end += 1
        del lines[i:end]
        with open(sys.argv[1], 'w') as f:
            f.writelines(lines)
        print(f'Removed first duplicate WDDM_2_7_CAPS case')
        break
" "$_d3dkmt" && {
                ok "Fixup: removed duplicate WDDM_2_7_CAPS case in d3dkmt.c"
                (( _fixups_applied++ )) || true
            }
        fi
    fi

    # Fix 10: mathf.c orphaned #endif from TkG merge removing outer #if defined(__i386__)
    _mathf="${WINE_SOURCE_DIR}/dlls/msvcrt/mathf.c"
    if [ -f "$_mathf" ]; then
        # Pattern: #endif followed immediately by #endif with no matching #if between them
        # The outer #if was removed by TkG but its #endif remains
        _orphan=$(awk '
            /^#if/ { depth++ }
            /^#endif/ {
                if (depth > 0) { depth-- }
                else { print NR; exit }
            }
        ' "$_mathf")
        if [ -n "$_orphan" ]; then
            sed -i "${_orphan}d" "$_mathf"
            ok "Fixup: removed orphaned #endif at line ${_orphan} in mathf.c"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 11: TpSetTimer signature mismatch — bleeding-edge returns VOID, TkG body uses BOOL
    _threadpool_c="${WINE_SOURCE_DIR}/dlls/ntdll/threadpool.c"
    if [ -f "$_threadpool_c" ] && grep -q 'VOID WINAPI TpSetTimer' "$_threadpool_c" && \
       grep -q 'timer_previously_set' "$_threadpool_c"; then
        sed -i 's/^VOID WINAPI TpSetTimer/BOOL WINAPI TpSetTimer/' "$_threadpool_c"
        sed -i '/BOOL WINAPI TpSetTimer/,/^{/{/^{/a\    BOOL timer_previously_set = FALSE;
        }' "$_threadpool_c"
        # Also update the header declaration
        _winternl="${WINE_SOURCE_DIR}/include/winternl.h"
        if [ -f "$_winternl" ]; then
            sed -i 's/NTSYSAPI void      WINAPI TpSetTimer/NTSYSAPI BOOL      WINAPI TpSetTimer/' "$_winternl"
        fi
        ok "Fixup: TpSetTimer VOID→BOOL + added timer_previously_set declaration"
        (( _fixups_applied++ )) || true
    fi

    # Fix 11: Missing headers from incomplete staging patches
    # Staging adds DLL stubs that reference headers not in bleeding-edge.
    # Must create the stub AND register it in include/Makefile.in (makedep
    # only resolves headers listed in SOURCES).
    _missing_headers=( rtscom )
    for _mod in "${_missing_headers[@]}"; do
        _hdr="${_mod}.h"
        _hdr_file="${WINE_SOURCE_DIR}/include/${_hdr}"
        _makefile_in="${WINE_SOURCE_DIR}/include/Makefile.in"
        if [ -d "${WINE_SOURCE_DIR}/dlls/${_mod}" ] && [ ! -f "${WINE_SOURCE_DIR}/include/${_mod}.idl" ]; then
            if [ ! -f "$_hdr_file" ]; then
                printf "/* Auto-generated stub (mythix-wine fixup) */\n" > "$_hdr_file"
            fi
            # Add to include/Makefile.in SOURCES list (after rtlsupportapi.h)
            if [ -f "$_makefile_in" ] && ! grep -q "	${_hdr}" "$_makefile_in"; then
                sed -i "/	rtlsupportapi\.h/a\\	${_hdr} \\\\" "$_makefile_in"
            fi
            ok "Fixup: created stub include/${_hdr} + registered in Makefile.in"
            (( _fixups_applied++ )) || true
        fi
    done

    # Fix 12: server/thread.h missing 'layout' member for TkG keyboard layout patch
    # TkG adds get_thread_layout/set_thread_layout handlers in queue.c that read/write
    # thread->layout, but bleeding-edge struct thread doesn't have the field.
    _thread_h="${WINE_SOURCE_DIR}/server/thread.h"
    if [ -f "$_thread_h" ] && grep -q 'thread->layout' "${WINE_SOURCE_DIR}/server/queue.c" 2>/dev/null && ! grep -q 'client_ptr_t.*layout' "$_thread_h"; then
        sed -i '/exit_poll;/a\    client_ptr_t           layout;        /* keyboard layout handle */' "$_thread_h"
        ok "Fixup: added missing 'layout' member to struct thread (TkG keyboard layout patch)"
        (( _fixups_applied++ )) || true
    fi

    # Fix 13: ntdll.spec duplicate wine_nt_to_unix_file_name export
    # TkG merge leaves a compat shim entry alongside the bleeding-edge -syscall version.
    _ntdll_spec="${WINE_SOURCE_DIR}/dlls/ntdll/ntdll.spec"
    if [ -f "$_ntdll_spec" ]; then
        _dup_count=$(grep -c 'wine_nt_to_unix_file_name' "$_ntdll_spec" 2>/dev/null || echo 0)
        if [ "$_dup_count" -ge 2 ]; then
            sed -i '/wine_nt_to_unix_file_name.*compat_wine_nt_to_unix_file_name/d' "$_ntdll_spec"
            ok "Fixup: removed duplicate wine_nt_to_unix_file_name compat shim from ntdll.spec"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 14: WIN_IS_IN_ACTIVATION missing from ntuser_private.h
    # TkG activation patch uses this flag but bleeding-edge doesn't define it.
    # TkG used 0x0100 but bleeding-edge already uses that for WIN_IS_TOUCH, so use 0x0200.
    _ntuser_priv="${WINE_SOURCE_DIR}/dlls/win32u/ntuser_private.h"
    if [ -f "$_ntuser_priv" ] && grep -q 'WIN_IS_IN_ACTIVATION' "${WINE_SOURCE_DIR}/dlls/win32u/input.c" 2>/dev/null && ! grep -q 'WIN_IS_IN_ACTIVATION' "$_ntuser_priv"; then
        sed -i '/WIN_IS_TOUCH/a#define WIN_IS_IN_ACTIVATION      0x0200 /* the window is in an activation process */' "$_ntuser_priv"
        ok "Fixup: added WIN_IS_IN_ACTIVATION (0x0200) to ntuser_private.h"
        (( _fixups_applied++ )) || true
    fi

    # Fix 15: nsiproxy icmp_echo.c set_socket_opts call signature mismatch
    # Bleeding-edge changed set_socket_opts to (struct icmp_socket *s) only,
    # but a stale call site passes (data, params) — two args, wrong type.
    _icmp_echo="${WINE_SOURCE_DIR}/dlls/nsiproxy.sys/icmp_echo.c"
    if [ -f "$_icmp_echo" ] && grep -q 'set_socket_opts( data, params )' "$_icmp_echo"; then
        sed -i 's/set_socket_opts( data, params )/set_socket_opts( data->s )/' "$_icmp_echo"
        ok "Fixup: nsiproxy set_socket_opts call signature (data,params → data->s)"
        (( _fixups_applied++ )) || true
    fi

    # Fix 16: sechost/service.c duplicate 'char str[64]' declarations
    # TkG BattlEye hack inserts 'char str[64]' but bleeding-edge already has it,
    # causing "redeclaration of 'str' with no linkage" in OpenServiceW and QueryServiceStatusEx.
    _sechost_svc="${WINE_SOURCE_DIR}/dlls/sechost/service.c"
    if [ -f "$_sechost_svc" ] && grep -cP '^\s+char str\[64\];' "$_sechost_svc" | grep -q '[3-9]\|[0-9][0-9]'; then
        awk '!seen[$0]++ || !/^[[:space:]]+char str\[64\];/' "$_sechost_svc" > "${_sechost_svc}.tmp" && \
            mv "${_sechost_svc}.tmp" "$_sechost_svc"
        ok "Fixup: removed duplicate 'char str[64]' in sechost/service.c"
        (( _fixups_applied++ )) || true
    fi

    # Fix 17: shell32 empty placeholder bitmaps cause wrc segfault
    # TkG/Staging patches add ietoolbar.bmp references to shell32.rc but create
    # empty 0-byte placeholder files. wrc dereferences NULL data and segfaults.
    _shell32_res="${WINE_SOURCE_DIR}/dlls/shell32/resources"
    for _bmp in ietoolbar.bmp ietoolbar_small.bmp; do
        if [ -f "$_shell32_res/$_bmp" ] && [ ! -s "$_shell32_res/$_bmp" ]; then
            python3 -c "
import struct
bmp  = b'BM' + struct.pack('<I',58) + struct.pack('<HH',0,0) + struct.pack('<I',54)
bmp += struct.pack('<I',40) + struct.pack('<ii',1,1) + struct.pack('<HH',1,24)
bmp += struct.pack('<I',0) + struct.pack('<I',4) + struct.pack('<ii',2835,2835) + struct.pack('<II',0,0)
bmp += b'\xff\xff\xff\x00'
open('$_shell32_res/$_bmp','wb').write(bmp)
"
            (( _fixups_applied++ )) || true
        fi
    done
    [ -f "$_shell32_res/ietoolbar.bmp" ] && [ -s "$_shell32_res/ietoolbar.bmp" ] && \
        ok "Fixup: created valid placeholder BMPs for shell32 (wrc segfault fix)"

    # Fix 18: windows.ui/private.h missing windows.ui.input.h include
    # Bleeding-edge added radialcontroller.c which uses IRadialControllerConfigurationStaticsVtbl
    # but private.h never includes the generated windows.ui.input.h header.
    _winui_private="${WINE_SOURCE_DIR}/dlls/windows.ui/private.h"
    if [ -f "$_winui_private" ] && \
       [ -f "${WINE_SOURCE_DIR}/dlls/windows.ui/radialcontroller.c" ] && \
       ! grep -q 'windows.ui.input.h' "$_winui_private"; then
        sed -i '/#include "windows.ui.viewmanagement.h"/i #define WIDL_using_Windows_UI_Input\n#include "windows.ui.input.h"' "$_winui_private"
        if ! grep -q 'radialcontroller_factory' "$_winui_private"; then
            sed -i '/extern IActivationFactory \*inputpane_factory;/a extern IActivationFactory *radialcontroller_factory;\nextern IActivationFactory *radialcontrollerconfiguration_factory;\nextern IActivationFactory *radialcontrollermenuitem_factory;' "$_winui_private"
        fi
        ok "Fixup: added windows.ui.input.h include to windows.ui/private.h"
        (( _fixups_applied++ )) || true
    fi

    # Fix 19: vkd3d version mismatch — bleeding-edge syncs a newer vkd3d that
    # renames structs, drops enums, and changes APIs vs what TkG patches expect.
    # Replace the entire libs/vkd3d subtree with the TkG reference version.
    _vkd3d_src="${WINE_SOURCE_DIR}/libs/vkd3d"
    _vkd3d_ref="${SRC_ROOT}/wine-tkg-ref/libs/vkd3d"
    if [ -d "$_vkd3d_ref" ] && [ -d "$_vkd3d_src" ]; then
        _src_has="$(grep -c 'vsir_compile_info_init' "$_vkd3d_src/libs/vkd3d-shader/vkd3d_shader_private.h" 2>/dev/null; true)"
        _ref_has="$(grep -c 'vsir_compile_info_init' "$_vkd3d_ref/libs/vkd3d-shader/vkd3d_shader_private.h" 2>/dev/null; true)"
        if [ "$_src_has" -eq 0 ] && [ "$_ref_has" -gt 0 ]; then
            sudo rm -rf "$_vkd3d_src" 2>/dev/null || rm -rf "$_vkd3d_src"
            cp -a "$_vkd3d_ref" "$_vkd3d_src"
            # TkG vkd3d references spirv/unified1/ headers; create symlinks to vulkan/ equivalents
            mkdir -p "$_vkd3d_src/include/spirv/unified1"
            ln -sf ../../vulkan/spirv.h "$_vkd3d_src/include/spirv/unified1/spirv.h"
            ln -sf ../../vulkan/GLSL.std.450.h "$_vkd3d_src/include/spirv/unified1/GLSL.std.450.h"
            # makedep scans spirv-tools/libspirv.h past #ifdef HAVE_SPIRV_TOOLS; create stub
            mkdir -p "$_vkd3d_src/include/spirv-tools"
            echo "/* stub */" > "$_vkd3d_src/include/spirv-tools/libspirv.h"
            # Ensure user ownership so container root-owned leftovers don't block future runs
            chown -R "$(id -u):$(id -g)" "$_vkd3d_src" 2>/dev/null || true
            # Clear stale vkd3d build artifacts from previous runs
            _vkd3d_build="${BUILD_RUN_DIR}/${BUILD_NAME}/wine64/libs/vkd3d"
            [ -d "$_vkd3d_build" ] && { sudo rm -rf "$_vkd3d_build" 2>/dev/null || rm -rf "$_vkd3d_build"; }
            ok "Fixup: replaced libs/vkd3d with TkG-compatible version"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 21: vkd3d flex scanners use fprintf (PE link failure)
    # Flex-generated yy_fatal_error calls fprintf(stderr,...) which doesn't resolve
    # in PE builds. Override YY_FATAL_ERROR to use ERR()/abort() instead.
    for _lexfile in "$WINE_SOURCE_DIR"/libs/vkd3d/libs/vkd3d-shader/*.l; do
        [ -f "$_lexfile" ] || continue
        if ! grep -q 'YY_FATAL_ERROR' "$_lexfile"; then
            sed -i '/%{/a #define YY_FATAL_ERROR(msg) do { ERR("%s\\n", msg); abort(); } while(0)' "$_lexfile"
            (( _fixups_applied++ )) || true
        fi
    done
    grep -q 'YY_FATAL_ERROR' "$WINE_SOURCE_DIR/libs/vkd3d/libs/vkd3d-shader/hlsl.l" 2>/dev/null && \
        ok "Fixup: overrode YY_FATAL_ERROR in vkd3d flex scanners"

    # Fix 24: ir50_32 and iyuv_32 broken by TkG patches
    # TkG patches add $(FFMPEG_PE_LIBS), color_converter.c refs, and winedmo DELAYIMPORTS
    # that don't exist in the base branch. Revert these DLLs to base originals.
    _fixup_base_ref="mythix-base-clean"
    for _codec_dll in ir50_32 iyuv_32; do
        _codec_dir="${WINE_SOURCE_DIR}/dlls/${_codec_dll}"
        if [ -d "$_codec_dir" ] && grep -q 'FFMPEG_PE_LIBS\|color_converter\|DELAYIMPORTS.*winedmo' "$_codec_dir/Makefile.in" 2>/dev/null; then
            (cd "$WINE_SOURCE_DIR" && git show "${_fixup_base_ref}:dlls/${_codec_dll}/Makefile.in" > "dlls/${_codec_dll}/Makefile.in" 2>/dev/null)
            for _cf in "$_codec_dir/"*.c "$_codec_dir/"*.h "$_codec_dir/"*.spec; do
                [ -f "$_cf" ] && (cd "$WINE_SOURCE_DIR" && git show "${_fixup_base_ref}:dlls/${_codec_dll}/$(basename "$_cf")" > "dlls/${_codec_dll}/$(basename "$_cf")" 2>/dev/null) || true
            done
            ok "Fixup: reverted ${_codec_dll} to base (TkG patches broke it)"
            (( _fixups_applied++ )) || true
        fi
    done

    # Fix 26: loader64 duplicates loader in make install for 64-bit-only builds
    # Both loader/ and loader64/ try to install wine64 to the same path.
    # Remove INSTALL_LIB from loader64 so only loader/ handles the install.
    _loader64_mkin="${WINE_SOURCE_DIR}/loader64/Makefile.in"
    if [ -f "$_loader64_mkin" ] && grep -q '^INSTALL_LIB' "$_loader64_mkin"; then
        sed -i '/^INSTALL_LIB/d' "$_loader64_mkin"
        ok "Fixup: removed duplicate INSTALL_LIB from loader64"
        (( _fixups_applied++ )) || true
    fi

    # Fix 27: wine6464-preloader path doubling bug
    # TkG patches make get_alternate_wineloader return "wine64" on 32-bit,
    # but preloader_exec blindly appends "64-preloader" → "wine6464-preloader".
    # Fix: check if path already ends in "64" before appending.
    _ntdll_loader="${WINE_SOURCE_DIR}/dlls/ntdll/unix/loader.c"
    if [ -f "$_ntdll_loader" ] && grep -q '%s64-preloader' "$_ntdll_loader"; then
        sed -i '/machine == IMAGE_FILE_MACHINE_AMD64/,/asprintf.*%s64-preloader/{
            /asprintf.*%s64-preloader/c\
    {\
        size_t len = strlen( argv[1] );\
        if (len >= 2 \&\& !strcmp( argv[1] + len - 2, "64" ))\
            asprintf( \&argv[0], "%s-preloader", argv[1] );\
        else\
            asprintf( \&argv[0], "%s64-preloader", argv[1] );\
    }
        }' "$_ntdll_loader"
        ok "Fixup: fixed wine6464-preloader path doubling in ntdll loader"
        (( _fixups_applied++ )) || true
    fi

    # Fix 25: mmdevapi should_hide_from_endpoint_collection missing definition
    # GE/Staging patch calls this function but never defines it.
    _mmdev_devenum="${WINE_SOURCE_DIR}/dlls/mmdevapi/devenum.c"
    if [ -f "$_mmdev_devenum" ] && grep -q 'should_hide_from_endpoint_collection' "$_mmdev_devenum" && \
       ! grep -q 'static BOOL should_hide_from_endpoint_collection' "$_mmdev_devenum"; then
        sed -i '/static BOOL MMDevCol_device_visible/i \
static BOOL should_hide_from_endpoint_collection(MMDevice *dev)\
{\
    return FALSE;\
}\
' "$_mmdev_devenum"
        ok "Fixup: added should_hide_from_endpoint_collection stub in mmdevapi"
        (( _fixups_applied++ )) || true
    fi

    # Fix 23: wmvcore winedmo→winegstreamer rename mismatch
    # Bleeding-edge renamed winegstreamer_create_wm_sync_reader to winedmo_create_wm_sync_reader,
    # but TkG reverts winedmo back to winegstreamer. Fix wmvcore to call the old name.
    _wmvcore_dir="${WINE_SOURCE_DIR}/dlls/wmvcore"
    if [ -f "$_wmvcore_dir/wmvcore_private.h" ] && grep -q 'winedmo_create_wm_sync_reader' "$_wmvcore_dir/wmvcore_private.h"; then
        sed -i 's/winedmo_create_wm_sync_reader/winegstreamer_create_wm_sync_reader/g' \
            "$_wmvcore_dir/wmvcore_private.h" \
            "$_wmvcore_dir/wmvcore_main.c" \
            "$_wmvcore_dir/async_reader.c"
        sed -i 's/DELAYIMPORTS = winedmo/DELAYIMPORTS = winegstreamer/' "$_wmvcore_dir/Makefile.in"
        ok "Fixup: wmvcore winedmo→winegstreamer rename"
        (( _fixups_applied++ )) || true
    fi

    # Fix 22: vkd3d PE link failures — fstat and vfprintf not available in PE builds
    # TkG vkd3d uses POSIX fstat/vfprintf which don't link in Wine PE DLLs.
    _vkd3d_utils_h="${WINE_SOURCE_DIR}/libs/vkd3d/include/private/vkd3d_shader_utils.h"
    if [ -f "$_vkd3d_utils_h" ] && grep -q 'sys/stat\.h\|fstat\|fileno' "$_vkd3d_utils_h"; then
        sed -i '/#include <sys\/stat.h>/d' "$_vkd3d_utils_h"
        python3 -c "
import re, sys
f = sys.argv[1]
src = open(f).read()
# Replace the fstat-based vkd3d_shader_code_from_file with fread-based version
old_fn = re.search(r'(static inline enum vkd3d_result vkd3d_shader_code_from_file\b.*?^})', src, re.DOTALL | re.MULTILINE)
if old_fn and 'fstat' in old_fn.group(0):
    new_fn = '''static inline enum vkd3d_result vkd3d_shader_code_from_file(struct vkd3d_shader_code *shader, FILE *f)
{
    size_t size = 4096;
    size_t pos = 0;
    uint8_t *data;
    size_t ret;

    memset(shader, 0, sizeof(*shader));

    if (!(data = malloc(size)))
        return VKD3D_ERROR_OUT_OF_MEMORY;

    for (;;)
    {
        if (pos >= size)
        {
            if (size > SIZE_MAX / 2 || !(data = realloc(data, size * 2)))
            {
                free(data);
                return VKD3D_ERROR_OUT_OF_MEMORY;
            }
            size *= 2;
        }

        if (!(ret = fread(&data[pos], 1, size - pos, f)))
            break;
        pos += ret;
    }

    if (!feof(f))
    {
        free(data);
        return VKD3D_ERROR;
    }

    shader->code = data;
    shader->size = pos;

    return VKD3D_OK;
}'''
    src = src[:old_fn.start()] + new_fn + src[old_fn.end():]
    # Remove S_ISREG define if present
    src = re.sub(r'#ifndef S_ISREG.*?#endif\n?', '', src, flags=re.DOTALL)
    open(f, 'w').write(src)
    print('OK')
else:
    print('SKIP')
" "$_vkd3d_utils_h"
        ok "Fixup: removed fstat from vkd3d_shader_utils.h"
        (( _fixups_applied++ )) || true
    fi
    _vkd3d_debug="${WINE_SOURCE_DIR}/libs/vkd3d/libs/vkd3d-common/debug.c"
    if [ -f "$_vkd3d_debug" ] && grep -q 'vfprintf(stderr' "$_vkd3d_debug"; then
        sed -i 's/vfprintf(stderr, fmt, args);/(void)fmt; (void)args;/' "$_vkd3d_debug"
        ok "Fixup: removed vfprintf from vkd3d debug.c"
        (( _fixups_applied++ )) || true
    fi
    # Fix 20: winepulse pulse_stream_wait_until_not missing definition
    # GE/Staging patches call pulse_stream_wait_until_not() in pulse_probe_settings
    # but never define the function.
    _pulse_c="${WINE_SOURCE_DIR}/dlls/winepulse.drv/pulse.c"
    if [ -f "$_pulse_c" ] && grep -q 'pulse_stream_wait_until_not' "$_pulse_c" && \
       ! grep -q 'static void pulse_stream_wait_until_not' "$_pulse_c"; then
        sed -i '/^static struct pulse_stream \*handle_get_stream/i \
static void pulse_stream_wait_until_not(pa_mainloop *ml, pa_stream *stream,\
        pa_stream_state_t target, const char *label)\
{\
    while (pa_stream_get_state(stream) == target)\
        pulse_cond_wait();\
}\
' "$_pulse_c"
        ok "Fixup: added pulse_stream_wait_until_not definition in winepulse"
        (( _fixups_applied++ )) || true
    fi

    # Fix 28: missing include/afunix.h (AF_UNIX socket header)
    # TkG patches add #include "afunix.h" to ntdll/unix/socket.c and ws2_32,
    # but the header only exists in upstream Wine (not in Valve proton_10.0).
    _afunix_hdr="${WINE_SOURCE_DIR}/include/afunix.h"
    if [ ! -f "$_afunix_hdr" ] && grep -rq '"afunix.h"' "${WINE_SOURCE_DIR}/dlls/ntdll/" 2>/dev/null; then
        cat > "$_afunix_hdr" << 'AFUNIX_EOF'
/*
 * AF_UNIX socket header (Wine)
 * Auto-generated by mythix-wine fixup — matches upstream Wine include/afunix.h
 */

#ifndef _WS2AFUNIX_
#define _WS2AFUNIX_

#ifdef USE_WS_PREFIX
# define WS(x)    WS_##x
#else
# define WS(x)    x
#endif

#define UNIX_PATH_MAX 108

typedef struct WS(sockaddr_un)
{
    ADDRESS_FAMILY sun_family;
    char sun_path[UNIX_PATH_MAX];
} SOCKADDR_UN, *PSOCKADDR_UN;

#endif /* _WS2AFUNIX_ */
AFUNIX_EOF
        _makefile_in="${WINE_SOURCE_DIR}/include/Makefile.in"
        if [ -f "$_makefile_in" ] && ! grep -q '	afunix.h' "$_makefile_in"; then
            sed -i '/	af_irda\.h/a\	afunix.h \\' "$_makefile_in"
        fi
        ok "Fixup: created include/afunix.h + registered in Makefile.in (TkG AF_UNIX support)"
        (( _fixups_applied++ )) || true
    fi

    # Fix 29: protocol.def duplicate @REQ blocks (proton_10.0 + TkG collision)
    # Valve's proton_10.0 already has esync/fsync in protocol.def.
    # TkG patches add them again → duplicate structs in server_protocol.h.
    # Deduplicate by removing the second occurrence of each @REQ block.
    _protocol_def="${WINE_SOURCE_DIR}/server/protocol.def"
    if [ -f "$_protocol_def" ]; then
        _dup_reqs=()
        while IFS= read -r _req_name; do
            _count=$(grep -c "^@REQ(${_req_name})" "$_protocol_def" 2>/dev/null || true)
            if [ "$_count" -gt 1 ]; then
                _dup_reqs+=("$_req_name")
            fi
        done < <(grep -oP '(?<=^@REQ\()[\w]+(?=\))' "$_protocol_def" | sort -u)

        if [ ${#_dup_reqs[@]} -gt 0 ]; then
            for _req_name in "${_dup_reqs[@]}"; do
                # Remove the SECOND occurrence of @REQ(_req_name) ... @END block
                # Find line numbers of all occurrences
                _lines=($(grep -n "^@REQ(${_req_name})" "$_protocol_def" | cut -d: -f1))
                if [ ${#_lines[@]} -ge 2 ]; then
                    _start=${_lines[1]}
                    _end=$(awk "NR>$_start && /^@END/{print NR; exit}" "$_protocol_def")
                    if [ -n "$_end" ]; then
                        sed -i "${_start},${_end}d" "$_protocol_def"
                    fi
                fi
            done
            # Also deduplicate any enum blocks (like enum fsync_type)
            # These appear as bare enum definitions between @REQ blocks
            # Remove duplicate 'enum fsync_type' block if present
            _enum_count=$(grep -c '^enum fsync_type' "$_protocol_def" 2>/dev/null || true)
            if [ "$_enum_count" -gt 1 ]; then
                _enum_lines=($(grep -n '^enum fsync_type' "$_protocol_def" | cut -d: -f1))
                _start=${_enum_lines[1]}
                _end=$(awk "NR>=$_start && /^};/{print NR; exit}" "$_protocol_def")
                if [ -n "$_end" ]; then
                    sed -i "${_start},${_end}d" "$_protocol_def"
                fi
            fi
            ok "Fixup: deduplicated ${#_dup_reqs[@]} protocol.def @REQ blocks (proton base already has esync/fsync)"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 30: ntdll/unix/file.c — TkG adds duplicate functions + calls to missing sync_ioctl/reparse
    # Proton already has all the esync/fsync infrastructure. Revert to base.
    _file_c="${WINE_SOURCE_DIR}/dlls/ntdll/unix/file.c"
    _file_stash="${WINE_SOURCE_DIR}/.mythix-base-stash/dlls/ntdll/unix/file.c"
    if [ -f "$_file_c" ] && [ -f "$_file_stash" ]; then
        if ! diff -q "$_file_c" "$_file_stash" >/dev/null 2>&1; then
            cp "$_file_stash" "$_file_c"
            ok "Fixup: reverted ntdll/unix/file.c to proton base (TkG/staging incompatible)"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 31a0: nsiproxy.sys — revert staging patches that break on proton_10.0
    # Staging rewrites icmp_echo.c/device.c to use struct members (.s, options_data_offset,
    # packet, data_offset, icmp_listen_thread_proc) that don't exist in proton's structs.
    # Proton's ICMP code works fine — revert the entire nsiproxy.sys dir.
    _nsiproxy_dir="${WINE_SOURCE_DIR}/dlls/nsiproxy.sys"
    if [ -f "${_nsiproxy_dir}/icmp_echo.c" ] && grep -qP 'data->s\b' "${_nsiproxy_dir}/icmp_echo.c" 2>/dev/null && \
       ! grep -q 'int s;' "${_nsiproxy_dir}/icmp_echo.c" 2>/dev/null; then
        # Code uses ->s but struct has ->socket — staging patches are incompatible
        _nsi_stash="${WINE_SOURCE_DIR}/.mythix-base-stash/dlls/nsiproxy.sys"
        if [ -f "${_nsi_stash}/icmp_echo.c" ]; then
            cp "${_nsi_stash}/icmp_echo.c" "${_nsiproxy_dir}/icmp_echo.c"
            [ -f "${_nsi_stash}/device.c" ] && cp "${_nsi_stash}/device.c" "${_nsiproxy_dir}/device.c"
            ok "Fixup: reverted nsiproxy.sys from base stash (staging struct mismatch)"
            (( _fixups_applied++ )) || true
        else
            _pre_staging=$(cd "$WINE_SOURCE_DIR" && git log --oneline -- dlls/nsiproxy.sys/ | tail -1 | cut -d' ' -f1)
            if [ -n "$_pre_staging" ]; then
                (cd "$WINE_SOURCE_DIR" && git checkout "$_pre_staging" -- dlls/nsiproxy.sys/) 2>/dev/null && \
                    ok "Fixup: reverted nsiproxy.sys to proton base (staging struct mismatch)" && \
                    (( _fixups_applied++ )) || true
            fi
        fi
    fi

    # Fix 31a2: server/*.c — revert staging-broken files to TkG state
    # Staging patches partially apply on proton_10.0 and create broken hybrid code.
    # These files are excluded from the generic Fix 7 dedup. Instead, revert them
    # to just after TkG patches (before staging) using the TkG commit tag.
    _server_fixed=false

    # Find the TkG commit — it's the one that applied TkG patches
    # Use git log --format to avoid SIGPIPE (pipefail + grep -m1 kills git → exit 141)
    _tkg_commit=""
    while IFS=' ' read -r _hash _msg; do
        if echo "$_msg" | grep -qiE 'tkg|wine-tkg'; then
            _tkg_commit="$_hash"
            break
        fi
    done < <(cd "$WINE_SOURCE_DIR" && git log --format='%h %s' 2>/dev/null || true)

    if [ -n "$_tkg_commit" ]; then
        for _srv_file in server/queue.c server/registry.c server/fd.c; do
            _full="${WINE_SOURCE_DIR}/${_srv_file}"
            [ -f "$_full" ] || continue
            (cd "$WINE_SOURCE_DIR" && git show "${_tkg_commit}:${_srv_file}" > "$_full" 2>/dev/null) && \
                _server_fixed=true && \
                msg2 "Reverted ${_srv_file} to TkG state"
        done
    fi

    # Fallback: if TkG commit not found, try stash copies then git show
    if [ "$_server_fixed" = false ]; then
        for _srv_file in server/queue.c server/registry.c server/fd.c; do
            _full="${WINE_SOURCE_DIR}/${_srv_file}"
            _stash="${WINE_SOURCE_DIR}/.mythix-base-stash/${_srv_file}"
            [ -f "$_full" ] || continue
            if [ -f "$_stash" ]; then
                cp "$_stash" "$_full"
                _server_fixed=true
                msg2 "Reverted ${_srv_file} from base stash"
            fi
        done
    fi

    if [ "$_server_fixed" = true ]; then
        ok "Fixup: reverted server/ files to pre-staging state (incompatible patches)"
        (( _fixups_applied++ )) || true
    fi

    # Fix 31a5: msado15/connection.c — staging adds 'dso' member not in proton's struct
    _msado_conn="${WINE_SOURCE_DIR}/dlls/msado15/connection.c"
    _stash_conn="${WINE_SOURCE_DIR}/.mythix-base-stash/dlls/msado15/connection.c"
    if [ -f "$_msado_conn" ]; then
        _has_dso=$(grep -c -- '->dso' "$_msado_conn" 2>/dev/null || echo 0)
        if [ "$_has_dso" -gt 0 ]; then
            if [ -f "$_stash_conn" ]; then
                cp "$_stash_conn" "$_msado_conn"
                msg2 "Fix 31a5: reverted msado15/connection.c from stash (had ${_has_dso} ->dso refs)"
            else
                sed -i '/->dso/d' "$_msado_conn"
                msg2 "Fix 31a5: sed-removed ->dso from msado15/connection.c (no stash)"
            fi
            ok "Fixup: reverted msado15/connection.c (staging struct mismatch)"
            (( _fixups_applied++ )) || true
        else
            msg2 "Fix 31a5: msado15/connection.c clean (no ->dso refs)"
        fi
    else
        msg2 "Fix 31a5: msado15/connection.c not found"
    fi

    # Fix 32: win32u/class.c — staging renames atomName→atom, retvalue→retval (proton mismatch)
    _class_c="${WINE_SOURCE_DIR}/dlls/win32u/class.c"
    _stash_class="${WINE_SOURCE_DIR}/.mythix-base-stash/dlls/win32u/class.c"
    if [ -f "$_class_c" ] && grep -qE 'class->atom[^N]' "$_class_c" 2>/dev/null; then
        if [ -f "$_stash_class" ]; then
            cp "$_stash_class" "$_class_c"
            ok "Fixup: reverted win32u/class.c to proton base (staging struct/var mismatch)"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 33: win32u/*.c — staging changes struct/function signatures incompatible with proton
    for _w32u_file in class.c imm.c input.c message.c window.c cursoricon.c defwnd.c hook.c menu.c ntuser_private.h win32u_private.h sysparams.c; do
        _w32u_path="${WINE_SOURCE_DIR}/dlls/win32u/${_w32u_file}"
        _w32u_stash="${WINE_SOURCE_DIR}/.mythix-base-stash/dlls/win32u/${_w32u_file}"
        if [ -f "$_w32u_path" ] && [ -f "$_w32u_stash" ]; then
            if ! diff -q "$_w32u_path" "$_w32u_stash" >/dev/null 2>&1; then
                cp "$_w32u_stash" "$_w32u_path"
                ok "Fixup: reverted win32u/${_w32u_file} to proton base (staging mismatch)"
                (( _fixups_applied++ )) || true
            fi
        fi
    done

    # Fix 34: libs/vkd3d/libs/vkd3d-shader — staging breaks proton's bundled vkd3d wholesale
    _vkd3d_dir="${WINE_SOURCE_DIR}/libs/vkd3d/libs/vkd3d-shader"
    _vkd3d_stash="${WINE_SOURCE_DIR}/.mythix-base-stash/libs/vkd3d/libs/vkd3d-shader"
    if [ -d "$_vkd3d_dir" ] && [ -d "$_vkd3d_stash" ]; then
        if ! diff -rq "$_vkd3d_dir" "$_vkd3d_stash" >/dev/null 2>&1; then
            cp -a "$_vkd3d_stash/." "$_vkd3d_dir/"
            ok "Fixup: reverted libs/vkd3d/libs/vkd3d-shader/ to proton base (staging incompatible)"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 39: xinput1_3/main.c — staging adds is_sony_gamepad member not in proton's struct
    _xinput_c="${WINE_SOURCE_DIR}/dlls/xinput1_3/main.c"
    _xinput_stash="${WINE_SOURCE_DIR}/.mythix-base-stash/dlls/xinput1_3/main.c"
    if [ -f "$_xinput_c" ] && [ -f "$_xinput_stash" ]; then
        if ! diff -q "$_xinput_c" "$_xinput_stash" >/dev/null 2>&1; then
            cp "$_xinput_stash" "$_xinput_c"
            ok "Fixup: reverted xinput1_3/main.c to proton base (staging struct mismatch)"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 38: server/sock.c — staging adds WS_sockaddr_un AF_UNIX support not in proton
    _sock_c="${WINE_SOURCE_DIR}/server/sock.c"
    _sock_stash="${WINE_SOURCE_DIR}/.mythix-base-stash/server/sock.c"
    if [ -f "$_sock_c" ] && [ -f "$_sock_stash" ]; then
        if ! diff -q "$_sock_c" "$_sock_stash" >/dev/null 2>&1; then
            cp "$_sock_stash" "$_sock_c"
            ok "Fixup: reverted server/sock.c to proton base (staging AF_UNIX mismatch)"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 37: ws2_32/socket.c — staging renames variables (len undeclared)
    _ws2_c="${WINE_SOURCE_DIR}/dlls/ws2_32/socket.c"
    _ws2_stash="${WINE_SOURCE_DIR}/.mythix-base-stash/dlls/ws2_32/socket.c"
    if [ -f "$_ws2_c" ] && [ -f "$_ws2_stash" ]; then
        if ! diff -q "$_ws2_c" "$_ws2_stash" >/dev/null 2>&1; then
            cp "$_ws2_stash" "$_ws2_c"
            ok "Fixup: reverted ws2_32/socket.c to proton base (staging var mismatch)"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 44: krnl386.exe16/instr.c — staging renames gdt/ldt vars (not in proton)
    _instr_c="${WINE_SOURCE_DIR}/dlls/krnl386.exe16/instr.c"
    _instr_stash="${WINE_SOURCE_DIR}/.mythix-base-stash/dlls/krnl386.exe16/instr.c"
    if [ -f "$_instr_c" ] && [ -f "$_instr_stash" ]; then
        if ! diff -q "$_instr_c" "$_instr_stash" >/dev/null 2>&1; then
            cp "$_instr_stash" "$_instr_c"
            ok "Fixup: reverted krnl386.exe16/instr.c to proton base (staging var renames)"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 43: mf/main.c — staging adds http_scheme_handler_construct reference (not in proton)
    _mf_main="${WINE_SOURCE_DIR}/dlls/mf/main.c"
    _mf_main_stash="${WINE_SOURCE_DIR}/.mythix-base-stash/dlls/mf/main.c"
    if [ -f "$_mf_main" ] && [ -f "$_mf_main_stash" ]; then
        if ! diff -q "$_mf_main" "$_mf_main_stash" >/dev/null 2>&1; then
            cp "$_mf_main_stash" "$_mf_main"
            ok "Fixup: reverted mf/main.c to proton base (staging http handler)"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 42: mf/scheme_handler.c — staging adds __wine_create_http_bytestream call (not in proton)
    _scheme_c="${WINE_SOURCE_DIR}/dlls/mf/scheme_handler.c"
    _scheme_stash="${WINE_SOURCE_DIR}/.mythix-base-stash/dlls/mf/scheme_handler.c"
    if [ -f "$_scheme_c" ] && [ -f "$_scheme_stash" ]; then
        if ! diff -q "$_scheme_c" "$_scheme_stash" >/dev/null 2>&1; then
            cp "$_scheme_stash" "$_scheme_c"
            ok "Fixup: reverted mf/scheme_handler.c to proton base (staging http bytestream)"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 41: wow64/system.c — TkG adds __wine_needs_override_large_address_aware (not in proton)
    _wow64_c="${WINE_SOURCE_DIR}/dlls/wow64/system.c"
    _wow64_stash="${WINE_SOURCE_DIR}/.mythix-base-stash/dlls/wow64/system.c"
    if [ -f "$_wow64_c" ] && [ -f "$_wow64_stash" ]; then
        if ! diff -q "$_wow64_c" "$_wow64_stash" >/dev/null 2>&1; then
            cp "$_wow64_stash" "$_wow64_c"
            ok "Fixup: reverted wow64/system.c to proton base (TkG large_address_aware)"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 40: mfplat/network.c — staging-only file, doesn't exist in proton base, breaks linking
    _network_c="${WINE_SOURCE_DIR}/dlls/mfplat/network.c"
    if [ -f "$_network_c" ]; then
        rm -f "$_network_c"
        # Also remove from Makefile.in if registered
        _mfplat_makefile="${WINE_SOURCE_DIR}/dlls/mfplat/Makefile.in"
        if [ -f "$_mfplat_makefile" ]; then
            sed -i '/network\.c/d' "$_mfplat_makefile"
        fi
        # Also remove exported functions from .spec that were in network.c
        _mfplat_spec="${WINE_SOURCE_DIR}/dlls/mfplat/mfplat.spec"
        if [ -f "$_mfplat_spec" ]; then
            sed -i '/__wine_create_http_bytestream/d' "$_mfplat_spec"
        fi
        ok "Fixup: removed staging-only mfplat/network.c + exports (not in proton base)"
        (( _fixups_applied++ )) || true
    fi

    # Fix 36: winex11.drv/mouse.c — TkG/staging duplicate struct/function redefinitions
    _mouse_c="${WINE_SOURCE_DIR}/dlls/winex11.drv/mouse.c"
    _mouse_stash="${WINE_SOURCE_DIR}/.mythix-base-stash/dlls/winex11.drv/mouse.c"
    if [ -f "$_mouse_c" ] && [ -f "$_mouse_stash" ]; then
        if ! diff -q "$_mouse_c" "$_mouse_stash" >/dev/null 2>&1; then
            cp "$_mouse_stash" "$_mouse_c"
            ok "Fixup: reverted winex11.drv/mouse.c to proton base (duplicate redefinitions)"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 35: winepulse.drv/pulse.c — staging adds struct members not in proton's pulse_stream
    _pulse_c="${WINE_SOURCE_DIR}/dlls/winepulse.drv/pulse.c"
    _pulse_stash="${WINE_SOURCE_DIR}/.mythix-base-stash/dlls/winepulse.drv/pulse.c"
    if [ -f "$_pulse_c" ] && [ -f "$_pulse_stash" ]; then
        if ! diff -q "$_pulse_c" "$_pulse_stash" >/dev/null 2>&1; then
            cp "$_pulse_stash" "$_pulse_c"
            ok "Fixup: reverted winepulse.drv/pulse.c to proton base (staging struct mismatch)"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 31a4: d3dx9_36/effect.c — staging adds code using vars not in proton's version
    _effect_c="${WINE_SOURCE_DIR}/dlls/d3dx9_36/effect.c"
    _stash_effect="${WINE_SOURCE_DIR}/.mythix-base-stash/dlls/d3dx9_36/effect.c"
    if [ -f "$_effect_c" ] && grep -q 'D3DXPC_STRUCT\|param->member_count' "$_effect_c" 2>/dev/null; then
        if [ -f "$_stash_effect" ]; then
            cp "$_stash_effect" "$_effect_c"
        fi
        ok "Fixup: reverted d3dx9_36/effect.c to proton base (staging incompatible)"
        (( _fixups_applied++ )) || true
    fi

    # Fix 31a3: kernelbase/file.c uses RtlPathTypeRelative not in proton's winternl.h
    _winternl="${WINE_SOURCE_DIR}/include/winternl.h"
    if [ -f "$_winternl" ] && ! grep -q 'RtlPathTypeRelative' "$_winternl" 2>/dev/null; then
        if grep -rq 'RtlPathTypeRelative' "${WINE_SOURCE_DIR}/dlls/" 2>/dev/null; then
            # Add RTL_PATH_TYPE enum before the first typedef enum in the file
            sed -i '/^typedef enum _PROCESSINFOCLASS/i\typedef enum _RTL_PATH_TYPE\n{\n    RtlPathTypeUnknown,\n    RtlPathTypeUncAbsolute,\n    RtlPathTypeDriveAbsolute,\n    RtlPathTypeDriveRelative,\n    RtlPathTypeRooted,\n    RtlPathTypeRelative,\n    RtlPathTypeLocalDevice,\n    RtlPathTypeRootLocalDevice,\n} RTL_PATH_TYPE;\n' "$_winternl"
            ok "Fixup: added RTL_PATH_TYPE enum to winternl.h"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 31a1: odbc32/proxyodbc.c — staging adds driver_odbc_ver not in proton's struct
    _proxyodbc="${WINE_SOURCE_DIR}/dlls/odbc32/proxyodbc.c"
    _stash_odbc="${WINE_SOURCE_DIR}/.mythix-base-stash/dlls/odbc32/proxyodbc.c"
    if [ -f "$_proxyodbc" ] && grep -q 'driver_odbc_ver' "$_proxyodbc" 2>/dev/null; then
        if [ -f "$_stash_odbc" ]; then
            cp "$_stash_odbc" "$_proxyodbc"
        else
            _pre_staging=$(cd "$WINE_SOURCE_DIR" && git log --oneline -- dlls/odbc32/ | tail -1 | cut -d' ' -f1)
            [ -n "$_pre_staging" ] && \
                (cd "$WINE_SOURCE_DIR" && git checkout "$_pre_staging" -- dlls/odbc32/) 2>/dev/null || true
        fi
        ok "Fixup: reverted odbc32 to proton base (staging struct mismatch)"
        (( _fixups_applied++ )) || true
    fi

    # Fix 31a: ntdll/unix/signal_x86_64.c — TkG adds get_syscall_frame + duplicates proton already has
    _signal_c="${WINE_SOURCE_DIR}/dlls/ntdll/unix/signal_x86_64.c"
    _signal_stash="${WINE_SOURCE_DIR}/.mythix-base-stash/dlls/ntdll/unix/signal_x86_64.c"
    if [ -f "$_signal_c" ] && [ -f "$_signal_stash" ]; then
        if ! diff -q "$_signal_c" "$_signal_stash" >/dev/null 2>&1; then
            cp "$_signal_stash" "$_signal_c"
            ok "Fixup: reverted signal_x86_64.c to proton base (TkG get_syscall_frame + duplicates)"
            (( _fixups_applied++ )) || true
        fi
    fi

    # Fix 31b: ntdll/unix/registry.c duplicate 'struct saved_key'
    # TkG adds saved_key struct that proton_10.0 already has.
    _registry_c="${WINE_SOURCE_DIR}/dlls/ntdll/unix/registry.c"
    if [ -f "$_registry_c" ]; then
        _dup_count=$(grep -c '^struct saved_key$' "$_registry_c" 2>/dev/null || true)
        if [ "$_dup_count" -gt 1 ]; then
            # Remove the second struct saved_key { ... }; block
            _lines=($(grep -n '^struct saved_key$' "$_registry_c" | cut -d: -f1))
            if [ ${#_lines[@]} -ge 2 ]; then
                _start=${_lines[1]}
                _end=$(awk "NR>$_start && /^};/{print NR; exit}" "$_registry_c")
                if [ -n "$_end" ]; then
                    sed -i "${_start},${_end}d" "$_registry_c"
                    ok "Fixup: removed duplicate struct saved_key from registry.c"
                    (( _fixups_applied++ )) || true
                fi
            fi
        fi
        # Also check for duplicate functions that follow saved_key
        for _fn in save_key load_key; do
            _dup_count=$(grep -c "^static.*${_fn}" "$_registry_c" 2>/dev/null || true)
            if [ "$_dup_count" -gt 1 ]; then
                _lines=($(grep -n "^static.*${_fn}" "$_registry_c" | cut -d: -f1))
                if [ ${#_lines[@]} -ge 2 ]; then
                    _start=${_lines[1]}
                    _end=$(awk "NR>$_start && /^}$/{print NR; exit}" "$_registry_c")
                    if [ -n "$_end" ]; then
                        sed -i "${_start},${_end}d" "$_registry_c"
                    fi
                fi
            fi
        done
    fi

    if [ "$_fixups_applied" -eq 0 ]; then
        ok "No fixups needed"
    else
        ok "Applied ${_fixups_applied} compatibility fixups"
        (cd "$WINE_SOURCE_DIR" && git add -A && \
            git commit -q -m "mythix-wine: post-patch compatibility fixups" --allow-empty) 2>/dev/null || true
    fi

    # ── Rebrand version string ────────────────────────────────────────────
    # TkG patches embed "( TkG Staging Esync Fsync )" in configure.ac.
    # Replace with Mythix branding and direct bug reports to us, not TkG/WineHQ.
    _configure_ac="${WINE_SOURCE_DIR}/configure.ac"
    if [ -f "$_configure_ac" ]; then
        # Replace the version suffix: "( TkG ... )" → "(Mythix Wine)"
        sed -i 's/( TkG[^)]*)/(Mythix Wine)/' "$_configure_ac"
        # Replace any wine-tkg bug report URL with ours
        sed -i 's|https://github.com/Frogging-Family/wine-tkg-git/issues|https://github.com/mythix-org/mythix-build/issues|g' "$_configure_ac"
        # Also patch loader/main.c which prints the "wine started" banner
        _loader_main="${WINE_SOURCE_DIR}/loader/main.c"
        if [ -f "$_loader_main" ]; then
            sed -i 's|Frogging-Family/wine-tkg-git|mythix-org/mythix-build|g' "$_loader_main"
            sed -i 's|wine-tkg-git|mythix-wine|g' "$_loader_main"
            sed -i 's|wine-tkg|Mythix Wine|g' "$_loader_main"
        fi
        ok "Rebranded version string → Mythix Wine"
    fi

    # ── Regenerate server_protocol.h ─────────────────────────────────────
    # TkG/Staging patches add new server requests (flush_key_done, etc.)
    # and modify existing reply structures in server/protocol.def.
    # make_requests regenerates the C structs/enums for requests+replies.
    _make_req="${WINE_SOURCE_DIR}/tools/make_requests"
    if [ -f "$_make_req" ]; then
        msg "Regenerating server_protocol.h (protocol.def was patched)…"
        (cd "$WINE_SOURCE_DIR" && perl tools/make_requests) || \
            warn "make_requests failed — some server requests may not compile"
        ok "server_protocol.h regenerated"
    fi

    # ── Summary ───────────────────────────────────────────────────────────
    section "Mythix Wine source tree ready"
    msg "Base:    Valve proton-wine bleeding-edge"
    msg "Layer 2: TkG patches (extracted from Kron4ek wine-tkg)"
    msg "Layer 3: Wine-Staging patches"
    msg "Layer 4: GE-Proton gaming patches"
    msg "Layer 5: Mythix custom patches (from patches/mythix-wine/)"
    msg2 "Full patch log: ${_mythix_patch_log}"
    ok "Mythix Wine — the works"
fi

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
#    ${NEUTRON_PACKAGE_DIR}/files/lib/wine/dxvk/x32/  (32-bit)
#    ${NEUTRON_PACKAGE_DIR}/files/lib/wine/dxvk/x64/  (64-bit)
# ══════════════════════════════════════════════════════════════════════════════
section "DXVK build  "
if [ "${SKIP_DXVK:-false}" = "true" ]; then
    msg2 "Skipping DXVK (--vkd3d-only)"
elif [ "${REINSTALL_COMPONENTS:-false}" = "true" ]; then
    section "DXVK reinstall from existing build"
    _dxvk_build_64="${SRC_ROOT}/dxvk-${DXVK_SOURCE_KEY}/build/x64"
    _dxvk_build_32="${SRC_ROOT}/dxvk-${DXVK_SOURCE_KEY}/build/x32"
    _dxvk_dest_64="${WINE_INSTALL_PREFIX}/lib/wine/dxvk/x64"
    _dxvk_dest_32="${WINE_INSTALL_PREFIX}/lib/wine/dxvk/x32"
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
        "${WINE_INSTALL_PREFIX}/lib/wine/dxvk/x64" \
        "${WINE_INSTALL_PREFIX}/lib/wine/dxvk/x32"
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
#    ${NEUTRON_PACKAGE_DIR}/files/lib/wine/vkd3d-proton/i386-windows/      (32-bit)
#    ${NEUTRON_PACKAGE_DIR}/files/lib/wine/vkd3d-proton/x86_64-windows/  (64-bit)
# ══════════════════════════════════════════════════════════════════════════════
section "VKD3D-Proton build  "
if [ "${REINSTALL_COMPONENTS:-false}" = "true" ]; then
    section "VKD3D-Proton reinstall from existing build"
    _vkd3d_build_64="${SRC_ROOT}/vkd3d-proton/build/x64"
    _vkd3d_build_32="${SRC_ROOT}/vkd3d-proton/build/x32"
    _vkd3d_dest_64="${WINE_INSTALL_PREFIX}/lib/wine/vkd3d-proton/x86_64-windows"
    _vkd3d_dest_32="${WINE_INSTALL_PREFIX}/lib/wine/vkd3d-proton/i386-windows"
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
        "${WINE_INSTALL_PREFIX}/lib/wine/vkd3d-proton/x86_64-windows" \
        "${WINE_INSTALL_PREFIX}/lib/wine/vkd3d-proton/i386-windows"
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
