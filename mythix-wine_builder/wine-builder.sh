#!/usr/bin/env bash
# ╔═════════════════════════════════════════════════════════════════════════╗
# ║              mythix-wine_builder  •  multi-source  v1.0.0                ║
# ║                fetch  •  patch  •  compile  •  install                  ║
# ╚═════════════════════════════════════════════════════════════════════════╝
#
#
# Entry point for building Wine from multiple upstream sources.
# Handles source selection, dependency checks, git fetch, pre-build header
# generation, and compilation via wine-build-core.sh.
#
# Usage:  ./wine-builder.sh [options]
#         ./wine-builder.sh --help      for full option reference
#
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# ══════════════════════════════════════════════════════════════════════════
#  Path resolution — works from both the source tree and after `make install`
#
#  Source tree layout:
#    mythix-wine_builder/
#      wine-builder.sh     ← this script
#      wine-build-core.sh  ← engine scripts alongside it
#      customization.cfg   ← config alongside it
#      buildz/             ← build output
#      src/                ← git clones
#
#  Installed layout (make install PREFIX=~/.local):
#    ~/.local/bin/wine-builder               ← this script
#    ~/.local/lib/mythix-wine_builder/*.sh    ← engine scripts
#    ~/.config/mythix-build/*.cfg             ← config
#    ~/.local/share/mythix-wine_builder/      ← build output + git clones
# ══════════════════════════════════════════════════════════════════════════
if [ -f "${SCRIPT_DIR}/wine-build-core.sh" ]; then
    # Running directly from the source tree — lib scripts are alongside us,
    # but data (build output, git clones) always goes to the XDG data dir so
    # builds never accumulate inside the git repo.
    _LIB_DIR="$SCRIPT_DIR"
    _CFG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/mythix-build"
    _DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/mythix-wine_builder"
elif [ -f "${SCRIPT_DIR}/../lib/mythix-wine_builder/wine-build-core.sh" ]; then
    # Running from an installed bin/ directory
    _LIB_DIR="$(cd "${SCRIPT_DIR}/../lib/mythix-wine_builder" && pwd)"
    _CFG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/mythix-build"
    _DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/mythix-wine_builder"
else
    printf "ERR! Cannot locate engine scripts.\n" >&2
    printf "     Expected alongside this script or in ../lib/mythix-wine_builder/\n" >&2
    printf "     Run from the source tree, or install with: make install\n" >&2
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════════
#  Colour & output helpers
# ══════════════════════════════════════════════════════════════════════════
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
# _LIB_DIR is used by the path resolution below; we just need its value
# before the full resolution block runs.
if [ -f "${SCRIPT_DIR}/wine-build-core.sh" ]; then
    _LIB_DIR="$SCRIPT_DIR"
elif [ -f "${SCRIPT_DIR}/../lib/mythix-wine_builder/wine-build-core.sh" ]; then
    _LIB_DIR="$(cd "${SCRIPT_DIR}/../lib/mythix-wine_builder" && pwd)"
else
    _LIB_DIR=""
fi

# Source common output helpers (uses the C_* color variables set above)
if [ -n "$_LIB_DIR" ] && [ -f "${_LIB_DIR}/_output_common.sh" ]; then
    . "${_LIB_DIR}/_output_common.sh"
elif [ -f "${SCRIPT_DIR}/_output_common.sh" ]; then
    # Fallback: when running from the source tree before _LIB_DIR is resolved
    . "${SCRIPT_DIR}/_output_common.sh"
fi

# ══════════════════════════════════════════════════════════════════════════
#  Banner
# ══════════════════════════════════════════════════════════════════════════
print_banner() {
    printf "\n${C_MAG}${C_B}"
    # Wolf head — mascot of mythix-wine_builder
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
    printf "  ╔═══════════════════════════════════════════════════════════╗\n"
    printf "  ║                                                           ║\n"
    printf "  ║  🛠  mythix-wine_builder  •  multi-source v1.0.0           ║\n"
    printf "  ║       fetch  •  patch  •  compile  •  install             ║\n"
    printf "  ║                                                           ║\n"
    printf "  ╚═══════════════════════════════════════════════════════════╝\n"
    printf "${C_R}\n"
}

# ══════════════════════════════════════════════════════════════════════════
#  Wine source catalogue
#
#  Format: associative arrays keyed by source name.
#  SOURCE_IS_TKG marks build-system repos that need special handling
#  (they are cloned, then we offer to delegate to their own build script).
# ══════════════════════════════════════════════════════════════════════════
declare -A SOURCE_URL=(
    [mainline]="https://gitlab.winehq.org/wine/wine.git"
    [experimental]="https://gitlab.winehq.org/wine/wine.git"
    [staging]="https://gitlab.winehq.org/wine/wine.git"
    [tkg-patched]="https://gitlab.winehq.org/wine/wine.git"
    [proton]="https://github.com/ValveSoftware/wine.git"
    [proton-experimental]="https://github.com/ValveSoftware/wine.git"
    [wine-tkg]="https://github.com/frogging-family/wine-tkg-git.git"
    [kron4ek]="https://github.com/Kron4ek/wine-tkg.git"
)
declare -A SOURCE_BRANCH=(
    [mainline]=""               # default branch (latest stable)
    [experimental]="master"     # WineHQ bleeding edge
    [staging]=""                # default branch
    [tkg-patched]=""            # version picker handles this (same tags as mainline)
    [proton]=""               # version picker selects the branch interactively
    [proton-experimental]="bleeding-edge"
    [wine-tkg]=""               # default branch of the TKG framework repo
    [kron4ek]=""                # default branch
)
declare -A SOURCE_DESC=(
    [mainline]="Wine mainline                — official WineHQ releases"
    [experimental]="Wine experimental           — WineHQ bleeding edge (master)"
    [staging]="Wine staging                 — mainline + community patches (pre-applied)"
    [tkg-patched]="Wine + staging (automated)   — mainline with staging applied, no interaction  [+]"
    [proton]="Valve Bleeding Edge          — Valve's Wine fork (version picker selects branch)"
    [proton-experimental]="Valve Bleeding Edge Experimental — Valve's latest experiments"
    [wine-tkg]="wine-tkg (frogging)         — community patchset framework  [*]"
    [kron4ek]="Kron4ek wine-tkg             — Kron4ek's Wine build"
    [local]="Local source                 — use an existing directory"
    [custom]="Custom URL                   — provide your own git URL + branch"
)
# Sources that are build-system frameworks rather than plain Wine source trees.
# These get special delegation handling after the clone step.
declare -A SOURCE_IS_TKG=(
    [wine-tkg]="true"
)
# Sources that support the interactive version picker.
# Omitted keys (experimental, proton-experimental, wine-tkg, local, custom)
# either have no meaningful stable tags or manage versioning themselves.
declare -A SOURCE_HAS_VERSIONS=(
    [mainline]="true"
    [staging]="true"
    [tkg-patched]="true"    # same tags as mainline — both use WineHQ git
    [proton]="true"
    [kron4ek]="true"
)
# Whether a source's versions live in git tags or git branches.
# Valve's wine fork uses branches (proton_8.0, proton_9.0, ...);
# everyone else uses annotated/lightweight tags.
declare -A SOURCE_VERSION_REF_TYPE=(
    [mainline]="tags"
    [staging]="tags"
    [tkg-patched]="tags"
    [proton]="heads"   # Valve uses branches, not tags
    [kron4ek]="tags"
)
# Sources that need a post-fetch patch application step before configure.
# wine-builder.sh calls wine-tkg-patcher.sh for these after the git clone.
declare -A SOURCE_NEEDS_PATCHING=(
    [tkg-patched]="true"
    [staging]="true"
)
# Ordered list of candidate build-script filenames for each TKG source.
# The first match found in the cloned tree wins.
# Separate names with a space; they are split into an array at search time.
declare -A SOURCE_TKG_SCRIPTS=(
    [wine-tkg]="non-makepkg-build.sh"
)
# Known exact relative paths to the build script within each TKG clone.
# These are checked first (before any generic find) so we hit the right script
# even when the repo contains multiple files sharing the same name.
# Separate multiple candidates with a colon; checked in order.
declare -A SOURCE_TKG_PATHS=(
    # non-makepkg-build.sh is the correct entry point for non-Arch (Debian/Ubuntu) systems.
    # The wine-tkg-scripts/ subdirectory contains helper modules sourced *by* this script,
    # not standalone entry points.  wine-tkg / wine64-tkg / wine-tkg-interactive in that
    # subdir are runtime launchers for the installed Wine — not build scripts.
    [wine-tkg]="wine-tkg-git/non-makepkg-build.sh"
)
SOURCE_KEYS=( mainline experimental staging tkg-patched proton proton-experimental wine-tkg kron4ek local custom )

# ══════════════════════════════════════════════════════════════════════════
#  Defaults — all overridable by flags
# ══════════════════════════════════════════════════════════════════════════
DEST_ROOT="${_DATA_DIR}/buildz"   # build-run/ and install/ live here
SRC_ROOT="${_DATA_DIR}/src"       # git clones live here
WINE_SOURCE_KEY=""
WINE_SOURCE_URL=""
WINE_SOURCE_BRANCH=""
WINE_SOURCE_DIR=""
LOCAL_SOURCE_DIR=""
BUILD_NAME=""
JOBS="${JOBS:-$(nproc)}"
DRY_RUN=0
SKIP_32BIT=false
NO_PULL=false
RESUME=false            # skip configure if Makefile already present (--resume)
UNINSTALL_NAME=""       # set by --uninstall to trigger removal mode
UPDATE_MODE=false       # set by --update to trigger update+rebuild mode
CUSTOM_CFG="${_CFG_DIR}/customization.cfg"
BUILD_CORE="${_LIB_DIR}/wine-build-core.sh"
PATCHER="${_LIB_DIR}/wine-tkg-patcher.sh"
BUILD_LOG=""            # resolved after BUILD_RUN_DIR is known
VERBOSE_BUILD=false     # --verbose: stream raw make output instead of the progress bar

# ── Build tuning toggles (all overridable by flags) ───────────────────────
NO_CCACHE=false         # --no-ccache: disable ccache entirely
KEEP_SYMBOLS=false      # --keep-symbols: skip strip, keep debug info
BUILD_TYPE="release"    # --build-type release|debug|debugoptimized
NATIVE_MARCH=false      # --native: compile with -march=native (non-portable)
LTO=false               # --lto: enable link-time optimisation (slow link)

# ══════════════════════════════════════════════════════════════════════════
#  Usage
# ══════════════════════════════════════════════════════════════════════════
print_usage() {
    cat <<USAGE
${C_B}Usage:${C_R} $0 [options]

${C_B}Source selection:${C_R}
  --source NAME       Wine source to build. One of:
                        mainline, experimental, staging,
                        tkg-patched,
                        proton, proton-experimental,
                        wine-tkg, kron4ek,
                        local, custom
  --url URL           Git URL     (required with --source custom)
  --branch BRANCH     Branch or tag to checkout — skips the interactive
                      version picker when provided
  --local-dir PATH    Existing source path  (required with --source local,
                      or omit to get an interactive fzf/select picker)
  --no-pull           Skip git pull on an existing source tree

${C_B}Build options:${C_R}
  --dest DIR          Root dir for build-run/ and install/  (default: <script-dir>/buildz)
  --src-dir DIR       Root dir for git-cloned sources        (default: <script-dir>/src)
  --name NAME         Build name for the install path (default: auto)
  --jobs N            Parallel make jobs              (default: $(nproc))
  --skip-32           Skip the 32-bit build
  --no-ccache         Disable ccache even if installed
  --keep-symbols      Skip strip — keep debug symbols in binaries
  --build-type TYPE   release (default) | debug | debugoptimized
  --native            Compile with -march=native (faster but non-portable)
  --lto               Enable link-time optimisation (slower link, smaller binary)
  --resume            Skip configure if Makefile already exists
  --verbose           Stream raw make output instead of the progress bar
  --cfg PATH          Use an alternate customization.cfg

${C_B}General:${C_R}
  --list              Show all installed builds in buildz/install/
  --uninstall NAME    Remove a named build (install + build-run dirs).
                      Omit NAME to get an interactive picker.
  --update            Re-fetch and rebuild the source last used for NAME
                      (requires --name or picks the most recent build)
  --dry-run           Print all planned actions without executing them
  -h | --help         Show this help

${C_B}Examples:${C_R}
  $0                                    # interactive source + version menu
  $0 --source experimental              # WineHQ bleeding edge (no picker)
  $0 --source staging --jobs 16         # interactive version picker for staging
  $0 --source mainline --branch wine-10.6   # pin a specific version non-interactively
  $0 --source proton --branch proton_9.0    # pin a Valve branch
  $0 --source tkg-patched               # mainline + staging + patches/
  $0 --source tkg-patched --jobs 16     # same, with more threads
  $0 --source local --local-dir /opt/wine-src --name my-wine
  $0 --source custom --url https://github.com/me/wine.git --branch patches
  $0 --source staging --resume          # resume an interrupted build
  $0 --list                             # show all installed builds
  $0 --uninstall wine-staging           # remove a specific build
  $0 --uninstall                        # interactive picker of builds to remove
  $0 --update --source staging          # re-fetch + rebuild staging
  $0 --update                           # rebuild the most recently built source

${C_B}Notes on [*] TKG sources:${C_R}
  wine-tkg is a build-system framework, not a bare Wine source tree.
  After cloning, wine-builder offers three options:
    1) Delegate fully to non-makepkg-build.sh (recommended — full patch support)
    2) Hybrid: run TKG prepare only, then hand off compilation here
    3) Abort (for manual setup)
  kron4ek is a plain Wine source tree and is built directly.
USAGE
}

# ══════════════════════════════════════════════════════════════════════════
#  Argument parsing
# ══════════════════════════════════════════════════════════════════════════
while [ "$#" -gt 0 ]; do
    case "$1" in
        --source)    WINE_SOURCE_KEY="$2";    shift 2 ;;
        --url)       WINE_SOURCE_URL="$2";    shift 2 ;;
        --branch)    WINE_SOURCE_BRANCH="$2"; shift 2 ;;
        --local-dir) LOCAL_SOURCE_DIR="$2";   shift 2 ;;
        --dest)      DEST_ROOT="$2";          shift 2 ;;
        --src-dir)   SRC_ROOT="$2";           shift 2 ;;
        --name)      BUILD_NAME="$2";         shift 2 ;;
        --jobs)      JOBS="$2";               shift 2 ;;
        --skip-32)   SKIP_32BIT=true;         shift   ;;
        --no-ccache) NO_CCACHE=true;          shift   ;;
        --keep-symbols) KEEP_SYMBOLS=true;    shift   ;;
        --build-type) BUILD_TYPE="$2";        shift 2 ;;
        --native)    NATIVE_MARCH=true;       shift   ;;
        --lto)       LTO=true;                shift   ;;
        --resume)    RESUME=true;             shift   ;;
        --verbose)   VERBOSE_BUILD=true;      shift   ;;
        --no-pull)   NO_PULL=true;            shift   ;;
        --cfg)       CUSTOM_CFG="$2";         shift 2 ;;
        --dry-run)   DRY_RUN=1;               shift   ;;
        --list)      UNINSTALL_NAME="__list"; shift   ;;
        --uninstall) UNINSTALL_NAME="${2:-__pick}"; shift; [ "$UNINSTALL_NAME" != "__pick" ] && shift ;;
        --update)    UPDATE_MODE=true;        shift   ;;
        -h|--help)   print_usage; exit 0               ;;
        *) printf "Unknown option: %s\n" "$1" >&2; print_usage; exit 1 ;;
    esac
done

# ══════════════════════════════════════════════════════════════════════════
#  list_builds  —  show all installed builds in buildz/install/
# ══════════════════════════════════════════════════════════════════════════
list_builds() {
    local install_dir="${DEST_ROOT}/install"
    local manifest="${DEST_ROOT}/builds.log"

    section "Installed builds"

    if [ ! -d "$install_dir" ] || [ -z "$(ls -A "$install_dir" 2>/dev/null)" ]; then
        msg2 "No builds found in ${install_dir}"
        return 0
    fi

    printf "\n${C_B}  %-36s  %-28s  %s${C_R}\n" "build name" "wine version" "size"
    printf "  %s\n" "$(printf '─%.0s' {1..80})"

    local name wine_ver size
    for d in "$install_dir"/*/; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"
        if [ -x "${d}bin/wine" ]; then
            wine_ver="$("${d}bin/wine" --version 2>/dev/null || printf 'unknown')"
        else
            wine_ver="(binary not found)"
        fi
        size="$(du -sh "$d" 2>/dev/null | cut -f1)"
        printf "  ${C_CYN}%-36s${C_R}  %-28s  %s\n" "$name" "$wine_ver" "$size"
    done

    if [ -f "$manifest" ]; then
        printf "\n  ${C_DIM}Full build history: %s${C_R}\n" "$manifest"
    fi
    printf "\n"
}

# ══════════════════════════════════════════════════════════════════════════
#  uninstall_build  —  remove a named build's install + build-run dirs
# ══════════════════════════════════════════════════════════════════════════
uninstall_build() {
    local target="$1"
    local install_dir="${DEST_ROOT}/install"
    local buildrun_dir="${DEST_ROOT}/build-run"

    # ── Interactive picker if no name given ──────────────────────────────
    if [ "$target" = "__pick" ]; then
        if [ ! -d "$install_dir" ] || [ -z "$(ls -A "$install_dir" 2>/dev/null)" ]; then
            err "No builds found in ${install_dir} — nothing to uninstall."
        fi
        local -a builds=()
        for d in "$install_dir"/*/; do
            [ -d "$d" ] && builds+=("$(basename "$d")")
        done

        if command -v fzf >/dev/null 2>&1; then
            target=$(printf '%s\n' "${builds[@]}" \
                | fzf --prompt="Uninstall > " \
                      --header="Select a build to remove" \
                      --height=40% --border || true)
        else
            printf "\n  ${C_B}Select a build to uninstall:${C_R}\n\n"
            PS3="  Choice: "
            select item in "${builds[@]}" "Abort"; do
                [ "$item" = "Abort" ] || [ -z "$item" ] && exit 0
                target="$item"
                break
            done
            PS3=""
        fi
        [ -n "$target" ] || { msg "Aborted."; exit 0; }
    fi

    local target_install="${install_dir}/${target}"
    local target_build="${buildrun_dir}/${target}"

    [ -d "$target_install" ] || \
        err "Build not found: ${target_install}"

    # ── Confirm ──────────────────────────────────────────────────────────
    local size
    size="$(du -sh "$target_install" 2>/dev/null | cut -f1)"
    printf "\n"
    warn "About to remove: ${C_B}${target}${C_R}"
    printf "  Install dir : %s  (%s)\n" "$target_install" "$size"
    [ -d "$target_build" ] && \
        printf "  Build dir   : %s\n" "$target_build"
    printf "\n"

    if [ "$DRY_RUN" -eq 1 ]; then
        dim "  [dry-run] rm -rf \"${target_install}\""
        [ -d "$target_build" ] && dim "  [dry-run] rm -rf \"${target_build}\""
        return 0
    fi

    printf "  ${C_B}Confirm removal? [y/N]:${C_R} "
    local ans
    read -r ans
    [[ "$ans" =~ ^[yY] ]] || { msg "Aborted."; exit 0; }

    rm -rf "$target_install"
    ok "Removed install dir: ${target_install}"
    if [ -d "$target_build" ]; then
        rm -rf "$target_build"
        ok "Removed build dir:   ${target_build}"
    fi

    msg "Uninstall complete: ${target}"
}

# ── Early-exit dispatch for --list, --uninstall, --update ─────────────────
# These modes do their work and exit before the source menu or build flow.
if [ -n "$UNINSTALL_NAME" ]; then
    print_banner
    if [ "$UNINSTALL_NAME" = "__list" ]; then
        list_builds
    else
        uninstall_build "$UNINSTALL_NAME"
    fi
    exit 0
fi

if [ "$UPDATE_MODE" = true ]; then
    # --update: force a fresh git pull then rebuild.
    # Requires --source (or uses the last-built source from builds.log).
    # Just clears NO_PULL and falls through to the normal build flow.
    NO_PULL=false
    if [ -z "$WINE_SOURCE_KEY" ] && [ -f "${DEST_ROOT}/builds.log" ]; then
        # Infer the source key from the most recent manifest entry
        _last_source=$(grep -v '^date\|^─' "${DEST_ROOT}/builds.log" \
            | tail -1 | awk '{print $3}')
        if [ -n "$_last_source" ]; then
            WINE_SOURCE_KEY="$_last_source"
            msg2 "--update: using last-built source: ${WINE_SOURCE_KEY}"
        fi
    fi
    [ -n "$WINE_SOURCE_KEY" ] || \
        err "--update requires --source NAME (or a prior build in builds.log)"
fi

# ══════════════════════════════════════════════════════════════════════════
#  Error recovery trap
#  On any unexpected exit, tail the build log and offer an interactive menu.
# ══════════════════════════════════════════════════════════════════════════
_on_error() {
    local exit_code=$?
    local line="$1"
    printf "\n${C_RED}${C_B}✗  Build failed — exit %d at line %d${C_R}\n\n" \
        "$exit_code" "$line" >&2

    # Tail the build log if one was opened
    if [ -n "${BUILD_LOG:-}" ] && [ -f "$BUILD_LOG" ]; then
        printf "${C_YLW}── Last 40 lines of %s ──${C_R}\n\n" "$BUILD_LOG" >&2
        tail -n 40 "$BUILD_LOG" >&2
        printf "\n${C_DIM}Full log: %s${C_R}\n\n" "$BUILD_LOG" >&2
    fi

    # Interactive recovery (only when stdin is a terminal and we have a log)
    if [ -t 0 ] && [ -n "${BUILD_LOG:-}" ] && [ -f "$BUILD_LOG" ]; then
        printf "${C_B}What would you like to do?${C_R}\n"
        printf "  ${C_CYN}1)${C_R} Page through the full build log\n"
        printf "  ${C_CYN}2)${C_R} Open a shell in the build directory\n"
        printf "  ${C_CYN}3)${C_R} Exit  (default)\n"
        printf "\n  Choice [1-3]: "
        local choice
        read -r choice || choice="3"
        case "${choice:-3}" in
            1)
                "${PAGER:-less}" "$BUILD_LOG"
                ;;
            2)
                local bd="${BUILD_RUN_DIR:-$(pwd)}"
                printf "\n${C_BLU}Opening shell in: %s${C_R}\n" "$bd"
                printf "${C_DIM}(type 'exit' to leave)${C_R}\n\n"
                ( cd "$bd" && exec "${SHELL:-bash}" ) || true
                ;;
        esac
    fi
    exit "$exit_code"
}
trap '_on_error $LINENO' ERR

# ══════════════════════════════════════════════════════════════════════════
#  Interactive source menu
# ══════════════════════════════════════════════════════════════════════════
source_menu() {
    if command -v fzf >/dev/null 2>&1; then
        local picked
        picked=$(
            for k in "${SOURCE_KEYS[@]}"; do
                printf '%s\t%s\n' "$k" "${SOURCE_DESC[$k]}"
            done             | fzf                 --prompt="Wine source > "                 --header="Select a Wine source   [*] = build-system framework with delegation"                 --with-nth=2                 --delimiter=$'\t'                 --height=30%                 --border             || true
        )
        [ -n "$picked" ] || { msg "No source selected — exiting."; exit 0; }
        WINE_SOURCE_KEY="$(printf '%s' "$picked" | cut -d$'\t' -f1)"
    else
        printf "\n  ${C_B}Choose a Wine source to build:${C_R}\n\n"
        local i=1
        for key in "${SOURCE_KEYS[@]}"; do
            printf "  ${C_CYN}%d)${C_R} %s\n" "$i" "${SOURCE_DESC[$key]}"
            i=$(( i + 1 ))
        done
        printf "\n  ${C_DIM}[*] = build-system framework; wine-builder will offer delegation options${C_R}\n\n"
        local choice
        while true; do
            printf "  ${C_B}Enter number [1-%d]:${C_R} " "${#SOURCE_KEYS[@]}"
            read -r choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && \
               [ "$choice" -ge 1 ] && \
               [ "$choice" -le "${#SOURCE_KEYS[@]}" ]; then
                WINE_SOURCE_KEY="${SOURCE_KEYS[$(( choice - 1 ))]}"
                break
            fi
            printf "  ${C_YLW}Please enter a number between 1 and %d.${C_R}\n" \
                "${#SOURCE_KEYS[@]}"
        done
    fi
    ok "Selected: ${SOURCE_DESC[$WINE_SOURCE_KEY]}"
}

# ══════════════════════════════════════════════════════════════════════════
#  _strip_version_prefix
#  Strips well-known Wine/Proton branch/tag prefixes from a ref string.
#  Used by both _tag_to_display and _extract_version_suffix so the prefix
#  list stays in one place.
#
#  Strips: wine-staging-, wine-, proton_, v
#  Examples:
#    wine-10.6         →  10.6
#    wine-staging-10.6 →  staging-10.6  (only first match)
#    proton_8.0        →  8.0
#    v9.21             →  9.21
# ══════════════════════════════════════════════════════════════════════════
_strip_version_prefix() {
    local v="$1"
    v="${v#wine-staging-}"
    v="${v#wine-}"
    v="${v#proton_}"
    v="${v#v}"
    printf '%s' "$v"
}

# ══════════════════════════════════════════════════════════════════════════
#  _extract_version_suffix
#  Strips well-known prefixes from a tag/branch name and returns the bare
#  version string, or nothing if it doesn't look like a version.
#  Used to build a human-readable suffix for BUILD_NAME / directory names.
#
#  Examples:
#    wine-10.6            →  10.6
#    wine-10.0-rc1        →  10.0-rc1
#    wine-staging-10.6    →  10.6
#    proton_8.0           →  8.0
#    v9.21                →  9.21
#    master / ""          →  (empty — no suffix)
# ══════════════════════════════════════════════════════════════════════════
_extract_version_suffix() {
    local ref="$1"
    local v
    v="$(_strip_version_prefix "$ref")"
    # Only return it if the result starts with a digit
    [[ "$v" =~ ^[0-9] ]] && printf '%s' "$v" || true
}

# ══════════════════════════════════════════════════════════════════════════
#  _tag_to_display  —  convert a raw git tag/branch to a human-readable name
#
#  The raw tag is always preserved for git operations; this is display-only.
#
#  Examples:
#    mainline/staging   wine-10.6         →  Wine 10.6
#    staging            wine-staging-10.6 →  Wine Staging 10.6
#    proton             proton_9.0        →  Valve Bleeding Edge 9.0
#    kron4ek            wine-10.6         →  Kron4ek Wine 10.6
# ══════════════════════════════════════════════════════════════════════════
_tag_to_display() {
    local tag="$1" key="$2"
    local ver
    ver="$(_strip_version_prefix "$tag")"

    case "$key" in
        mainline|experimental|tkg-patched)
            printf 'Wine %s' "$ver"
            ;;
        staging)
            printf 'Wine Staging %s' "$ver"
            ;;
        proton|proton-experimental)
            printf 'Valve Bleeding Edge %s' "$ver"
            ;;
        kron4ek)
            printf 'Kron4ek Wine %s' "$ver"
            ;;
        *)
            printf '%s' "$tag"
            ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════
#  pick_version
#
#  Queries the remote with `git ls-remote` (no clone required — just a
#  lightweight ref listing) and presents the available versions.
#
#  Sets the global _src_branch to the chosen tag/branch, or leaves it at
#  the catalogue default if "Latest" is selected.
#
#  Silently skips (uses the default) when any of these are true:
#    • stdin is not a terminal (scripted / piped run)
#    • --branch was already given on the command line
#    • the source is not in SOURCE_HAS_VERSIONS
#    • git ls-remote fails or returns nothing (network unavailable etc.)
# ══════════════════════════════════════════════════════════════════════════
pick_version() {
    local url="$1" key="$2"

    # Only run interactively, only for versioned sources, only when the
    # user hasn't already pinned a branch with --branch
    [ -t 0 ]                                          || return 0
    [ "${SOURCE_HAS_VERSIONS[$key]:-false}" = "true" ] || return 0
    [ -z "$WINE_SOURCE_BRANCH" ]                       || return 0

    section "Version selection"

    local ref_type="${SOURCE_VERSION_REF_TYPE[$key]:-tags}"
    msg2 "Fetching available versions from remote…"
    msg2 "(this takes a few seconds — querying $url)"

    # git ls-remote prints:  <sha>TAB<refname>
    # We extract just the short ref name, filter to version-looking entries,
    # and sort with version-aware sort newest-first.
    local -a versions=()
    local raw_refs
    if ! raw_refs=$(
            git ls-remote --"${ref_type}" --refs "$url" 2>/dev/null \
            | awk '{print $2}' \
            | sed "s|refs/${ref_type}/||" \
            | grep -E '^(wine-[0-9]+\.[0-9]|wine-staging-[0-9]+\.[0-9]|proton_[0-9]+\.[0-9]|v[0-9]+\.[0-9]|[0-9]+\.[0-9])' \
            | grep -v -- '-rc'   \
            | sort -Vr
        ); then
        warn "Could not fetch version list — using default branch."
        return 0
    fi

    # Build the array; bail gracefully if the remote returned nothing useful
    while IFS= read -r v; do
        [ -n "$v" ] && versions+=("$v")
    done <<< "$raw_refs"

    if [ "${#versions[@]}" -eq 0 ]; then
        warn "No version tags found for this source — using default branch."
        return 0
    fi

    ok "Found ${#versions[@]} release(s) — showing newest first"
    printf "  ${C_DIM}(release candidates hidden; use --branch to pin an RC explicitly)${C_R}\n\n"

    local latest_label="Latest  (default — most recent commit)"
    local manual_label="[ Type a tag or branch name manually ]"

    # Build tab-delimited lines:  raw_tag TAB Display Name
    # fzf --with-nth=2 shows only the display column; raw tag recovered by cut.
    # This is subshell-safe — no parallel arrays needed.
    local -a tag_pairs=()
    for _v in "${versions[@]}"; do
        tag_pairs+=("${_v}"$'\t'"$(_tag_to_display "$_v" "$key")")
    done

    # ── fzf path ────────────────────────────────────────────────────────
    if command -v fzf >/dev/null 2>&1; then
        local picked_line
        picked_line=$(
            { printf '%s\n' "__latest__"$'\t'"${latest_label}";
              printf '%s\n' "${tag_pairs[@]}";
              printf '%s\n' "__manual__"$'\t'"${manual_label}"; } \
            | fzf \
                --prompt="Version > " \
                --header="Select a version to build   (Enter = confirm, Ctrl-C = Latest)" \
                --with-nth=2 \
                --delimiter=$'\t' \
                --preview='
                    raw=$(printf "%s" "{1}")
                    label=$(printf "%s" "{2}")
                    case "$raw" in
                        __latest__) printf "Build the tip of the default branch.\nNo version suffix added to the install directory.\n" ;;
                        __manual__) printf "You will be prompted to type a tag or branch name.\n" ;;
                        *)          printf "%s\n\ngit tag: %s\n" "$label" "$raw" ;;
                    esac' \
                --preview-window="right:38%:wrap" \
                --height=50% \
                --border \
            || true
        )

        [ -n "$picked_line" ] || { ok "Using latest (default branch)"; return 0; }

        local picked_raw
        picked_raw="$(printf '%s' "$picked_line" | cut -d$'\t' -f1)"

        case "$picked_raw" in
            __latest__)
                ok "Using latest (default branch)"
                return 0
                ;;
            __manual__)
                printf "\n  ${C_B}Tag or branch name:${C_R} "
                read -r _src_branch
                return 0
                ;;
            *)
                _src_branch="$picked_raw"
                local picked_label
                picked_label="$(printf '%s' "$picked_line" | cut -d$'\t' -f2)"
                ok "Selected: ${picked_label}  (tag: ${_src_branch})"
                return 0
                ;;
        esac
    fi

    # ── bash select fallback ─────────────────────────────────────────────
    local display_limit=30
    local -a trunc_display=()
    local -a trunc_raw=()
    local i=0
    for i in "${!versions[@]}"; do
        trunc_raw+=("${versions[$i]}")
        trunc_display+=("$(_tag_to_display "${versions[$i]}" "$key")")
        [ "$(( i + 1 ))" -ge "$display_limit" ] && break
    done
    [ "${#versions[@]}" -gt "$display_limit" ] && \
        dim "  (${#versions[@]} total; showing newest ${display_limit} — use --branch for older)"

    local -a menu_items=( "$latest_label" "${trunc_display[@]}" "$manual_label" )
    PS3="  Version: "
    local picked_display
    select picked_display in "${menu_items[@]}"; do
        case "$picked_display" in
            "$latest_label")
                ok "Using latest (default branch)"
                break
                ;;
            "$manual_label"|"")
                printf "  ${C_B}Tag or branch name:${C_R} "
                read -r _src_branch
                break
                ;;
            *)
                for i in "${!trunc_display[@]}"; do
                    if [ "${trunc_display[$i]}" = "$picked_display" ]; then
                        _src_branch="${trunc_raw[$i]}"
                        ok "Selected: ${picked_display}  (tag: ${_src_branch})"
                        break
                    fi
                done
                break
                ;;
        esac
    done
    PS3=""

    [ -n "$_src_branch" ] || ok "Using latest"
}

# ══════════════════════════════════════════════════════════════════════════
#  pick_build_name  — interactive prompt for the install directory name
#
#  Asks for a base name (e.g. "my-wine" or "wine-gaming").
#  The Wine version string is appended automatically after the build,
#  so the final directory will be e.g. "my-wine-10.4".
#
#  Skipped when --name was given on the CLI, in non-interactive mode,
#  or when the source already forced a specific name (local / custom).
# ══════════════════════════════════════════════════════════════════════════
pick_build_name() {
    # Only prompt interactively when /dev/tty is available and --name wasn't given
    [ -e /dev/tty ] || return 0
    [ -z "$BUILD_NAME" ] || return 0

    # Compute the name the builder would auto-generate so we can show it
    local _vsuffix
    _vsuffix="$(_extract_version_suffix "${_src_branch:-}")"
    local _auto_name
    if [ -n "$_vsuffix" ]; then
        _auto_name="wine-${WINE_SOURCE_KEY}-${_vsuffix}"
    else
        _auto_name="wine-${WINE_SOURCE_KEY}"
    fi

    section "Build name"
    printf "  Enter a name for this Wine build.\n"
    printf "  The Wine version will be appended automatically.\n"
    printf "  ${C_DIM}Example: my-wine  →  my-wine-10.4${C_R}\n\n"
    printf "  ${C_B}Build name${C_R} [default: ${_auto_name}]: "

    local _input
    read -r _input </dev/tty
    if [ -n "$_input" ]; then
        BUILD_NAME="$(printf '%s' "$_input" \
            | tr ' ' '-' \
            | tr -cd 'a-zA-Z0-9._-' \
            | sed 's/--*/-/g; s/^-//; s/-$//')"
        [ -n "$BUILD_NAME" ] || BUILD_NAME="$_auto_name"
        ok "Build name: ${BUILD_NAME}"
    else
        # Leave BUILD_NAME empty — the auto-derivation below will fill it in
        ok "Build name: ${_auto_name}  (default)"
    fi
}

# ══════════════════════════════════════════════════════════════════════════
#  pick_build_options  — interactive wizard for build tuning
#
#  Opens with a single yes/no: "change build options?"
#  Answering N (or Enter) skips all questions and keeps defaults — no more
#  answering 6 questions just to accept everything.
#  Skipped entirely when --jobs / --no-ccache / etc. were given on the CLI,
#  or in non-interactive mode.
# ══════════════════════════════════════════════════════════════════════════
pick_build_options() {
    [ -e /dev/tty ] || return 0

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
#
#  Scans common locations for directories that look like Wine source trees
#  (they have both a configure script and a dlls/ subdirectory).
#
#  If fzf is available: pretty fuzzy-finder with a preview pane.
#  Otherwise: bash select menu with a manual-entry fallback.
# ══════════════════════════════════════════════════════════════════════════
pick_local_dir() {
    section "Local source picker"

    # ── Candidate scan ──────────────────────────────────────────────────
    local -a candidates=()
    local -a search_roots=( "${SRC_ROOT}" "${DEST_ROOT}" "${HOME}" /opt /usr/local/src )
    msg2 "Scanning for Wine source trees (configure + dlls/)..."

    local cfg_path wine_dir
    while IFS= read -r cfg_path; do
        wine_dir="${cfg_path%/configure}"
        [ -d "${wine_dir}/dlls" ] && candidates+=("$wine_dir")
    done < <(
        find "${search_roots[@]}" -maxdepth 6 -name "configure" 2>/dev/null \
        | grep -i wine \
        | sort -u
    )

    if [ "${#candidates[@]}" -eq 0 ]; then
        msg2 "No Wine source trees auto-detected — you can type a path manually."
    else
        msg2 "Found ${#candidates[@]} candidate(s)."
    fi

    local manual_entry="[ Enter path manually ]"

    # ── fzf path ────────────────────────────────────────────────────────
    if command -v fzf >/dev/null 2>&1; then
        local picked
        picked=$(
            { printf '%s\n' "${candidates[@]+"${candidates[@]}"}"; printf '%s\n' "$manual_entry"; } \
            | fzf \
                --prompt="Wine source > " \
                --header="Select a Wine source tree   (Ctrl-C / q to type path manually)" \
                --preview='
                    d="{}"
                    if [ "$d" = "'"${manual_entry}"'" ]; then
                        printf "(you will be prompted to type a path)\n"
                    else
                        printf "── dlls/ (first 20) ──\n"
                        ls "$d/dlls" 2>/dev/null | head -20
                        printf "\n── configure modified ──\n"
                        stat -c "%y" "$d/configure" 2>/dev/null || true
                        printf "\n── git log (last 3) ──\n"
                        git -C "$d" log --oneline -3 2>/dev/null || true
                    fi' \
                --preview-window="right:38%:wrap" \
                --height=55% \
                --border \
            || true
        )

        if [ -z "$picked" ] || [ "$picked" = "$manual_entry" ]; then
            printf "\n  ${C_B}Full path to Wine source directory:${C_R} "
            read -r LOCAL_SOURCE_DIR
        else
            LOCAL_SOURCE_DIR="$picked"
        fi
        return
    fi

    # ── bash select fallback ─────────────────────────────────────────────
    local -a menu_items=( "${candidates[@]+"${candidates[@]}"}" "$manual_entry" )
    printf "\n  ${C_B}Detected Wine source trees:${C_R}\n\n"
    PS3="  Choice: "
    select item in "${menu_items[@]}"; do
        if [ "$item" = "$manual_entry" ] || [ -z "$item" ]; then
            printf "  ${C_B}Full path to Wine source directory:${C_R} "
            read -r LOCAL_SOURCE_DIR
        else
            LOCAL_SOURCE_DIR="$item"
        fi
        break
    done
    PS3=""
}

# ══════════════════════════════════════════════════════════════════════════
#  _find_tkg_script  —  locate the build script for a TKG-style source
#
#  Search order:
#    1. Known exact relative paths from SOURCE_TKG_PATHS (colon-separated).
#       These are checked first so we hit the right script even when the repo
#       contains several .sh files sharing the same filename.
#    2. Generic find by filename (SOURCE_TKG_SCRIPTS) up to maxdepth 8.
#    3. Interactive picker scanning all .sh files up to depth 5, so deeper
#       scripts are visible instead of just the shallow root-level ones.
#
#  Prints the resolved absolute path to stdout; returns 1 if nothing found.
# ══════════════════════════════════════════════════════════════════════════
_find_tkg_script() {
    local src="$1" key="$2"

    # ── Step 1: check known exact relative paths ─────────────────────────
    local rel found
    IFS=':' read -ra _known_paths <<< "${SOURCE_TKG_PATHS[$key]:-}"
    for rel in "${_known_paths[@]}"; do
        [ -z "$rel" ] && continue
        if [ -f "${src}/${rel}" ]; then
            printf '%s' "${src}/${rel}"
            return 0
        fi
    done

    # ── Step 2: generic find by filename ─────────────────────────────────
    local name
    for name in ${SOURCE_TKG_SCRIPTS[$key]:-non-makepkg-build.sh}; do
        found=$(find "$src" -maxdepth 8 -name "$name" 2>/dev/null \
                | grep -v '/proton-tkg/' \
                | head -1 || true)
        if [ -n "$found" ]; then
            printf '%s' "$found"
            return 0
        fi
    done

    # ── Step 3: fallback interactive picker ──────────────────────────────
    # Scan to depth 5 for .sh files.
    # Exclude wine-tkg-scripts/ (those are helper modules sourced by the entry
    # point, not standalone scripts) and proton-tkg/ (separate product).
    local -a root_scripts=()
    while IFS= read -r s; do
        root_scripts+=("$s")
    done < <(
        find "$src" -maxdepth 5 -type f -name "*.sh" 2>/dev/null \
        | grep -v '/proton-tkg/' \
        | grep -v '/wine-tkg-scripts/' \
        | sort
    )

    if [ "${#root_scripts[@]}" -eq 0 ]; then
        return 1
    fi

    printf "\n${C_YLW}warn${C_R} Known script path not found in %s\n" "$src" >&2
    printf "${C_YLW}warn${C_R} Expected relative path: %s\n\n" \
        "${SOURCE_TKG_PATHS[$key]:-${SOURCE_TKG_SCRIPTS[$key]:-non-makepkg-build.sh}}" >&2
    printf "  ${C_B}Scripts found in the repo — pick one, or choose Abort:${C_R}\n\n" >&2

    local i=1
    for s in "${root_scripts[@]}"; do
        printf "  ${C_CYN}%d)${C_R} %s\n" "$i" "${s#${src}/}" >&2
        i=$(( i + 1 ))
    done
    printf "  ${C_CYN}%d)${C_R} Abort\n\n" "$i" >&2

    local pick
    printf "  Choice [1-%d]: " "$i" >&2
    read -r pick </dev/tty || pick=""

    if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -lt "$i" ]; then
        printf '%s' "${root_scripts[$(( pick - 1 ))]}"
        return 0
    fi

    return 1
}

# ══════════════════════════════════════════════════════════════════════════
#  handle_tkg_source
#
#  wine-tkg ships a full build framework rather than a bare Wine
#  source tree.  After cloning we stop and explain the options before
#  proceeding so users don't end up with a broken half-build.
#
#  Option 1 — Full delegation: exec the TKG build script (replaces this process)
#  Option 2 — Hybrid: run the TKG script's prepare step, then hand the
#             prepared wine source tree to wine-build-core.sh
#  Option 3 — Abort cleanly
# ══════════════════════════════════════════════════════════════════════════
handle_tkg_source() {
    local src="$1"
    section "TKG build-system source"

    printf "\n"
    msg "${SOURCE_DESC[$WINE_SOURCE_KEY]}"
    printf "\n"
    printf "  This source is a ${C_B}build-system framework${C_R}, not a plain Wine source tree.\n"
    printf "  It contains its own script, patchsets, and per-option configuration.\n"
    printf "\n"
    printf "  ${C_B}1) Delegate  (recommended)${C_R}\n"
    printf "     Hand everything to the repo's own build script.\n"
    printf "     ${C_DIM}Full feature set; all patches applied as upstream intends.${C_R}\n"
    printf "\n"
    printf "  ${C_B}2) Hybrid${C_R}\n"
    printf "     Run the repo's prepare step only (fetches wine source + applies patches).\n"
    printf "     wine-builder then handles compile + install.\n"
    printf "     ${C_DIM}Useful when you want wine-builder's log management and install layout.${C_R}\n"
    printf "\n"
    printf "  ${C_B}3) Abort${C_R}\n"
    printf "     Exit cleanly — no changes made.\n"
    printf "\n"

    # Resolve the build script before asking the user so we can report what
    # was found (or warn if nothing was) before they commit to a choice.
    local tkg_script=""
    tkg_script=$( _find_tkg_script "$src" "$WINE_SOURCE_KEY" ) || true

    if [ -n "$tkg_script" ]; then
        msg2 "Build script found: ${tkg_script#${src}/}"
    else
        warn "No build script found in ${src}."
        warn "Options 1 and 2 require a build script."
        warn "You can still choose 3 (Abort) and inspect the repo manually."
    fi
    printf "\n"

    local choice
    printf "  ${C_B}Choice [1-3, default 1]:${C_R} "
    read -r choice || choice="1"

    case "${choice:-1}" in
        # ── Option 2: hybrid ──────────────────────────────────────────
        2)
            if [ -z "$tkg_script" ]; then
                err "Cannot run hybrid mode: no build script was found in ${src}.
     Check the repo contents:  ls \"${src}\"
     Then re-run with --source local --local-dir pointing at your prepared
     wine source tree once you have run the repo's setup manually."
            fi
            printf "\n"
            warn "The build script will ask interactive questions."
            warn "When it offers a compile step, ${C_B}decline / select 'no'${C_R} — wine-builder"
            warn "handles compilation.  Look for a 'prepare only' or 'no build' option."
            printf "\n"
            ( cd "$(dirname "$tkg_script")" && bash "$(basename "$tkg_script")" )

            # Locate the prepared wine source tree that the script deposited
            local wine_src_found=""
            wine_src_found=$(
                find "$src" -maxdepth 8 -name "configure" 2>/dev/null \
                | while IFS= read -r f; do
                    _d="${f%/configure}"
                    [ -d "${_d}/dlls" ] && printf '%s\n' "${_d}"
                  done \
                | head -1 \
                || true
            )

            if [ -n "$wine_src_found" ]; then
                ok "Wine source tree found at: $wine_src_found"
                WINE_SOURCE_DIR="$wine_src_found"
                BUILD_NAME="${BUILD_NAME:-${WINE_SOURCE_KEY}-hybrid}"
            else
                printf "\n"
                warn "No wine source tree found inside ${src} after the prepare step."
                warn "The prepare step may not have completed, or the source landed in"
                warn "an unexpected location."
                printf "\n  ${C_DIM}Re-run manually with:${C_R}\n"
                printf "  ${C_DIM}  $0 --source local --local-dir <path-to-prepared-wine-src>${C_R}\n"
                exit 1
            fi
            ;;

        # ── Option 3: abort ───────────────────────────────────────────
        3)
            msg "Aborted — no changes made."
            exit 0
            ;;

        # ── Option 1 (default): full delegation ───────────────────────
        *)
            if [ -z "$tkg_script" ]; then
                err "Cannot delegate: no build script was found in ${src}.
     Check the repo contents:  ls \"${src}\"
     The clone may be incomplete — try:
       git -C \"${src}\" fetch --unshallow"
            fi
            msg "Delegating to: $tkg_script"
            msg2 "Pre-selecting profile: default-tkg (edit TKG's customization.cfg to change)"
            printf "\n"
            cd "$(dirname "$tkg_script")"
            # _LOCAL_PRESET is read from TKG's own customization.cfg, not the environment.
            # Patch it in-place before exec so the profile prompt is skipped.
            # "none" = use the default config files without prompting, equivalent to
            # choosing default-tkg at the prompt.
            # We only write it if the line is currently empty (i.e. user hasn't set it
            # themselves), so a manual choice in the cfg is always respected.
            local _tkg_cfg="customization.cfg"
            # Back up TKG's cfg before we modify it so we can restore it
            # afterward.  This prevents our changes from permanently dirtying
            # the TKG source tree across git pulls and future runs.
            local _tkg_cfg_backup="${_tkg_cfg}.looni_backup"
            cp "$_tkg_cfg" "$_tkg_cfg_backup" 2>/dev/null && \
                msg2 "Backed up TKG's customization.cfg" || \
                warn "Could not back up customization.cfg — changes will persist"

            if [ -f "$_tkg_cfg" ] && \
               grep -qE '^_LOCAL_PRESET=""' "$_tkg_cfg" 2>/dev/null; then
                sed -i 's|^_LOCAL_PRESET=""|_LOCAL_PRESET="none"|' "$_tkg_cfg"
                msg2 "Set _LOCAL_PRESET=\"none\" in TKG's customization.cfg"
            fi
            # Redirect TKG's install output into our buildz/install/ directory.
            # _nomakepkg_prefix_path tells TKG where to install:
            #   final path = ${_nomakepkg_prefix_path}/${_nomakepkg_pkgname}
            # We only write it if the line is currently empty so a user who has
            # already set a custom path in TKG's cfg is always respected.
            local _tkg_install_root="${DEST_ROOT}/install"
            if [ -f "$_tkg_cfg" ] && \
               grep -qE '^_nomakepkg_prefix_path=""' "$_tkg_cfg" 2>/dev/null; then
                sed -i "s|^_nomakepkg_prefix_path=\"\"|_nomakepkg_prefix_path=\"${_tkg_install_root}\"|" \
                    "$_tkg_cfg"
                msg2 "Set _nomakepkg_prefix_path=\"${_tkg_install_root}\" in TKG's customization.cfg"
            fi
            # Deploy our updated deps file into TKG's scripts directory.
            # deps-tkg in the builder root is the Ubuntu 24.04-compatible version;
            # it gets copied as deps so TKG picks it up under its expected name.
            local _deps_src="${_LIB_DIR}/deps-tkg"
            local _deps_dst="wine-tkg-scripts/deps"
            if [ -f "$_deps_src" ]; then
                cp "$_deps_src" "$_deps_dst" \
                    && msg2 "Deployed deps-tkg → wine-tkg-scripts/deps" \
                    || warn "Could not copy deps-tkg to wine-tkg-scripts/deps — TKG will use its own"
            else
                warn "deps-tkg not found at ${_deps_src} — TKG will use its own dependency file"
                warn "Copy your updated deps file to ${_deps_src} to have it deployed automatically"
            fi
            # Run TKG in the foreground (not exec) so we can restore the cfg
            # after it finishes.  The experience is identical to exec for the
            # user — TKG has full terminal control throughout.
            bash "$(basename "$tkg_script")"
            local _tkg_exit=$?
            # Restore the original cfg unconditionally so TKG's tree stays clean
            # for git pulls and future runs.
            if [ -f "$_tkg_cfg_backup" ]; then
                mv "$_tkg_cfg_backup" "$_tkg_cfg" \
                    && msg2 "Restored TKG's customization.cfg" \
                    || warn "Could not restore customization.cfg — check ${_tkg_cfg_backup}"
            fi
            exit $_tkg_exit
            # (exit propagates TKG's own exit code back to the caller)
    esac
}

# ══════════════════════════════════════════════════════════════════════════
#  Dependency pre-flight check
# ══════════════════════════════════════════════════════════════════════════
check_deps() {
    section "Dependency check"
    local -a missing=()
    local -a optional_missing=()

    # Hard requirements (build will fail without these)
    local -a hard=(
        git make gcc g++ autoreconf python3 perl flex bison pkg-config
        i686-linux-gnu-gcc i686-linux-gnu-g++
        i686-w64-mingw32-gcc x86_64-w64-mingw32-gcc
    )
    # Nice-to-haves
    local -a soft=( ccache patch rsync fzf )

    local cmd
    for cmd in "${hard[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            ok "$cmd"
        else
            printf "${C_RED} ✗  %-36s${C_DIM}(required)${C_R}\n" "$cmd"
            missing+=("$cmd")
        fi
    done

    for cmd in "${soft[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            printf "${C_GRN} ✓  ${C_R}%-28s${C_DIM}(optional)${C_R}\n" "$cmd"
        else
            printf "${C_YLW} ⚠  %-28s${C_DIM}(optional)${C_R}\n" "$cmd"
            optional_missing+=("$cmd")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        printf "\n"
        err "Missing required tools: ${missing[*]}

     On Debian/Ubuntu:
       sudo apt install build-essential gcc-i686-linux-gnu g++-i686-linux-gnu \\
           gcc-mingw-w64 g++-mingw-w64 git python3 perl flex bison autoconf \\
           automake pkg-config

     Also add i386 architecture for 32-bit support:
       sudo dpkg --add-architecture i386 && sudo apt update
       sudo apt install libx11-dev:i386 libvulkan-dev:i386 libfreetype-dev:i386"
    fi

    if [ "${#optional_missing[@]}" -gt 0 ]; then
        printf "\n"
        warn "Optional tools not found: ${optional_missing[*]}"
        warn "  ccache  → speeds up incremental rebuilds significantly"
        warn "  fzf     → enables the fuzzy-finder local source picker"
        warn "  rsync   → used by install-from-build.sh"
    fi
}

# ══════════════════════════════════════════════════════════════════════════
#  Disk space pre-flight
#  A full Wine build (source + wine64 + wine32 trees) needs ~10 GB.
# ══════════════════════════════════════════════════════════════════════════
check_disk_space() {
    local target_dir="$1"
    local required_gb=10
    mkdir -p "$target_dir" 2>/dev/null || true

    local avail_kb avail_gb
    avail_kb=$(df -Pk "$target_dir" 2>/dev/null | awk 'NR==2 {print $4}' || printf '0')
    avail_gb=$(( avail_kb / 1024 / 1024 ))

    if [ "$avail_gb" -lt "$required_gb" ]; then
        warn "Low disk space: ${avail_gb} GB available in ${target_dir}"
        warn "Recommend at least ${required_gb} GB — build may fail partway."
        warn "Use --dest to point to a filesystem with more space."
    else
        ok "Disk space: ${avail_gb} GB available (≥${required_gb} GB required)"
    fi
}

# ══════════════════════════════════════════════════════════════════════════
#  OpenCL header compatibility symlink
#  Wine's configure looks for /usr/include/OpenCL/opencl.h (macOS layout).
#  On Linux the header lives at /usr/include/CL/cl.h — create a symlink.
# ══════════════════════════════════════════════════════════════════════════
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
        sudo mkdir -p /usr/include/OpenCL
        sudo ln -sf "$linux_h" "$compat_h" \
            || err "Could not create $compat_h — run manually:
       sudo mkdir -p /usr/include/OpenCL
       sudo ln -sf $linux_h $compat_h"
        ok "OpenCL compat symlink created"
    else
        dim "  [dry-run] sudo mkdir -p /usr/include/OpenCL && sudo ln -sf $linux_h $compat_h"
    fi
}

# ══════════════════════════════════════════════════════════════════════════
#  Git source fetch / update
# ══════════════════════════════════════════════════════════════════════════
fetch_source() {
    local url="$1" branch="$2" dest="$3" shallow="${4:-true}"

    if [ -d "$dest/.git" ]; then
        # Check the existing clone's remote URL matches what we expect.
        # If it doesn't (e.g. staging src dir was previously a patch repo clone),
        # wipe it and re-clone from the correct URL.
        local existing_url
        existing_url="$(git -C "$dest" remote get-url origin 2>/dev/null || true)"
        if [ -n "$existing_url" ] && [ "$existing_url" != "$url" ]; then
            warn "Existing clone at $dest has a different remote:"
            warn "  expected : $url"
            warn "  found    : $existing_url"
            warn "Removing stale clone and re-cloning from the correct URL..."
            rm -rf "$dest"
            # fall through to the clone path below
        fi
    fi

    if [ -d "$dest/.git" ]; then
        if [ "$NO_PULL" = true ]; then
            ok "Source exists — --no-pull set, skipping update"
        else
            msg2 "Updating existing source: $dest"
            if [ "$DRY_RUN" -eq 0 ]; then
                git -C "$dest" fetch --prune --tags
                if [ -n "$branch" ]; then
                    git -C "$dest" checkout "$branch"
                fi
                git -C "$dest" pull --ff-only \
                    || warn "git pull failed (diverged?). Continuing with current state."
            else
                dim "  [dry-run] git -C $dest fetch && git pull"
            fi
        fi
    else
        msg2 "Cloning: $url"
        [ -n "$branch" ] && msg2 "Branch / tag: $branch"
        if [ "$DRY_RUN" -eq 0 ]; then
            mkdir -p "$(dirname "$dest")"
            local _clone_depth_arg=""
            [ "$shallow" = "true" ] && _clone_depth_arg="--depth=1"
            if [ -n "$branch" ]; then
                git clone $_clone_depth_arg --branch "$branch" "$url" "$dest"
            else
                git clone $_clone_depth_arg "$url" "$dest"
            fi
            ok "Cloned to: $dest"
        else
            dim "  [dry-run] git clone $url $dest"
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════════
#  Pre-generate headers that makedep needs before configure runs
# ══════════════════════════════════════════════════════════════════════════
pregen_headers() {
    local src="$1"
    section "Pre-generating headers"

    # wine/vulkan.h  (Python script in source tree)
    local vulkan_out="$src/include/wine/vulkan.h"
    local vulkan_script="$src/dlls/winevulkan/make_vulkan"
    if [ ! -f "$vulkan_out" ]; then
        msg2 "Generating wine/vulkan.h ..."
        if [ -f "$vulkan_script" ]; then
            if [ "$DRY_RUN" -eq 0 ]; then
                ( cd "$src" && python3 dlls/winevulkan/make_vulkan ) \
                    || err "make_vulkan failed. Install: sudo apt install python3 vulkan-headers"
                ok "wine/vulkan.h generated"
            else
                dim "  [dry-run] python3 dlls/winevulkan/make_vulkan"
            fi
        else
            warn "make_vulkan not found — skipping vulkan.h (may cause configure errors later)"
        fi
    else
        ok "wine/vulkan.h  (already present)"
    fi

    # ntsyscalls.h  (Perl — Wine 10.x+, not present in all trees)
    local ntsys_out="$src/dlls/ntdll/ntsyscalls.h"
    local specfiles="$src/tools/make_specfiles"
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

    # server_protocol.h  (Perl — regenerated if make_requests is newer)
    local proto_out="$src/include/wine/server_protocol.h"
    local make_req="$src/tools/make_requests"
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

# ══════════════════════════════════════════════════════════════════════════
#  autoreconf
# ══════════════════════════════════════════════════════════════════════════
run_autoreconf() {
    local src="$1"
    section "autoreconf"
    msg2 "Regenerating configure in: $src"
    if [ "$DRY_RUN" -eq 0 ]; then
        ( cd "$src" && autoreconf -fiv )
        ok "autoreconf complete"
    else
        dim "  [dry-run] autoreconf -fiv in $src"
    fi
}

# ══════════════════════════════════════════════════════════════════════════
#  _install_logged  — run make install with a magenta/cyan progress bar
#
#  Tracks lines matching "tools/install" to count files being installed.
#  Falls back to plain output in non-interactive or --verbose mode.
#  Usage: _install_logged [make args…]   (install target appended automatically)
# ══════════════════════════════════════════════════════════════════════════
_install_logged() {
    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        run make "$@" install; return
    fi

    # Write the progress bar directly to /dev/tty so it works regardless of
    # whether stdout is a pipe, redirected, or anything else.  Only skip the
    # bar when /dev/tty is unavailable (non-interactive CI) or --verbose set.
    local _use_bar=false
    if [ -e /dev/tty ] && [ "${VERBOSE_BUILD:-false}" != "true" ]; then
        _use_bar=true
    fi

    # ── Detect which install-line pattern this Wine tree uses ────────────
    # Valve/proton-wine: Wine's own tools/install script
    # Mainline / kron4ek / staging: the system /usr/bin/install -c
    # We sniff a few lines from the dry-run to pick the right pattern.
    local _install_pat='install -[cm]'   # matches both by default
    local _total=0
    if [ "$_use_bar" = "true" ]; then
        printf "${C_DIM}  Counting install steps...${C_R}" > /dev/tty
        _total=$(
            timeout 20 make "$@" install -n 2>/dev/null \
            | grep -cE '(tools/install|install -[cm])' || true
        )
        printf "\r\033[K" > /dev/tty
        [ "$_total" -eq 0 ] && _total=1
    fi

    if [ "$_use_bar" = "true" ]; then
        local _cur=0 _start _make_exit _tmp_out _last_dest
        _tmp_out=$(mktemp)
        _start=$(date +%s)
        _last_dest="..."

        # Reserve 2 lines on the terminal for the HUD
        printf "\n\n" > /dev/tty

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
            {
                printf "\033[2A"
                printf "\033[K${C_MAG}  [%s] %3d%%${C_R}  ${C_DIM}(%d / %d)${C_R}\n" \
                    "$bar" "$pct" "$cur" "$tot"
                printf "\033[K  ${C_CYN}elapsed${C_R} %-10s  ${C_CYN}installing${C_R} %s\n" \
                    "$estr" "$phase"
            } > /dev/tty
        }

        _draw_install 0 "$_total" "starting..." "$_start"

        set +e
        make "$@" install > "$_tmp_out" 2>&1 &
        local _make_pid=$!

        # One redraw per 0.1 s cycle — batch-process all lines that arrived
        # since the last cycle so rapid installs don't flood the terminal.
        while kill -0 "$_make_pid" 2>/dev/null || [ -s "$_tmp_out" ]; do
            local _batch_dest=""
            while IFS= read -r _line; do
                printf '%s\n' "$_line" >> "${BUILD_LOG:-/dev/null}"
                if printf '%s' "$_line" | grep -qE '(tools/install|install -[cm])'; then
                    _cur=$(( _cur + 1 ))
                    _batch_dest=$(printf '%s' "$_line" | grep -oE '[^ ]+$' | tail -1)
                    _batch_dest="${_batch_dest##*/}"
                fi
            done < "$_tmp_out"
            [ -n "$_batch_dest" ] && _last_dest="$_batch_dest"
            kill -0 "$_make_pid" 2>/dev/null && > "$_tmp_out" || break
            _draw_install "$_cur" "$_total" "$_last_dest" "$_start"
            sleep 0.1
        done

        wait "$_make_pid"; _make_exit=$?
        while IFS= read -r _line; do
            printf '%s\n' "$_line" >> "${BUILD_LOG:-/dev/null}"
        done < "$_tmp_out"
        rm -f "$_tmp_out"
        set -e

        _draw_install "$_total" "$_total" "complete ✓" "$_start"
        printf "\n" > /dev/tty

        [ "$_make_exit" -ne 0 ] && return "$_make_exit"
    else
        make "$@" install 2>&1 | tee -a "${BUILD_LOG:-/dev/null}"
    fi
}

# ══════════════════════════════════════════════════════════════════════════
#  Install
# ══════════════════════════════════════════════════════════════════════════
install_wine() {
    local build_run="$1" prefix="$2"
    section "Installing Wine"

    run rm -rf "$prefix"
    run mkdir -p "$prefix"

    # Apply strip flag — KEEP_SYMBOLS=true means we skip stripping
    local _wstrip=""
    [ "${KEEP_SYMBOLS:-false}" = "true" ] && _wstrip="STRIP=true"

    local arch
    for arch in wine64 wine32; do
        if [ -d "${build_run}/${arch}" ]; then
            msg2 "Installing ${arch} components..."
            if [ "$DRY_RUN" -eq 0 ]; then
                _install_logged \
                    -C "${build_run}/${arch}" \
                    prefix="$prefix" \
                    libdir="$prefix/lib" \
                    dlldir="$prefix/lib/wine" \
                    ${_wstrip}
            else
                dim "  [dry-run] make install in ${build_run}/${arch}"
            fi
            ok "${arch} installed"
        else
            warn "Build directory not found: ${build_run}/${arch} — skipping"
        fi
    done

    ok "Wine installed to: $prefix"
}

# ══════════════════════════════════════════════════════════════════════════
#  Build summary
# ══════════════════════════════════════════════════════════════════════════
print_summary() {
    local prefix="$1" elapsed="$2"
    printf "\n${C_GRN}${C_B}"
    printf "  ╔═══════════════════════════════════════════════════════════╗\n"
    printf "  ║                  Build complete!  🎉                      ║\n"
    printf "  ╚═══════════════════════════════════════════════════════════╝\n"
    printf "${C_R}\n"
    printf "  ${C_B}Installed to:${C_R}  %s\n"           "$prefix"
    printf "  ${C_B}wine binary: ${C_R}  %s/bin/wine\n"  "$prefix"
    # wine64 was dropped as a separate binary in Wine 8+; only print if present
    [ -f "$prefix/bin/wine64" ] && \
        printf "  ${C_B}wine64:      ${C_R}  %s/bin/wine64\n" "$prefix" || true
    printf "  ${C_B}Build time:  ${C_R}  %s\n"           "$elapsed"
    printf "\n"
    printf "  ${C_DIM}Test:     %s/bin/wine --version${C_R}\n" "$prefix"
    printf "  ${C_DIM}Log:      %s${C_R}\n" "${BUILD_LOG:-n/a}"
    printf "\n"
}

# ══════════════════════════════════════════════════════════════════════════
#  Build manifest
#  Appends a one-line record to buildz/builds.log after every successful
#  build so there's a persistent history of what was built and when.
#  Format: ISO-8601 date | source key | build name | version | elapsed | path
# ══════════════════════════════════════════════════════════════════════════
write_build_manifest() {
    local prefix="$1" elapsed="$2"
    local manifest="${DEST_ROOT}/builds.log"
    mkdir -p "$DEST_ROOT"

    # Try to get the wine version from the installed binary
    local wine_ver="unknown"
    if [ -x "$prefix/bin/wine" ]; then
        wine_ver="$("$prefix/bin/wine" --version 2>/dev/null || true)"
    fi

    # Header line on first use
    if [ ! -f "$manifest" ]; then
        printf '%-20s  %-22s  %-36s  %-28s  %-12s  %s\n' \
            "date" "source" "build-name" "version" "elapsed" "install-path" \
            >> "$manifest"
        printf '%s\n' "$(printf '─%.0s' {1..130})" >> "$manifest"
    fi

    printf '%-20s  %-22s  %-36s  %-28s  %-12s  %s\n' \
        "$(date '+%Y-%m-%d %H:%M')" \
        "${WINE_SOURCE_KEY:-local}" \
        "${BUILD_NAME:-unknown}" \
        "${wine_ver:-unknown}" \
        "$elapsed" \
        "$prefix" \
        >> "$manifest"

    msg2 "Build recorded in: $manifest"
}

# ══════════════════════════════════════════════════════════════════════════
#  Set default Wine — offer to write PATH + WINEPREFIX + WINESERVER
#  into ~/.bashrc with marker comments for clean removal.
# ══════════════════════════════════════════════════════════════════════════
offer_set_wine_default() {
    local prefix="$1"
    local wine_bin="${prefix}/bin"
    local wineserver_bin="${prefix}/bin/wineserver"

    local MARKER_BEGIN='# ── mythix-build wine-default ──'
    local MARKER_END='# ── end mythix-build wine-default ──'
    local RCFILE="${HOME}/.bashrc"

    # Sanity: make sure there's actually a wine binary
    if [ ! -x "${wine_bin}/wine" ]; then
        warn "No wine binary found at ${wine_bin}/wine — skipping default-Wine offer"
        return 0
    fi

    printf "\n"
    printf "  ${C_CYN}${C_B}Set this build as your default Wine?${C_R}\n"
    printf "  This will add the following to ~/.bashrc:\n"
    printf "    ${C_DIM}• PATH        → %s${C_R}\n" "$wine_bin"
    printf "    ${C_DIM}• WINEPREFIX  → \${WINEPREFIX:-\$HOME/.wine}${C_R}\n"
    printf "    ${C_DIM}• WINESERVER  → %s${C_R}\n" "$wineserver_bin"
    printf "  ${C_DIM}(replaces any previous mythix-build wine-default block)${C_R}\n"
    printf "\n  ${C_B}Set as default? [y/N]:${C_R} "
    read -r _ans

    case "$_ans" in
        [yY]|[yY][eE][sS])
            # Remove existing wine-default block if present
            if [ -f "$RCFILE" ] && grep -qF "$MARKER_BEGIN" "$RCFILE"; then
                sed -i "\,^${MARKER_BEGIN}\$,, \,^${MARKER_END}\$, d" "$RCFILE"
                msg2 "Replaced previous wine-default block"
            fi

            # Append new block
            {
                printf '\n%s\n' "$MARKER_BEGIN"
                printf 'export PATH="%s:$PATH"\n' "$wine_bin"
                printf 'export WINEPREFIX="${WINEPREFIX:-$HOME/.wine}"\n'
                printf 'export WINESERVER="%s"\n' "$wineserver_bin"
                printf '%s\n' "$MARKER_END"
            } >> "$RCFILE"

            printf "\n"
            ok "~/.bashrc updated"
            printf "    ${C_DIM}Run:  source ~/.bashrc   (or open a new terminal)${C_R}\n"
            printf "    ${C_DIM}Test: wine --version${C_R}\n\n"
            ;;
        *)
            dim "  Skipped — run wine directly with: ${prefix}/bin/wine"
            printf "\n"
            ;;
    esac
}

print_banner

# ── Source selection ──────────────────────────────────────────────────────
section "Source selection"
[ -z "$WINE_SOURCE_KEY" ] && source_menu

_src_url=""
_src_branch=""

case "$WINE_SOURCE_KEY" in
    local)
        # Use the interactive picker if --local-dir was not supplied
        if [ -z "$LOCAL_SOURCE_DIR" ]; then
            pick_local_dir
        fi
        [ -n "$LOCAL_SOURCE_DIR" ] || err "--source local: no directory selected."
        [ -d "$LOCAL_SOURCE_DIR" ] || \
            err "Local source directory not found: $LOCAL_SOURCE_DIR"
        WINE_SOURCE_DIR="$(realpath "$LOCAL_SOURCE_DIR")"
        BUILD_NAME="${BUILD_NAME:-$(basename "$WINE_SOURCE_DIR")}"
        msg2 "Using local source: $WINE_SOURCE_DIR"
        ;;

    custom)
        [ -n "$WINE_SOURCE_URL" ] || \
            err "--source custom requires --url URL"
        _src_url="$WINE_SOURCE_URL"
        _src_branch="${WINE_SOURCE_BRANCH:-}"
        msg2 "Custom URL: $_src_url"
        ;;

    wine-tkg|kron4ek|mainline|experimental|staging|tkg-patched|proton|proton-experimental)
        _src_url="${SOURCE_URL[$WINE_SOURCE_KEY]}"
        _src_branch="${WINE_SOURCE_BRANCH:-${SOURCE_BRANCH[$WINE_SOURCE_KEY]}}"
        msg2 "Source: ${SOURCE_DESC[$WINE_SOURCE_KEY]}"
        # staging: if --branch was given as a staging tag (v10.4), convert to
        # the matching mainline tag (wine-10.4) and export STAGING_BRANCH so
        # the patcher knows exactly which staging version to apply.
        if [ "$WINE_SOURCE_KEY" = "staging" ] && [ -n "$_src_branch" ]; then
            if [[ "$_src_branch" =~ ^v[0-9] ]]; then
                export STAGING_BRANCH="$_src_branch"
                _src_branch="wine-${_src_branch#v}"
                msg2 "Staging tag ${STAGING_BRANCH} → cloning mainline at ${_src_branch}"
            fi
        fi
        ;;

    *)
        err "Unknown source key: '$WINE_SOURCE_KEY'
     Run '$0 --help' for a list of valid sources."
        ;;
esac

ok "Selected: ${SOURCE_DESC[$WINE_SOURCE_KEY]:-$WINE_SOURCE_KEY}"

# Prompt for extra details when --source custom is used interactively
if [ "$WINE_SOURCE_KEY" = "custom" ] && [ -t 0 ]; then
    if [ -z "${_src_branch}" ]; then
        printf "  ${C_B}Branch / tag (blank for repo default):${C_R} "
        read -r _src_branch
    fi
fi

# ── Version picker ────────────────────────────────────────────────────────
# Runs only for sources listed in SOURCE_HAS_VERSIONS, only interactively,
# and only when --branch was not already supplied.  May update _src_branch.
#
# Special case: staging queries the wine-staging patch repo for its version
# tags (v10.4 etc.) since those are the canonical release markers, but we
# clone mainline WineHQ.  After picking, convert v10.4 → wine-10.4 for git,
# and export STAGING_BRANCH so the patcher uses the exact staging version.
if [ "$WINE_SOURCE_KEY" != "local" ]; then
    if [ "$WINE_SOURCE_KEY" = "staging" ]; then
        _staging_query_url="https://github.com/wine-staging/wine-staging.git"
        pick_version "$_staging_query_url" "$WINE_SOURCE_KEY"
        # _src_branch is now e.g. "v10.4" — convert to mainline tag "wine-10.4"
        if [ -n "$_src_branch" ]; then
            export STAGING_BRANCH="$_src_branch"
            _src_branch="wine-${_src_branch#v}"
            msg2 "Staging tag ${STAGING_BRANCH} → cloning mainline at ${_src_branch}"
        fi
    else
        pick_version "$_src_url" "$WINE_SOURCE_KEY"
    fi
fi

# ── Interactive build name prompt ────────────────────────────────────────
# Only fires for non-local, non-custom sources — those handle naming above.
# Must run after pick_version so _src_branch is known (used for the default).
if [ "$WINE_SOURCE_KEY" != "local" ] && [ "$WINE_SOURCE_KEY" != "custom" ]; then
    pick_build_name
fi

# ── Build options wizard ──────────────────────────────────────────────────
pick_build_options

# ── Derive BUILD_NAME and paths (after version is known) ─────────────────
# For local sources BUILD_NAME is already set above.
if [ "$WINE_SOURCE_KEY" != "local" ]; then
    if [ -z "$BUILD_NAME" ]; then
        # Append a version suffix when a specific version was chosen so that
        # different versions can coexist side-by-side under src/ and install/.
        _vsuffix="$(_extract_version_suffix "${_src_branch}")"
        if [ -n "$_vsuffix" ]; then
            BUILD_NAME="wine-${WINE_SOURCE_KEY}-${_vsuffix}"
        else
            BUILD_NAME="wine-${WINE_SOURCE_KEY}"
        fi
    fi
    WINE_SOURCE_DIR="${SRC_ROOT}/${BUILD_NAME}"
fi

# For custom source: finalise BUILD_NAME interactively if still unset
if [ "$WINE_SOURCE_KEY" = "custom" ] && [ -t 0 ]; then
    if [ -z "$BUILD_NAME" ] || [ "$BUILD_NAME" = "wine-custom" ]; then
        printf "  ${C_B}Build name for install path:${C_R} "
        read -r BUILD_NAME
        BUILD_NAME="${BUILD_NAME:-wine-custom}"
        WINE_SOURCE_DIR="${SRC_ROOT}/${BUILD_NAME}"
    fi
fi

# Derived build / install paths (set these before anything that might use them)
BUILD_RUN_DIR="${DEST_ROOT}/build-run/${BUILD_NAME}"
INSTALL_PREFIX="${DEST_ROOT}/install/${BUILD_NAME}"
BUILD_LOG="${BUILD_RUN_DIR}/build.log"

msg2 "Install prefix : $INSTALL_PREFIX"
msg2 "Build directory: $BUILD_RUN_DIR"
msg2 "Jobs           : $JOBS"
[ "$RESUME" = true ] && \
    msg2 "Mode           : RESUME (configure skipped if Makefile already present)"

# ── Dependency + disk checks ──────────────────────────────────────────────
check_deps
section "Pre-flight checks"
check_disk_space "$DEST_ROOT"

# ── Fetch / update source ─────────────────────────────────────────────────
if [ "$WINE_SOURCE_KEY" != "local" ]; then
    section "Fetching source"
    # Valve sources need a full clone (no --depth=1) so that git describe
    # can walk the tag history and produce the proper version string
    # e.g. wine-8.0-15630-g61cbb052f84.  All other sources use shallow
    # clones since their version comes from the tag name directly.
    _shallow="true"
    case "$WINE_SOURCE_KEY" in
        proton|proton-experimental)
            _shallow="false"
            msg2 "Full clone (no depth limit) — required for Valve version strings"
            ;;
    esac
    fetch_source "$_src_url" "${_src_branch}" "$WINE_SOURCE_DIR" "$_shallow"
fi

[ -d "$WINE_SOURCE_DIR" ] || \
    err "Wine source directory not found after fetch: $WINE_SOURCE_DIR"

# ── TKG framework delegation (after clone, before configure) ─────────────
if [ "${SOURCE_IS_TKG[$WINE_SOURCE_KEY]:-false}" = "true" ]; then
    handle_tkg_source "$WINE_SOURCE_DIR"
    # If we reach here we're in hybrid mode — WINE_SOURCE_DIR was updated
    # to the prepared wine source tree inside the TKG directory.
    BUILD_RUN_DIR="${DEST_ROOT}/build-run/${BUILD_NAME}"
    INSTALL_PREFIX="${DEST_ROOT}/install/${BUILD_NAME}"
    BUILD_LOG="${BUILD_RUN_DIR}/build.log"
fi

# ── Automated patch application (tkg-patched and similar sources) ─────────
# Runs wine-tkg-patcher.sh which applies wine-staging via patchinstall.py
# and then any .patch / .diff files from patches/.
# Skipped automatically on --resume (source already patched).
if [ "${SOURCE_NEEDS_PATCHING[$WINE_SOURCE_KEY]:-false}" = "true" ]; then
    if [ "$RESUME" = "true" ]; then
        msg2 "--resume: skipping patch application (assuming source already patched)"
    else
        section "Applying TKG-style patches"
        [ -f "$PATCHER" ] || \
            err "Patcher script not found: $PATCHER
     Expected alongside wine-builder.sh as wine-tkg-patcher.sh"
        [ -x "$PATCHER" ] || chmod +x "$PATCHER"

        export DRY_RUN NO_PULL
        export PATCH_LOG="${BUILD_RUN_DIR}/tkg-patch.log"
        # Pass the known tag/branch as a hint so the patcher can derive
        # the staging version even when configure.ac uses a macro placeholder.
        export STAGING_BRANCH_HINT="${_src_branch:-}"
        mkdir -p "$BUILD_RUN_DIR"
        # Pass the staging cache dir explicitly so the patcher doesn't
        # default to SCRIPT_DIR/src/ which points into the (read-only) lib
        # directory after a make install.
        "$PATCHER" "$WINE_SOURCE_DIR" "${_DATA_DIR}/src/wine-staging-patches"
    fi
fi

# ── Validate the wine source tree ─────────────────────────────────────────
# Check for configure.ac, not configure — configure is generated by autoreconf
# which runs below.  configure.ac is always present in a real Wine source tree.
[ -f "$WINE_SOURCE_DIR/configure.ac" ] || \
    err "configure.ac not found in: $WINE_SOURCE_DIR
     This does not look like a Wine source tree.
     For TKG sources, the prepare step must complete first."

# ── System pre-flight ─────────────────────────────────────────────────────
section "System pre-flight"
fix_opencl_headers

# ── Pre-generate headers ──────────────────────────────────────────────────
pregen_headers "$WINE_SOURCE_DIR"

# ── autoreconf ────────────────────────────────────────────────────────────
run_autoreconf "$WINE_SOURCE_DIR"

# ── Build core sanity ─────────────────────────────────────────────────────
[ -f "$BUILD_CORE" ] || \
    err "Build core script not found: $BUILD_CORE
     Expected alongside wine-builder.sh as wine-build-core.sh"
[ -x "$BUILD_CORE" ] || chmod +x "$BUILD_CORE"

# ── Load configuration ────────────────────────────────────────────────────
[ -f "$CUSTOM_CFG" ] || \
    err "Configuration file not found: $CUSTOM_CFG
     Copy and edit customization.cfg — see README for details."

# shellcheck source=/dev/null
source "$CUSTOM_CFG"

# ── Source-specific configure overrides ───────────────────────────────────
# Valve's Wine fork (proton / proton-experimental) has its own SDL input
# handling that conflicts with the standard --with-sdl configure path and
# caused build errors.  Disable SDL for Valve sources only; all other sources
# (mainline, staging, tkg-patched etc.) keep SDL enabled for controller support.
case "$WINE_SOURCE_KEY" in
    proton|proton-experimental)
        _configure_args+=( "--without-sdl" )
        msg2 "Valve source: SDL disabled (Valve uses its own input stack)"
        ;;
esac

# Our computed values always take precedence over what's in the cfg,
# so a generic cfg works for any source/destination combination.
export WINE_SOURCE="$WINE_SOURCE_DIR"
export PREFIX="$INSTALL_PREFIX"
export WINE_BUILD="${BUILD_NAME//-/_}"   # underscores by convention
export JOBS
export SKIP_32BIT
export NO_CCACHE KEEP_SYMBOLS BUILD_TYPE NATIVE_MARCH LTO
export BUILD_RUN_DIR
export CUSTOM_CFG
export RESUME
export BUILD_LOG
export VERBOSE_BUILD

# ── Start build timer ─────────────────────────────────────────────────────
_BUILD_START=$(date +%s)

# ── Compile ───────────────────────────────────────────────────────────────
section "Compiling Wine"
msg "Handing off to: $BUILD_CORE"
mkdir -p "$BUILD_RUN_DIR"
cd "$DEST_ROOT"
"$BUILD_CORE"

# ── Install ───────────────────────────────────────────────────────────────
install_wine "$BUILD_RUN_DIR" "$INSTALL_PREFIX"

# ── Rename install + build-run dirs to include the actual Wine version ────
# Read the real version string from the installed binary and rename both
# directories so users see e.g. wine-proton-experimental-8.0-15630-gabcdef
# rather than the placeholder wine-proton-experimental.
_rename_to_version() {
    local prefix="$1"   # current install dir
    local build="$2"    # current build-run dir
    local source_key="$3"

    local wine_bin="${prefix}/bin/wine"
    local raw_ver=""

    # Strategy 1: run the built wine binary with its own lib dirs in LD_LIBRARY_PATH
    if [ -x "$wine_bin" ]; then
        raw_ver="$(
            LD_LIBRARY_PATH="${prefix}/lib64:${prefix}/lib:${LD_LIBRARY_PATH:-}" \
            "$wine_bin" --version 2>/dev/null || true
        )"
    fi

    # Strategy 2: git describe on the source tree — no runtime required
    if [ -z "$raw_ver" ] && [ -d "$WINE_SOURCE_DIR/.git" ]; then
        raw_ver="$(git -C "$WINE_SOURCE_DIR" describe --tags --long 2>/dev/null || true)"
    fi

    if [ -z "$raw_ver" ]; then
        warn "Could not determine Wine version — install dir kept as: $(basename "$prefix")"
        return 0
    fi

    # Strip leading "wine-" prefix, sanitize for use in a directory name
    local clean_ver
    clean_ver="${raw_ver#wine-}"
    clean_ver="$(printf '%s' "$clean_ver" \
        | tr ' ' '-' \
        | tr -d '()[]:'  \
        | sed 's/--*/-/g; s/-$//')"

    [ -n "$clean_ver" ] || return 0

    local new_install="${DEST_ROOT}/install/wine-${source_key}-${clean_ver}"
    local new_build="${DEST_ROOT}/build-run/wine-${source_key}-${clean_ver}"

    # Nothing to do if the name already ends with this version
    if [ "$prefix" = "$new_install" ]; then
        return 0
    fi

    msg2 "Renaming install dir to include Wine version..."

    if [ -e "$new_install" ]; then
        warn "Target already exists: $new_install — removing old and renaming"
        rm -rf "$new_install"
    fi

    mv "$prefix" "$new_install" && \
        ok "Install dir: $new_install" || \
        { warn "Could not rename install dir — leaving as: $prefix"; return 0; }

    if [ -d "$build" ] && [ ! -e "$new_build" ]; then
        mv "$build" "$new_build" 2>/dev/null || true
    fi

    # Update globals so print_summary and write_build_manifest use the new path
    INSTALL_PREFIX="$new_install"
    BUILD_RUN_DIR="$new_build"
    BUILD_LOG="${new_build}/build.log"
}

_rename_to_version "$INSTALL_PREFIX" "$BUILD_RUN_DIR" "$WINE_SOURCE_KEY"

# ── Summary + manifest ────────────────────────────────────────────────────
_BUILD_END=$(date +%s)
_ELAPSED=$(( _BUILD_END - _BUILD_START ))
_ELAPSED_FMT="$(( _ELAPSED / 3600 ))h $(( (_ELAPSED % 3600) / 60 ))m $(( _ELAPSED % 60 ))s"
print_summary "$INSTALL_PREFIX" "$_ELAPSED_FMT"
write_build_manifest "$INSTALL_PREFIX" "$_ELAPSED_FMT"

# ── Offer to set this build as the default Wine ──────────────────────────
offer_set_wine_default "$INSTALL_PREFIX"
