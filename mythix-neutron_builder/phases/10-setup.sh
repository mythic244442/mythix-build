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

# ── Build profile (--profile) ────────────────────────────────────────────────
[ -z "$PROFILE_NAME" ] || _load_profile "$PROFILE_NAME"

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

# ── Build mode ───────────────────────────────────────────────────────────────
# classic = 64-bit tree (wine64) + 32-bit tree — Mythix Wine's layout
# wow64   = one unified --enable-archs=i386,x86_64 tree (+ i386-unix drivers) — Neutron line
if [ -z "$NEUTRON_BUILD_MODE" ]; then
    case "$WINE_SOURCE_KEY" in
        mythix-wine) NEUTRON_BUILD_MODE="classic" ;;
        *)           NEUTRON_BUILD_MODE="wow64" ;;
    esac
fi
case "$NEUTRON_BUILD_MODE" in
    classic|wow64) ;;
    *) err "Unknown --build-mode: '${NEUTRON_BUILD_MODE}' (use classic or wow64)" ;;
esac
export NEUTRON_BUILD_MODE
msg2 "Build mode: ${NEUTRON_BUILD_MODE}"

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
if [ "${PROFILE_PIPELINE:-}" = "patch" ]; then
    # Patch pipeline layout: <src>/mythix-ge = GE checkout, wine/ + wine-staging/ inside
    MYTHIX_PATCH_WORK_DIR="${SRC_ROOT}/mythix-patch"
    WINE_SOURCE_DIR="${MYTHIX_PATCH_WORK_DIR}/wine"
fi
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
if [ "$WINE_SOURCE_KEY" = "mythix-wine" ] && [ -z "$_wine_branch" ] && \
   [ "${PROFILE_PIPELINE:-}" != "patch" ]; then
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

