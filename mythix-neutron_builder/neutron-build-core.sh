#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║         mythix-neutron_builder  •  Wine compilation engine                  ║
# ║   64-bit + 32-bit cross-compile with Proton-specific configure flags      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Called by neutron-builder.sh.  Can also be invoked standalone if the
# required environment variables are exported first.
#
# Required env vars:
#   WINE_SOURCE     — absolute path to the proton-wine source tree
#   PREFIX          — absolute install prefix (becomes the 'files/' dir in
#                     the final Proton package; set by neutron-builder.sh)
#
# Optional env vars (neutron-builder.sh sets all of these automatically):
#   WINE_BUILD          — build name; defaults to last component of PREFIX
#   JOBS                — parallel make threads; defaults to nproc
#   SKIP_32BIT          — "true" to skip the 32-bit build
#   BUILD_RUN_DIR       — directory for wine64 / wine32 build trees
#   CUSTOM_CFG          — path to neutron-customization.cfg
#   RESUME              — "true" to skip configure if Makefile already present
#   BUILD_LOG           — path for build log; defaults to BUILD_RUN_DIR/build.log
#   NEUTRON_SOURCE_KEY  — "proton-wine" or "proton-wine-experimental"
#                         (used to apply source-specific configure overrides)
#
set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
#  Output helpers  (mirror neutron-builder.sh style; safe when used standalone)
# ══════════════════════════════════════════════════════════════════════════════
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
    _R="\033[0m" _B="\033[1m"
    _GRN="\033[1;35m"   # magenta  (replaces green for ok/msg)
    _BLU="\033[1;36m"   # cyan     (replaces blue for msg2/sep)
    _YLW="\033[1;33m" _RED="\033[1;31m"
    _DIM="\033[2m"
    _MAG="\033[1;35m" _CYN="\033[1;36m" _DIM_="\033[2m" _R_="\033[0m"
else
    _R="" _B="" _GRN="" _BLU="" _YLW="" _RED="" _DIM=""
    _MAG="" _CYN="" _DIM_="" _R_=""
fi
# Source common output helpers (uses the _* color variables set above)
_NCORE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
. "${_NCORE_DIR}/_output_common.sh"

# ══════════════════════════════════════════════════════════════════════════════
#  Validate / default required environment
# ══════════════════════════════════════════════════════════════════════════════
: "${WINE_SOURCE:?WINE_SOURCE must be set to the proton-wine source directory}"
: "${PREFIX:?PREFIX must be set to the install prefix}"
: "${WINE_BUILD:=${PREFIX##*/}}"
: "${JOBS:=$(nproc)}"
: "${SKIP_32BIT:=false}"
: "${RESUME:=false}"
: "${NEUTRON_SOURCE_KEY:=proton-wine}"
: "${BUILD_RUN_DIR:=$(pwd)/build-run/${WINE_BUILD}}"
: "${BUILD_LOG:=${BUILD_RUN_DIR}/build.log}"

WINE_SOURCE_DIR="${WINE_SOURCE}"
INSTALL_PREFIX="${PREFIX}"
BUILD64="${BUILD_RUN_DIR}/wine64"
BUILD32="${BUILD_RUN_DIR}/wine32"

mkdir -p "${BUILD_RUN_DIR}"

# ══════════════════════════════════════════════════════════════════════════════
#  Build log setup
#  All make output (stdout + stderr) is tee'd to BUILD_LOG so the full error
#  context is available even when the terminal has scrolled past it.
#  set -o pipefail ensures make's non-zero exit is not hidden by tee.
# ══════════════════════════════════════════════════════════════════════════════
{
    printf '# neutron-build-core log\n'
    printf '# Started     : %s\n' "$(date)"
    printf '# Source      : %s\n' "$WINE_SOURCE_DIR"
    printf '# Source key  : %s\n' "$NEUTRON_SOURCE_KEY"
    printf '# Install     : %s\n' "$INSTALL_PREFIX"
    printf '# Jobs        : %s\n' "$JOBS"
    printf '# Resume      : %s\n\n' "$RESUME"
} > "$BUILD_LOG"

# ══════════════════════════════════════════════════════════════════════════════
#  HUD state  (shared across _draw_bar calls)
# ══════════════════════════════════════════════════════════════════════════════
_HUD_WARNINGS=0
_HUD_ERRORS=0
_HUD_LAST_FILE=""

# ══════════════════════════════════════════════════════════════════════════════
#  _draw_bar <cur> <tot> <label> <start_epoch> <eta_secs>
#
#  Single-line progress bar — updates in-place via \r.
#  Shows: [bar] pct  (count)  elapsed  ETA  file
# ══════════════════════════════════════════════════════════════════════════════
_draw_bar() {
    local cur="$1" tot="$2" label="$3" start="${4:-0}" eta="${5:-0}"

    # ── Bar ──────────────────────────────────────────────────────────────
    local width=30 filled pct bar="" i=0
    if [ "$tot" -eq 0 ]; then
        local now_s; now_s=$(date +%s)
        local tick=$(( (now_s - start) % 10 ))
        local pos=$(( tick * 3 ))
        [ "$pos" -gt $(( width - 6 )) ] && pos=$(( width * 2 - 6 - pos ))
        while [ "$i" -lt "$pos" ];            do bar="${bar}░"; i=$(( i+1 )); done
        while [ "$i" -lt $(( pos + 6 )) ];    do bar="${bar}█"; i=$(( i+1 )); done
        while [ "$i" -lt "$width" ];          do bar="${bar}░"; i=$(( i+1 )); done
        pct="??"
    else
        filled=$(( cur * width / tot ))
        pct=$(( cur * 100 / tot ))
        while [ "$i" -lt "$filled" ]; do bar="${bar}█"; i=$(( i+1 )); done
        while [ "$i" -lt "$width"  ]; do bar="${bar}░"; i=$(( i+1 )); done
    fi

    # ── Elapsed ──────────────────────────────────────────────────────────
    local elapsed=0 elapsed_str="0s"
    if [ "$start" -gt 0 ]; then
        local now; now=$(date +%s)
        elapsed=$(( now - start ))
        if   [ "$elapsed" -ge 3600 ]; then elapsed_str="$(( elapsed/3600 ))h$(( (elapsed%3600)/60 ))m"
        elif [ "$elapsed" -ge 60   ]; then elapsed_str="$(( elapsed/60 ))m$(( elapsed%60 ))s"
        else                               elapsed_str="${elapsed}s"; fi
    fi

    # ── ETA ──────────────────────────────────────────────────────────────
    local eta_str="--"
    if [ "$cur" -gt 0 ] && [ "$eta" -gt 2 ]; then
        local wc_eta=0
        [ "$elapsed" -gt 0 ] && wc_eta=$(( elapsed * ( tot - cur ) / cur ))
        local best_eta; best_eta=$(( eta > wc_eta ? eta : wc_eta ))
        if   [ "$best_eta" -ge 3600 ]; then eta_str="~$(( best_eta/3600 ))h$(( (best_eta%3600)/60 ))m"
        elif [ "$best_eta" -ge 60   ]; then eta_str="~$(( best_eta/60 ))m$(( best_eta%60 ))s"
        else                                eta_str="~${best_eta}s"; fi
    fi

    # ── Warn/error suffix ────────────────────────────────────────────────
    local issues=""
    [ "$_HUD_ERRORS"   -gt 0 ] && issues=" ${_RED}${_HUD_ERRORS}err${_R}"
    [ "$_HUD_WARNINGS" -gt 0 ] && issues="${issues} ${_YLW}${_HUD_WARNINGS}warn${_R}"

    # ── Truncate filename to fit ─────────────────────────────────────────
    local fname="$_HUD_LAST_FILE"
    [ "${#fname}" -gt 20 ] && fname="…${fname: -19}"

    # ── Single-line draw ─────────────────────────────────────────────────
    {
        printf "\r\033[K  ${_MAG}[%s]${_R} %3s%%  ${_DIM}%d/%d${_R}  ${_CYN}%s${_R}  ${_CYN}%s${_R}  ${_DIM}%s${_R}%s" \
            "$bar" "$pct" "$cur" "$tot" "$elapsed_str" "$eta_str" "$fname" "$issues"
    } > /dev/tty
}

# ══════════════════════════════════════════════════════════════════════════════
#  _make_compile_bar <phase> [make args…]
#
#  phase — "64" or "32", used to scale the source-file estimate.
#
#  Counts compilable source files in the Wine tree with `find` (~0.3s,
#  zero interference with make) rather than `make -n` (which runs
#  sub-makes in the build directory and deadlocks against the real make).
#  Falls back to plain tee output when /dev/tty is unavailable or
#  VERBOSE_BUILD=true.
# ══════════════════════════════════════════════════════════════════════════════
_make_logged() {
    local _opencl_make_arg=()
    [ -n "${OPENCL_LIBS:-}" ] && _opencl_make_arg=("OPENCL_LIBS=${OPENCL_LIBS}")
    MAKEFLAGS="" make "${_opencl_make_arg[@]}" --output-sync=none "$@" 2>&1 | tee -a "$BUILD_LOG"
}

_make_compile_bar() {
    local _phase="$1"; shift   # "64" or "32"
    local _opencl_make_arg=()
    [ -n "${OPENCL_LIBS:-}" ] && _opencl_make_arg=("OPENCL_LIBS=${OPENCL_LIBS}")

    if ! ( : >/dev/tty ) 2>/dev/null || [ "${VERBOSE_BUILD:-false}" = "true" ]; then
        _make_logged "$@"
        return
    fi

    # ── Count source files — fast, no build-dir side effects ────────────
    printf "${_DIM}  Counting source files...${_R}" > /dev/tty
    local _total=0
    _total=$(
        find "$WINE_SOURCE_DIR" -maxdepth 6 \
            \( -name '*.c' -o -name '*.cpp' -o -name '*.s' \) \
            ! -path '*/tests/*' ! -path '*/test/*' \
            2>/dev/null | wc -l
    )
    printf "\r\033[K" > /dev/tty
    # 32-bit reuses the 64-bit tool tree — roughly half the objects
    [ "$_phase" = "32" ] && _total=$(( _total / 2 ))
    [ "$_total" -eq 0 ] && _total=500

    # ── HUD state reset for this compile phase ───────────────────────────
    local _cur=0 _start _prev _now _dur _eta=0 _ewma_x100=0
    local _tmp_out _make_exit _label="starting"
    _tmp_out=$(mktemp)
    _start=$(date +%s); _prev="$_start"
    _HUD_WARNINGS=0
    _HUD_ERRORS=0
    _HUD_LAST_FILE=""

    # ── Let the user know the bar will be quiet for a while ──────────────
    printf "\n" > /dev/tty
    printf "  ${_CYN}${_B}Heads up:${_R} Wine bootstraps build tools first — bar starts at 0%%. Please wait :3\n" > /dev/tty
    _draw_bar 0 "$_total" "bootstrapping..." "$_start" 0

    # ── Run make in background, poll output in 0.1 s batches ─────────────
    # --output-sync=none: stream each line immediately instead of buffering
    #   per-job (make 4.x default). Without this, the 32-bit build buffers
    #   for minutes because its long gaps between jobs never fill the buffer.
    # MAKEFLAGS="": clear any inherited jobserver FDs from a prior make call
    #   that may have already closed their pipe ends, which would deadlock.
    set +e
    MAKEFLAGS="" make "${_opencl_make_arg[@]}" --output-sync=none "$@" > "$_tmp_out" 2>&1 &
    local _make_pid=$!

    while kill -0 "$_make_pid" 2>/dev/null || [ -s "$_tmp_out" ]; do
        while IFS= read -r _line; do
            printf '%s\n' "$_line" >> "$BUILD_LOG"

            if [[ "$_line" =~ error:|fatal\ error:|make.*Error|make.*Stop ]]; then
                _HUD_ERRORS=$(( _HUD_ERRORS + 1 ))
            fi
            [[ "$_line" =~ warning: ]] && _HUD_WARNINGS=$(( _HUD_WARNINGS + 1 ))

            if [[ "$_line" =~ (-o\ [^\ ]+\.o|-c\ .*\.(c|cpp|s)) ]]; then
                _cur=$(( _cur + 1 ))
                [ "$_cur" -ge "$_total" ] && _total=$(( _total + 50 ))
                _now=$(date +%s)
                _dur=$(( _now - _prev )); _prev="$_now"
                if [ "$_ewma_x100" -eq 0 ]; then
                    _ewma_x100=$(( _dur * 100 ))
                else
                    _ewma_x100=$(( ( 30 * _dur * 100 + 70 * _ewma_x100 ) / 100 ))
                fi
                local _rem=$(( _total - _cur ))
                _eta=$(( _ewma_x100 * _rem / 100 ))
                local _file=""
                if [[ "$_line" =~ [^\ ]+\.(c|cpp|s) ]]; then
                    _file="${BASH_REMATCH[0]}"
                fi
                _HUD_LAST_FILE="${_file##*/}"
            fi
        done < "$_tmp_out"

        kill -0 "$_make_pid" 2>/dev/null && > "$_tmp_out" || break
        _draw_bar "$_cur" "$_total" "$_label" "$_start" "$_eta"
        sleep 0.1
    done

    wait "$_make_pid"; _make_exit=$?

    while IFS= read -r _line; do
        printf '%s\n' "$_line" >> "$BUILD_LOG"
    done < "$_tmp_out"
    rm -f "$_tmp_out"
    set -e

    if [ "$_make_exit" -ne 0 ]; then
        printf "\n\n" > /dev/tty
        printf "  ${_RED}Make failed (exit %d) — last output:${_R}\n" "$_make_exit" >&2
        tail -20 "$BUILD_LOG" >&2
        return "$_make_exit"
    fi

    [ "$_total" -lt "$_cur" ] && _total="$_cur"
    _HUD_LAST_FILE="done ✓"
    _draw_bar "$_total" "$_total" "complete" "$_start" 0
    printf "\n" > /dev/tty
}

# ══════════════════════════════════════════════════════════════════════════════
#  _run_configure  — run Wine's configure with a live indeterminate spinner
#
#  configure outputs "checking for X... yes/no" for each autoconf test.
#  We can't know the total upfront so we use the bouncing indeterminate bar
#  (tot=0 mode) and show a live count + the current check being tested.
#
#  Usage: _run_configure <configure-binary> [args...]
# ══════════════════════════════════════════════════════════════════════════════
_run_configure() {
    if ! ( : >/dev/tty ) 2>/dev/null || [ "${VERBOSE_BUILD:-false}" = "true" ]; then
        "$@" 2>&1 | tee -a "$BUILD_LOG"
        return
    fi

    local _tmp _pid _exit _cur=0 _label="starting" _start _spinstr='|/-\'
    _tmp=$(mktemp)
    _start=$(date +%s)

    # Reserve lines: 1 spinner line + 1 detail line
    printf "\n\n" > /dev/tty
    tput civis 2>/dev/null || true

    "$@" > "$_tmp" 2>&1 &
    _pid=$!

    while kill -0 "$_pid" 2>/dev/null || [ -s "$_tmp" ]; do
        while IFS= read -r _line; do
            printf '%s\n' "$_line" >> "$BUILD_LOG"
            if printf '%s' "$_line" | grep -qE '^checking '; then
                _cur=$(( _cur + 1 ))
                # Extract what's being checked, trim trailing punctuation
                _label="$(printf '%s' "$_line" \
                    | sed 's/^checking //' \
                    | sed 's/\.\.\..*//' \
                    | cut -c1-60)"
            fi
        done < "$_tmp"
        kill -0 "$_pid" 2>/dev/null && > "$_tmp" || break

        # Draw 2-line configure HUD in-place
        local _now _elapsed _estr="0s"
        _now=$(date +%s); _elapsed=$(( _now - _start ))
        if   [ "$_elapsed" -ge 3600 ]; then _estr="$(( _elapsed/3600 ))h$(( (_elapsed%3600)/60 ))m$(( _elapsed%60 ))s"
        elif [ "$_elapsed" -ge 60   ]; then _estr="$(( _elapsed/60 ))m$(( _elapsed%60 ))s"
        else                               _estr="${_elapsed}s"; fi

        local _sp="${_spinstr:0:1}"
        _spinstr="${_spinstr:1}${_sp}"
        {
            printf "\033[2A"
            printf "\033[K  ${_CYN}${_B}[%s]${_R}  configuring...  ${_DIM}%d checks  •  %s elapsed${_R}\n" \
                "$_sp" "$_cur" "$_estr"
            printf "\033[K  ${_DIM}checking %s${_R}\n" "$_label"
        } > /dev/tty
        sleep 0.1
    done

    wait "$_pid"; _exit=$?

    # Drain remaining output
    while IFS= read -r _line; do
        printf '%s\n' "$_line" >> "$BUILD_LOG"
    done < "$_tmp"
    rm -f "$_tmp"
    tput cnorm 2>/dev/null || true

    # Clear the 2 reserved lines
    printf "\033[2A\033[J" > /dev/tty

    if [ "$_exit" -ne 0 ]; then
        printf "${_RED}[ ✘ ]${_R} configure failed (exit %d)\n" "$_exit" >&2
        printf "${_YLW}── Last 20 lines of %s ──${_R}\n" "$BUILD_LOG" >&2
        tail -n 20 "$BUILD_LOG" >&2
        return "$_exit"
    fi
    printf "${_MAG} ✓  ${_R}configure complete  ${_DIM}(%d checks)${_R}\n" "$_cur"
}

# ══════════════════════════════════════════════════════════════════════════════
#  ERR trap — show a build log excerpt on unexpected failure
# ══════════════════════════════════════════════════════════════════════════════
_core_on_error() {
    local exit_code=$?
    local line="$1"
    printf "\n${_RED}${_B}neutron-build-core: failed at line %d (exit %d)${_R}\n\n" \
        "$line" "$exit_code" >&2
    if [ -f "$BUILD_LOG" ]; then
        printf "${_YLW}── Last 50 lines of %s ──${_R}\n\n" "$BUILD_LOG" >&2
        tail -n 50 "$BUILD_LOG" >&2
        printf "\n${_DIM}Full log: %s${_R}\n" "$BUILD_LOG" >&2
    fi
    exit "$exit_code"
}
trap '_core_on_error $LINENO' ERR

# ══════════════════════════════════════════════════════════════════════════════
#  Overview
# ══════════════════════════════════════════════════════════════════════════════
sep "Proton Wine Build Core"
msg2 "Source key  : ${NEUTRON_SOURCE_KEY}"
msg2 "Source dir  : ${WINE_SOURCE_DIR}"
msg2 "Install dir : ${INSTALL_PREFIX}"
msg2 "Build root  : ${BUILD_RUN_DIR}"
msg2 "Jobs        : ${JOBS}"
msg2 "32-bit      : $([ "$SKIP_32BIT" = true ] && printf 'skip' || printf 'yes')"
msg2 "Resume      : ${RESUME}"
msg2 "Build log   : ${BUILD_LOG}"

# configure must be executable
[ -x "${WINE_SOURCE_DIR}/configure" ] || \
    err "configure not found or not executable at: ${WINE_SOURCE_DIR}/configure
     Has autoreconf been run? neutron-builder.sh runs it automatically."

# ══════════════════════════════════════════════════════════════════════════════
#  MinGW cross-compiler validation
#  --with-mingw is mandatory for Proton; fail early with a clear message if
#  the required compilers are absent rather than producing a corrupt build.
# ══════════════════════════════════════════════════════════════════════════════
sep "MinGW cross-compiler check"
_mingw64="${MINGW_CC_64:-x86_64-w64-mingw32-gcc}"
_mingw32="${MINGW_CC_32:-i686-w64-mingw32-gcc}"
if command -v "$_mingw64" >/dev/null 2>&1; then
    ok "64-bit MinGW: $( "$_mingw64" --version | head -1 )"
else
    err "64-bit MinGW cross-compiler not found: $_mingw64
     Install: sudo apt install gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64
     (or use the mythix-neutron_builder container which includes it)"
fi
if command -v "$_mingw32" >/dev/null 2>&1; then
    ok "32-bit MinGW: $( "$_mingw32" --version | head -1 )"
else
    warn "32-bit MinGW cross-compiler not found: $_mingw32"
    warn "Install: sudo apt install gcc-mingw-w64-i686 g++-mingw-w64-i686"
    warn "32-bit PE modules will not be built with MinGW (SKIP_32BIT will not fix this)."
fi

# ══════════════════════════════════════════════════════════════════════════════
#  User patch application
#  Drop .patch / .diff files into a proton-patches/ directory alongside this
#  script to have them automatically applied (idempotent via --forward).
# ══════════════════════════════════════════════════════════════════════════════
sep "Patch application"
PATCH_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/patches"
if [ -d "${PATCH_DIR}" ]; then
    shopt -s nullglob
    _patched=0
    for p in "${PATCH_DIR}"/*.patch "${PATCH_DIR}"/*.diff; do
        [ -f "$p" ] || continue
        msg2 "Applying: $(basename "$p")"
        patch -d "${WINE_SOURCE_DIR}" -p1 --forward < "$p" \
            || warn "Patch $(basename "$p") had fuzz or failed — check for .rej files"
        _patched=$(( _patched + 1 ))
    done
    shopt -u nullglob
    if [ "$_patched" -eq 0 ]; then
        msg2 "No patches found in ${PATCH_DIR}"
    else
        ok "$_patched patch(es) applied"
    fi
else
    mkdir -p "${PATCH_DIR}"
    msg2 "Created ${PATCH_DIR} — drop .patch files there for next run"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Source compatibility fixes
#  Idempotent in-tree edits for known build-system / API mismatches.
# ══════════════════════════════════════════════════════════════════════════════
sep "Source compatibility fixes"

# ── Fix: is_sdl_ignored_device when built --without-sdl ──────────────────────
# Same issue as in wine-build-core.sh: bus_udev.c calls is_sdl_ignored_device()
# unconditionally but the function is only compiled when SDL is enabled.
# Only applies to proton-wine-experimental where we force --without-sdl.
_BUS_UDEV="${WINE_SOURCE_DIR}/dlls/winebus.sys/bus_udev.c"
if [ -f "$_BUS_UDEV" ]; then
    if grep -q 'is_sdl_ignored_device' "$_BUS_UDEV" && \
       ! grep -q 'SDL callsite patched' "$_BUS_UDEV"; then
        msg2 "Patching is_sdl_ignored_device call site in bus_udev.c ..."
        sed -i \
            's/is_sdl_ignored_device([^)]*)/\/\* SDL callsite patched \*\/ FALSE/g' \
            "$_BUS_UDEV" \
            && ok "bus_udev.c patched" \
            || warn "bus_udev.c sed failed — check the file manually"
    else
        ok "bus_udev.c  (no patch needed or already patched)"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Re-hydrate configure arg arrays from config file
#  Bash cannot export arrays across process boundaries.  We re-source the
#  config here, where the arrays are actually used.
# ══════════════════════════════════════════════════════════════════════════════
sep "Loading configuration"
_CFG="${CUSTOM_CFG:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/neutron-customization.cfg}"
if [ -f "$_CFG" ]; then
    msg2 "Sourcing: $_CFG"
    # shellcheck source=/dev/null
    . "$_CFG"
    ok "Config loaded"
else
    warn "Config not found at $_CFG — configure arg arrays will be empty"
    _configure_args=()
    _configure_args32=()
    _configure_args64=()
fi

# Ensure all three are proper Bash arrays (guard against plain-string exports)
_ensure_array() {
    local v="$1"
    local d
    d="$(declare -p "$v" 2>/dev/null || true)"
    [[ "$d" == "declare -a"* ]] || eval "${v}=()"
}
_ensure_array _configure_args
_ensure_array _configure_args32
_ensure_array _configure_args64

_args_common=( "${_configure_args[@]+"${_configure_args[@]}"}" )
_args_64=(     "${_configure_args64[@]+"${_configure_args64[@]}"}" )
_args_32=(     "${_configure_args32[@]+"${_configure_args32[@]}"}" )

# ── Source-specific configure overrides ──────────────────────────────────────
# Different upstream forks have different expectations around SDL and MinGW.
case "${NEUTRON_SOURCE_KEY}" in
    proton-wine-experimental)
        # Valve's bleeding-edge fork has its own SDL input stack — the standard
        # --with-sdl configure path conflicts with it.
        _args_common+=( "--without-sdl" )
        msg2 "Experimental source: SDL disabled (Valve uses its own input stack)"
        ;;
    kron4ek-tkg)
        # Kron4ek's wine-tkg tracks mainline Wine + Staging + TKG patchset.
        # Standard Wine SDL input stack — no overrides needed.
        msg2 "Kron4ek TKG source: using standard SDL (mainline Wine input stack)"
        ;;
    *)
        # proton-wine stable: SDL enabled for controller support
        ;;
esac

# ══════════════════════════════════════════════════════════════════════════════
#  OpenCL forced linking
# ══════════════════════════════════════════════════════════════════════════════
if [ -z "${OPENCL_LIBS:-}" ]; then
    if ldconfig -p 2>/dev/null | grep -q 'libOpenCL\.so '; then
        export OPENCL_LIBS="-lOpenCL"
        ok "libOpenCL.so found — OPENCL_LIBS=-lOpenCL"
    else
        warn "libOpenCL.so not found — OpenCL disabled"
    fi
else
    ok "OPENCL_LIBS already set: ${OPENCL_LIBS}"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  ccache helper
# ══════════════════════════════════════════════════════════════════════════════
_wrap_cc() {
    # Respect NO_CCACHE toggle
    if [ "${NO_CCACHE:-false}" != "true" ] && command -v ccache >/dev/null 2>&1; then
        printf "ccache %s" "$1"
    else
        printf "%s" "$1"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  Apply build tuning flags from toggles
# ══════════════════════════════════════════════════════════════════════════════
sep "Build tuning"

# Base CFLAGS from build type
case "${BUILD_TYPE:-release}" in
    debug)           _opt_flags="-O0 -g3" ;;
    debugoptimized)  _opt_flags="-O2 -g2" ;;
    *)               _opt_flags="-O2" ;;    # release default
esac

# -march=native
[ "${NATIVE_MARCH:-false}" = "true" ] && _opt_flags="${_opt_flags} -march=native"
ok "Optimisation  : ${_opt_flags}"

# LTO
_lto_flags=""
[ "${LTO:-false}" = "true" ] && _lto_flags="-flto=auto" && ok "LTO           : enabled"

# Strip flag for make install
_strip_flag=""
[ "${KEEP_SYMBOLS:-false}" = "true" ] && _strip_flag="STRIP=true" \
    && ok "Symbols       : kept (STRIP disabled)" \
    || ok "Symbols       : stripped"

# ccache status
if [ "${NO_CCACHE:-false}" = "true" ]; then
    ok "ccache        : disabled"
elif command -v ccache >/dev/null 2>&1; then
    ok "ccache        : enabled"
fi

msg2 "Jobs          : ${JOBS:-$(nproc)}"
msg2 "32-bit        : $([ "${SKIP_32BIT:-false}" = "true" ] && echo skipped || echo enabled)"

# ══════════════════════════════════════════════════════════════════════════════
#  Resume helper
# ══════════════════════════════════════════════════════════════════════════════
_needs_configure() {
    local build_dir="$1"
    if [ "${RESUME}" = "true" ] && [ -f "${build_dir}/Makefile" ]; then
        msg2 "--resume: Makefile exists in ${build_dir} — skipping configure"
        return 1
    fi
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  64-bit build
# ══════════════════════════════════════════════════════════════════════════════
sep "64-bit configure"
mkdir -p "$BUILD64"

export CC="$(_wrap_cc gcc)"
export CXX="$(_wrap_cc g++)"
# MinGW PE cross-compilers for --with-mingw
export CROSSCC="$(_wrap_cc "${MINGW_CC_64:-x86_64-w64-mingw32-gcc}")"
export CROSSCXX="$(_wrap_cc "${MINGW_CXX_64:-x86_64-w64-mingw32-g++}")"
export PKG_CONFIG_PATH="/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig:/usr/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="${PKG_CONFIG_PATH}"
export LDFLAGS="${LDFLAGS:-} -L/usr/lib/x86_64-linux-gnu -L/lib/x86_64-linux-gnu ${_lto_flags}"
export CFLAGS="${_opt_flags} ${_lto_flags}"
export CXXFLAGS="${_opt_flags} ${_lto_flags}"

msg2 "CC       = ${CC}"
msg2 "CROSSCC  = ${CROSSCC}"
msg2 "PKG_PATH = ${PKG_CONFIG_PATH}"

cd "$BUILD64"
if _needs_configure "$BUILD64"; then
    _run_configure "${WINE_SOURCE_DIR}/configure" \
        --prefix="${INSTALL_PREFIX}" \
        --enable-win64 \
        --build=x86_64-linux-gnu \
        CPPFLAGS="-I/usr/include -I/usr/include/x86_64-linux-gnu" \
        ${OPENCL_LIBS:+OPENCL_LIBS="${OPENCL_LIBS}"} \
        "${_args_common[@]+"${_args_common[@]}"}" \
        "${_args_64[@]+"${_args_64[@]}"}"
fi

sep "64-bit compile  (jobs=${JOBS})"

# ── Post-configure ntsync fix ──────────────────────────────────────────────────
# Wine's autoconf test for linux/ntsync.h fails silently in cross-build
# container environments even when the header compiles correctly (confirmed
# by direct gcc test).  Since the header IS present and valid, force the
# define in config.h before compilation begins.
_config_h="${BUILD64}/include/config.h"
if [ -f "$_config_h" ]; then
    if grep -q "undef HAVE_LINUX_NTSYNC_H" "$_config_h"; then
        if [ -f "/usr/include/x86_64-linux-gnu/linux/ntsync.h" ] || \
           [ -f "/usr/include/linux/ntsync.h" ]; then
            sed -i \
                's|/\* #undef HAVE_LINUX_NTSYNC_H \*/|#define HAVE_LINUX_NTSYNC_H 1|' \
                "$_config_h"
            ok "Patched config.h: HAVE_LINUX_NTSYNC_H 1 (header confirmed present)"
            # Wipe server object files so ccache is forced to recompile them
            # with the patched config.h — ccache would otherwise return stale
            # objects compiled with HAVE_LINUX_NTSYNC_H=0.
            _server_build="${BUILD64}/server"
            if [ -d "$_server_build" ]; then
                find "$_server_build" -name '*.o' -delete 2>/dev/null || true
                ok "Server objects wiped — will recompile with ntsync enabled"
            fi
        fi
    else
        ok "HAVE_LINUX_NTSYNC_H already defined in config.h"
    fi
fi

_make_compile_bar 64 -j"${JOBS}"
ok "64-bit build complete"

# ══════════════════════════════════════════════════════════════════════════════
#  32-bit build  (cross-compile via i686-linux-gnu-gcc)
#
#  Same rationale as wine-build-core.sh: i686-linux-gnu-gcc is a genuine
#  cross-compiler triplet, so autoconf correctly treats it as cross and skips
#  execute tests.  A -m32 wrapper would break configure's execution tests.
# ══════════════════════════════════════════════════════════════════════════════
if [ "${SKIP_32BIT}" = "true" ]; then
    msg2 "SKIP_32BIT=true — skipping 32-bit build"
else
    sep "32-bit configure  (cross-compile)"

    _CC32="i686-linux-gnu-gcc"
    _CXX32="i686-linux-gnu-g++"

    command -v "$_CC32" >/dev/null 2>&1 || \
        err "32-bit cross-compiler not found: $_CC32
         Install: sudo apt install gcc-i686-linux-gnu g++-i686-linux-gnu"

    mkdir -p "$BUILD32"

    export CC="$(_wrap_cc "$_CC32")"
    export CXX="$(_wrap_cc "$_CXX32")"
    # 32-bit MinGW PE cross-compiler
    export CROSSCC="$(_wrap_cc "${MINGW_CC_32:-i686-w64-mingw32-gcc}")"
    export CROSSCXX="$(_wrap_cc "${MINGW_CXX_32:-i686-w64-mingw32-g++}")"
    # i386_CC is the per-arch CC used by newer Wine multi-arch builds
    export i386_CC="${CROSSCC}"

    export PKG_CONFIG_LIBDIR="/usr/lib/i386-linux-gnu/pkgconfig:/usr/share/pkgconfig:/usr/lib/pkgconfig"
    export PKG_CONFIG_PATH="${PKG_CONFIG_LIBDIR}"

    export CFLAGS="-I/usr/include/freetype2 -I/usr/include/wayland"
    export CPPFLAGS="-I/usr/include/freetype2 -I/usr/include/wayland"
    export LDFLAGS="-L/usr/lib/i386-linux-gnu -L/usr/lib32 -L/lib/i386-linux-gnu -lm"

    msg2 "CC       = ${CC}"
    msg2 "CROSSCC  = ${CROSSCC}"
    msg2 "PKG_PATH = ${PKG_CONFIG_PATH}"

    cd "$BUILD32"
    if _needs_configure "$BUILD32"; then
        _run_configure "${WINE_SOURCE_DIR}/configure" \
            --prefix="${INSTALL_PREFIX}" \
            --with-wine64="${BUILD64}" \
            --with-wine-tools="${BUILD64}" \
            --with-freetype \
            --build=x86_64-linux-gnu \
            --host=i686-linux-gnu \
            ${OPENCL_LIBS:+OPENCL_LIBS="${OPENCL_LIBS}"} \
            "${_args_common[@]+"${_args_common[@]}"}" \
            "${_args_32[@]+"${_args_32[@]}"}"
    fi

    sep "32-bit compile  (jobs=${JOBS})"
    _make_compile_bar 32 -j"${JOBS}"
    ok "32-bit build complete"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Verify build artifacts before handing back to neutron-builder.sh
# ══════════════════════════════════════════════════════════════════════════════
sep "Verifying build artifacts"

_verify_artifact() {
    local path="$1" label="$2"
    if [ -f "$path" ]; then
        ok "$label"
    else
        warn "Expected artifact not found: $path"
    fi
}

_verify_artifact "${BUILD64}/loader/wine"        "wine loader  (64-bit tree)"
_verify_artifact "${BUILD64}/server/wineserver"  "wineserver   (64-bit tree)"
if [ "${SKIP_32BIT}" != "true" ]; then
    _verify_artifact "${BUILD32}/loader/wine"    "wine loader  (32-bit tree)"
fi

# Proton-specific: verify that at least one PE module was built with MinGW.
# If --with-mingw succeeded, we should see *.dll files in the build tree.
_pe_count=$(find "${BUILD64}" -name '*.dll' -maxdepth 4 2>/dev/null | wc -l)
if [ "$_pe_count" -gt 0 ]; then
    ok "MinGW PE modules present (${_pe_count} .dll files found in 64-bit tree)"
else
    warn "No .dll files found in 64-bit build tree"
    warn "This suggests --with-mingw did not produce PE modules."
    warn "Check that x86_64-w64-mingw32-gcc is installed and working."
fi

sep "Wine build complete"
ok "All proton-wine components compiled successfully"
msg2 "Build artifacts  : ${BUILD_RUN_DIR}"
msg2 "Build log        : ${BUILD_LOG}"
msg2 "neutron-builder.sh will now run 'make install' and package the build."
