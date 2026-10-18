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

${C_B}Build profiles (pinned Mythix Wine recipes):${C_R}
  --profile NAME        Build a pinned profile from profiles/NAME (or a profile dir).
                        Sets --source mythix-wine, the package name, build mode and
                        patch groups; every upstream input is pinned + source-locked.
  --list-profiles       Show the available profiles
  --build-mode MODE     classic (wine64 + 32-bit tree) | wow64 (unified)
                        Default: the profile's mode; mythix-wine → classic; others → wow64
  --allow-patch-failures  Keep going when a profile patch layer fails (for re-curating)

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
  $0 --profile mythix-11.19 --container       # Mythix Wine 11.19 (Wayland-first), pinned
  $0 --profile mythix-10.17 --container       # rebuild the frozen 10.17 esync/fsync build
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
        --wine-base)    MYTHIX_WINE_BASE="$2"; _WINE_BASE_SET=true; shift 2 ;;
        --profile)      PROFILE_NAME="$2";       shift 2 ;;
        --list-profiles) _LIST_PROFILES=true;    shift   ;;
        --build-mode)   NEUTRON_BUILD_MODE="$2"; shift 2 ;;
        --allow-patch-failures) ALLOW_PATCH_FAILURES=true; shift ;;
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

