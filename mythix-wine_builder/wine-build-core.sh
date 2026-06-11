#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════╗
# ║            mythix-wine_builder  •  compilation engine                   ║
# ║   64-bit + 32-bit cross-compile with automatic compat patching         ║
# ╚═══════════════════════════════════════════════════════════════════════╝
#
# Called by wine-builder.sh.  Can also be invoked standalone if the
# required environment variables are exported first.
#
# Required env vars:
#   WINE_SOURCE     — absolute path to the Wine source tree
#   PREFIX          — absolute install prefix
#
# Optional env vars (wine-builder.sh sets all of these automatically):
#   WINE_BUILD      — build name; defaults to the last component of PREFIX
#   JOBS            — parallel make threads; defaults to nproc
#   SKIP_32BIT      — "true" to skip the 32-bit build
#   BUILD_RUN_DIR   — directory for wine64 / wine32 build trees
#   CUSTOM_CFG      — path to customization.cfg
#   RESUME          — "true" to skip configure if Makefile already exists
#   BUILD_LOG       — path for build log (stdout+stderr of make); defaults
#                     to BUILD_RUN_DIR/build.log
#
set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════
#  Output helpers  (mirror wine-builder.sh style; safe when used standalone)
# ══════════════════════════════════════════════════════════════════════════
if [ -e /dev/tty ] && command -v tput >/dev/null 2>&1 && tput colors >/dev/tty 2>&1; then
    _R=$'\033[0m'  _B=$'\033[1m'
    _GRN=$'\033[1;32m' _BLU=$'\033[1;34m'
    _YLW=$'\033[1;33m' _RED=$'\033[1;31m'
    _CYN=$'\033[1;36m' _MAG=$'\033[1;35m'
    _DIM=$'\033[2m'
else
    _R="" _B="" _GRN="" _BLU="" _YLW="" _RED="" _CYN="" _MAG="" _DIM=""
fi
# Source common output helpers (uses the _* color variables set above)
_CORE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
. "${_CORE_DIR}/_output_common.sh"

# ══════════════════════════════════════════════════════════════════════════
#  Validate / default required environment
# ══════════════════════════════════════════════════════════════════════════
: "${WINE_SOURCE:?WINE_SOURCE must be set to the Wine source directory}"
: "${PREFIX:?PREFIX must be set to the install prefix}"
: "${WINE_BUILD:=${PREFIX##*/}}"
: "${JOBS:=$(nproc)}"
: "${SKIP_32BIT:=false}"
: "${RESUME:=false}"
: "${BUILD_RUN_DIR:=$(pwd)/build-run/${WINE_BUILD}}"
: "${BUILD_LOG:=${BUILD_RUN_DIR}/build.log}"

WINE_SOURCE_DIR="${WINE_SOURCE}"
INSTALL_PREFIX="${PREFIX}"
BUILD64="${BUILD_RUN_DIR}/wine64"
BUILD32="${BUILD_RUN_DIR}/wine32"

mkdir -p "${BUILD_RUN_DIR}"

# ══════════════════════════════════════════════════════════════════════════
#  Build log setup
#  All make output (stdout + stderr) is tee'd to BUILD_LOG so the full
#  error context is available even when the terminal has scrolled past it.
#  set -o pipefail ensures make's non-zero exit is not hidden by tee.
# ══════════════════════════════════════════════════════════════════════════
{
    printf '# wine-build-core log\n'
    printf '# Started: %s\n' "$(date)"
    printf '# Source : %s\n' "$WINE_SOURCE_DIR"
    printf '# Prefix : %s\n' "$INSTALL_PREFIX"
    printf '# Jobs   : %s\n' "$JOBS"
    printf '# Resume : %s\n\n' "$RESUME"
} > "$BUILD_LOG"

# Helper: run make and tee output to the build log.
# With set -o pipefail the pipeline exits non-zero if make fails.
_make_logged() {
    local _opencl_make_arg=()
    [ -n "${OPENCL_LIBS:-}" ] && _opencl_make_arg=("OPENCL_LIBS=${OPENCL_LIBS}")
    MAKEFLAGS="" make "${_opencl_make_arg[@]}" --output-sync=none "$@" 2>&1 | tee -a "$BUILD_LOG"
}

# ══════════════════════════════════════════════════════════════════════════
#  HUD state  (shared across _draw_bar calls)
# ══════════════════════════════════════════════════════════════════════════
_HUD_DRAWN=0
_HUD_WARNINGS=0
_HUD_ERRORS=0
_HUD_LAST_FILES=""
_HUD_JOBS=0

# ══════════════════════════════════════════════════════════════════════════
#  _draw_bar <cur> <tot> <label> <start_epoch> <eta_secs>
#
#  4-line HUD drawn to /dev/tty — updates in-place via cursor movement:
#    Line 1: progress bar + pct + count
#    Line 2: elapsed / ETA / speed
#    Line 3: last 3 filenames being compiled
#    Line 4: live warning / error badge + job count
# ══════════════════════════════════════════════════════════════════════════
_draw_bar() {
    local cur="$1" tot="$2" label="$3" start="${4:-0}" eta="${5:-0}"

    # ── Bar ──────────────────────────────────────────────────────────────
    local width=50 filled pct bar="" i=0
    if [ "$tot" -eq 0 ]; then
        # Indeterminate mode: bouncing 8-wide pulse block, driven by elapsed time
        local now_s; now_s=$(date +%s)
        local tick=$(( (now_s - start) % 10 ))
        local pos=$(( tick * 5 ))
        [ "$pos" -gt $(( width - 8 )) ] && pos=$(( width * 2 - 8 - pos ))
        while [ "$i" -lt "$pos" ];            do bar="${bar}░"; i=$(( i+1 )); done
        while [ "$i" -lt $(( pos + 8 )) ];    do bar="${bar}█"; i=$(( i+1 )); done
        while [ "$i" -lt "$width" ];          do bar="${bar}░"; i=$(( i+1 )); done
        pct=0
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
        if   [ "$elapsed" -ge 3600 ]; then elapsed_str="$(( elapsed/3600 ))h$(( (elapsed%3600)/60 ))m$(( elapsed%60 ))s"
        elif [ "$elapsed" -ge 60   ]; then elapsed_str="$(( elapsed/60 ))m$(( elapsed%60 ))s"
        else                               elapsed_str="${elapsed}s"; fi
    fi

    # ── ETA (EWMA cross-checked with wall-clock) ──────────────────────────
    local eta_str="--"
    if [ "$cur" -gt 0 ] && [ "$eta" -gt 2 ]; then
        local wc_eta=0
        [ "$elapsed" -gt 0 ] && wc_eta=$(( elapsed * ( tot - cur ) / cur ))
        local best_eta; best_eta=$(( eta > wc_eta ? eta : wc_eta ))
        if   [ "$best_eta" -ge 3600 ]; then eta_str="$(( best_eta/3600 ))h$(( (best_eta%3600)/60 ))m$(( best_eta%60 ))s"
        elif [ "$best_eta" -ge 60   ]; then eta_str="$(( best_eta/60 ))m$(( best_eta%60 ))s"
        else                                eta_str="${best_eta}s"; fi
    fi

    # ── Speed (steps/min) ─────────────────────────────────────────────────
    local speed_str="--"
    if [ "$elapsed" -gt 0 ] && [ "$cur" -gt 0 ]; then
        local spm=$(( cur * 60 / elapsed ))
        speed_str="${spm} files/min"
    fi

    # ── Recent files (last 3) ─────────────────────────────────────────────
    local recent_str=""
    for _f in $_HUD_LAST_FILES; do
        [ -n "$recent_str" ] && recent_str="${recent_str}  ${_DIM}›${_R}  "
        recent_str="${recent_str}${_DIM}${_f}${_R}"
    done
    [ -z "$recent_str" ] && recent_str="${_DIM}waiting...${_R}"

    # ── Warn/error badge ──────────────────────────────────────────────────
    local warn_badge="" err_badge=""
    [ "$_HUD_WARNINGS" -gt 0 ] && warn_badge="${_YLW}⚠  ${_HUD_WARNINGS} warn${_R}  "
    [ "$_HUD_ERRORS"   -gt 0 ] && err_badge="${_RED}✖  ${_HUD_ERRORS} err${_R}  "
    local badge_str="${warn_badge}${err_badge}"
    [ -z "$badge_str" ] && badge_str="${_DIM}no issues${_R}"

    # ── Draw to /dev/tty ──────────────────────────────────────────────────
    {
        [ "${_HUD_DRAWN:-0}" -eq 1 ] && printf "\033[4A"
        _HUD_DRAWN=1
        if [ "$tot" -eq 0 ]; then
            printf "\033[K${_MAG}  [%s] ??%%${_R}  ${_DIM}(%d compiled — calculating total...)${_R}\n" \
                "$bar" "$cur"
        else
            printf "\033[K${_MAG}  [%s] %3d%%${_R}  ${_DIM}(%d / %d)${_R}\n" \
                "$bar" "$pct" "$cur" "$tot"
        fi
        printf "\033[K  ${_CYN}elapsed${_R} %-10s  ${_CYN}ETA${_R} %-12s  ${_CYN}compile speed${_R} %s\n" \
            "$elapsed_str" "$eta_str" "$speed_str"
        printf "\033[K  ${_CYN}compiling${_R}  %s\n" "$recent_str"
        printf "\033[K  ${_CYN}status${_R}  %s  ${_DIM}jobs=${_HUD_JOBS}${_R}\n" \
            "$badge_str"
    } > /dev/tty
}

# ══════════════════════════════════════════════════════════════════════════
#  _make_compile_bar <phase> [make args…]
#
#  phase — "64" or "32", used to scale the source-file estimate.
#
#  Counts compilable source files in the Wine tree with `find` (~0.3s,
#  zero interference with make) rather than `make -n` (which runs
#  sub-makes in the build directory and deadlocks against the real make).
#  Falls back to plain _make_logged when /dev/tty is unavailable or
#  VERBOSE_BUILD=true.
# ══════════════════════════════════════════════════════════════════════════
_make_compile_bar() {
    local _phase="$1"; shift   # "64" or "32"
    local _opencl_make_arg=()
    [ -n "${OPENCL_LIBS:-}" ] && _opencl_make_arg=("OPENCL_LIBS=${OPENCL_LIBS}")

    if [ ! -e /dev/tty ] || [ "${VERBOSE_BUILD:-false}" = "true" ]; then
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
    _HUD_DRAWN=0
    _HUD_WARNINGS=0
    _HUD_ERRORS=0
    _HUD_LAST_FILES=""
    _HUD_JOBS="$JOBS"

    # ── Let the user know the bar will be quiet for a while ──────────────
    # Wine builds its own host tools (winebuild, wrc, widl, makedep …) before
    # compiling any .c files.  The counter won't move during this phase since
    # those steps don't produce -c/-o style output we can count.
    printf "\n" > /dev/tty
    printf "  ${_CYN}${_B}Heads up:${_R} compilation takes a few minutes to start.\n" > /dev/tty
    printf "  Wine bootstraps its build tools first — the bar will sit at 0%%\n" > /dev/tty
    printf "  until that finishes.  Everything is working, please wait... :3\n" > /dev/tty
    printf "\n\n\n\n" > /dev/tty
    _draw_bar 0 "$_total" "bootstrapping build tools..." "$_start" 0

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
                { printf "\033[4B"; printf "%s\n" "$_line"; printf "\033[4A"; } > /dev/tty
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
                local _basename="${_file##*/}"
                if [[ "$_file" =~ ^tools/|/tools/ ]]; then
                    _label="bootstrapping: ${_basename}"
                else
                    _label="$_basename"
                    local _f1 _f2
                    _f1="${_HUD_LAST_FILES%% *}"
                    _f2="${_HUD_LAST_FILES#* }"; _f2="${_f2%% *}"
                    _HUD_LAST_FILES="${_label} ${_f1} ${_f2}"
                fi
            fi
        done < "$_tmp_out"

        kill -0 "$_make_pid" 2>/dev/null && > "$_tmp_out" || break
        _draw_bar "$_cur" "$_total" "$_label" "$_start" "$_eta"
        sleep 0.1
    done

    wait "$_make_pid"; _make_exit=$?

    while IFS= read -r _line; do
        printf '%s\n' "$_line" >> "$BUILD_LOG"
        if [[ "$_line" =~ error:|fatal\ error:|make.*Error ]]; then
            { printf "\r\033[K"; printf "%s\n" "$_line"; } > /dev/tty
        fi
    done < "$_tmp_out"
    rm -f "$_tmp_out"
    set -e

    if [ "$_make_exit" -ne 0 ]; then
        printf "\n" > /dev/tty
        printf "${_RED}Make failed (exit %d) — last output:${_R}\n" "$_make_exit" >&2
        tail -20 "$BUILD_LOG" >&2
        return "$_make_exit"
    fi

    [ "$_total" -lt "$_cur" ] && _total="$_cur"
    _HUD_LAST_FILES="done"
    _draw_bar "$_total" "$_total" "complete ✓" "$_start" 0
    printf "\n" > /dev/tty
}

# ══════════════════════════════════════════════════════════════════════════
#  _run_configure  — run Wine's configure with a live indeterminate spinner
#
#  configure outputs "checking for X... yes/no" for each autoconf test.
#  We can't know the total upfront so we use an indeterminate spinner and
#  show a live count + the current check being tested.
#
#  Usage: _run_configure <configure-binary> [args...]
# ══════════════════════════════════════════════════════════════════════════
_run_configure() {
    if [ ! -e /dev/tty ] || [ "${VERBOSE_BUILD:-false}" = "true" ]; then
        "$@" 2>&1 | tee -a "$BUILD_LOG"
        return
    fi

    local _tmp _pid _exit _cur=0 _label="starting" _start _spinstr='|/-\'
    _tmp=$(mktemp)
    _start=$(date +%s)

    # Reserve 2 lines for the configure HUD
    printf "\n\n" > /dev/tty
    tput civis 2>/dev/null || true

    "$@" > "$_tmp" 2>&1 &
    _pid=$!

    while kill -0 "$_pid" 2>/dev/null || [ -s "$_tmp" ]; do
        while IFS= read -r _line; do
            printf '%s\n' "$_line" >> "$BUILD_LOG"
            if printf '%s' "$_line" | grep -qE '^checking '; then
                _cur=$(( _cur + 1 ))
                _label="$(printf '%s' "$_line" \
                    | sed 's/^checking //' \
                    | sed 's/\.\.\..*//' \
                    | cut -c1-60)"
            fi
        done < "$_tmp"
        kill -0 "$_pid" 2>/dev/null && > "$_tmp" || break

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

    while IFS= read -r _line; do
        printf '%s\n' "$_line" >> "$BUILD_LOG"
    done < "$_tmp"
    rm -f "$_tmp"
    tput cnorm 2>/dev/null || true
    printf "\033[2A\033[J" > /dev/tty

    if [ "$_exit" -ne 0 ]; then
        printf "${_RED}[ ✘ ]${_R} configure failed (exit %d)\n" "$_exit" >&2
        printf "${_YLW}── Last 20 lines of %s ──${_R}\n" "$BUILD_LOG" >&2
        tail -n 20 "$BUILD_LOG" >&2
        return "$_exit"
    fi
    printf "${_GRN} ✓  ${_R}configure complete  ${_DIM}(%d checks)${_R}\n" "$_cur"
}

# ══════════════════════════════════════════════════════════════════════════
#  ERR trap — show a build log excerpt on unexpected failure
# ══════════════════════════════════════════════════════════════════════════
_core_on_error() {
    local exit_code=$?
    local line="$1"
    printf "\n${_RED}${_B}wine-build-core: failed at line %d (exit %d)${_R}\n\n" \
        "$line" "$exit_code" >&2
    if [ -f "$BUILD_LOG" ]; then
        printf "${_YLW}── Last 50 lines of %s ──${_R}\n\n" "$BUILD_LOG" >&2
        tail -n 50 "$BUILD_LOG" >&2
        printf "\n${_DIM}Full log: %s${_R}\n" "$BUILD_LOG" >&2
    fi
    exit "$exit_code"
}
trap '_core_on_error $LINENO' ERR

# ══════════════════════════════════════════════════════════════════════════
#  Overview
# ══════════════════════════════════════════════════════════════════════════
sep "Wine Build Core"
msg2 "Source    : ${WINE_SOURCE_DIR}"
msg2 "Install   : ${INSTALL_PREFIX}"
msg2 "Build root: ${BUILD_RUN_DIR}"
msg2 "Jobs      : ${JOBS}"
msg2 "32-bit    : $([ "$SKIP_32BIT" = true ] && printf 'skip' || printf 'yes')"
msg2 "Resume    : ${RESUME}"
msg2 "Build log : ${BUILD_LOG}"

# configure must be executable
[ -x "${WINE_SOURCE_DIR}/configure" ] || \
    err "configure not found or not executable at: ${WINE_SOURCE_DIR}/configure"

# ══════════════════════════════════════════════════════════════════════════
#  User patch application
#  Drop .patch / .diff files into a patches/ directory alongside this script
#  to have them automatically applied here (idempotent via --forward).
# ══════════════════════════════════════════════════════════════════════════
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
    msg2 "No patches/ directory found — skipping"
    mkdir -p "${PATCH_DIR}"
    msg2 "Created ${PATCH_DIR} — drop .patch files there for next run"
fi

# ══════════════════════════════════════════════════════════════════════════
#  Source compatibility fixes
#  Idempotent in-tree edits for known build-system / API mismatches.
#  Each fix checks for its own marker before applying.
# ══════════════════════════════════════════════════════════════════════════
sep "Source compatibility fixes"

# ── Fix: is_sdl_ignored_device when built --without-sdl ────────────────
# bus_udev.c calls is_sdl_ignored_device() unconditionally but that function
# is defined only in bus_sdl.c (omitted when SDL is disabled).
# Replacing the call site with the compile-time constant FALSE is the
# correct fix: unix_private.h already has an extern declaration that would
# clash with any stub we might add.
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
        ok "bus_udev.c  (already patched)"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════
#  Re-hydrate configure arg arrays from config file
#  Bash cannot export arrays across process boundaries.  We re-source the
#  config here, where the arrays are actually used.
# ══════════════════════════════════════════════════════════════════════════
sep "Loading configuration"
_CFG="${CUSTOM_CFG:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/customization.cfg}"
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

# ══════════════════════════════════════════════════════════════════════════
#  OpenCL forced linking
#  Wine's configure header check for OpenCL often fails even when the
#  library is present.  Force OPENCL_LIBS when libOpenCL.so is installed.
# ══════════════════════════════════════════════════════════════════════════
if [ -z "${OPENCL_LIBS:-}" ]; then
    if ldconfig -p 2>/dev/null | grep -q 'libOpenCL\.so '; then
        export OPENCL_LIBS="-lOpenCL"
        ok "libOpenCL.so found — OPENCL_LIBS set to -lOpenCL"
    else
        warn "libOpenCL.so not found in ldconfig — OpenCL disabled"
        warn "Install: sudo apt install ocl-icd-opencl-dev"
    fi
else
    ok "OPENCL_LIBS already set: ${OPENCL_LIBS}"
fi

# ══════════════════════════════════════════════════════════════════════════
#  ccache helper
# ══════════════════════════════════════════════════════════════════════════
_wrap_cc() {
    # Respect NO_CCACHE toggle
    if [ "${NO_CCACHE:-false}" != "true" ] && command -v ccache >/dev/null 2>&1; then
        printf "ccache %s" "$1"
    else
        printf "%s" "$1"
    fi
}

# ══════════════════════════════════════════════════════════════════════════
#  Apply build tuning flags from toggles
# ══════════════════════════════════════════════════════════════════════════
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

# ══════════════════════════════════════════════════════════════════════════
#  Resume helper
#  Returns 0 (run configure) or 1 (skip configure) based on RESUME flag
#  and the presence of a Makefile in the given build directory.
# ══════════════════════════════════════════════════════════════════════════
_needs_configure() {
    local build_dir="$1"
    if [ "${RESUME}" = "true" ] && [ -f "${build_dir}/Makefile" ]; then
        msg2 "--resume: Makefile exists in ${build_dir} — skipping configure"
        return 1
    fi
    return 0
}

# ══════════════════════════════════════════════════════════════════════════
#  64-bit build
# ══════════════════════════════════════════════════════════════════════════
sep "64-bit configure"
mkdir -p "$BUILD64"

export CC="$(_wrap_cc gcc)"
export CXX="$(_wrap_cc g++)"
export PKG_CONFIG_PATH="/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig:/usr/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="${PKG_CONFIG_PATH}"
export LDFLAGS="${LDFLAGS:-} -L/usr/lib/x86_64-linux-gnu -L/lib/x86_64-linux-gnu ${_lto_flags}"
export CFLAGS="${_opt_flags} ${_lto_flags}"
export CXXFLAGS="${_opt_flags} ${_lto_flags}"

msg2 "CC              = ${CC}"
msg2 "PKG_CONFIG_PATH = ${PKG_CONFIG_PATH}"

cd "$BUILD64"
if _needs_configure "$BUILD64"; then
    _run_configure "${WINE_SOURCE_DIR}/configure" \
        --prefix="${INSTALL_PREFIX}" \
        --enable-win64 \
        --build=x86_64-linux-gnu \
        ${OPENCL_LIBS:+OPENCL_LIBS="${OPENCL_LIBS}"} \
        "${_args_common[@]+"${_args_common[@]}"}" \
        "${_args_64[@]+"${_args_64[@]}"}"
fi

sep "64-bit compile  (jobs=${JOBS})"
_make_compile_bar 64 -j"${JOBS}"
ok "64-bit build complete"

# ══════════════════════════════════════════════════════════════════════════
#  32-bit build  (cross-compile via i686-linux-gnu-gcc)
#
#  Why i686-linux-gnu-gcc rather than gcc -m32:
#    A -m32 wrapper appears to autoconf as a native compiler, so autoconf
#    tries to *execute* the compiled test binary.  On an x86_64 host that
#    binary is 32-bit ELF and execution will hang or fail.
#    i686-linux-gnu-gcc has the target triplet in its name, so autoconf
#    immediately treats it as a cross-compiler and skips execution tests.
#    --build / --host flags below reinforce this.
# ══════════════════════════════════════════════════════════════════════════
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

    # MinGW PE cross-compilers (Windows .dll side of the build)
    export CROSSCC="${CC_32:-i686-w64-mingw32-gcc}"
    export CROSSCXX="${CXX_32:-i686-w64-mingw32-g++}"

    export PKG_CONFIG_LIBDIR="/usr/lib/i386-linux-gnu/pkgconfig:/usr/share/pkgconfig:/usr/lib/pkgconfig"
    export PKG_CONFIG_PATH="${PKG_CONFIG_LIBDIR}"

    # No -m32 needed — the cross-compiler already targets i686.
    export CFLAGS="${_opt_flags} ${_lto_flags} -I/usr/include/freetype2 -I/usr/include/wayland"
    export CPPFLAGS="-I/usr/include/freetype2 -I/usr/include/wayland"
    export LDFLAGS="-L/usr/lib/i386-linux-gnu -L/usr/lib32 -L/lib/i386-linux-gnu ${_lto_flags}"

    msg2 "CC              = ${CC}"
    msg2 "CROSSCC         = ${CROSSCC}"
    msg2 "PKG_CONFIG_PATH = ${PKG_CONFIG_PATH}"

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

# ══════════════════════════════════════════════════════════════════════════
#  Verify build artifacts before handing back to wine-builder.sh
# ══════════════════════════════════════════════════════════════════════════
sep "Verifying build artifacts"

_verify_artifact() {
    local path="$1" label="$2"
    if [ -f "$path" ]; then
        ok "$label"
    else
        warn "Expected artifact not found: $path"
    fi
}

_verify_artifact "${BUILD64}/loader/wine"      "wine loader (64-bit tree)"
_verify_artifact "${BUILD64}/server/wineserver" "wineserver (64-bit tree)"
if [ "${SKIP_32BIT}" != "true" ]; then
    _verify_artifact "${BUILD32}/loader/wine" "wine (32-bit loader)"
fi

sep "Build complete"
ok "All Wine components compiled successfully"
msg2 "Build artifacts  : ${BUILD_RUN_DIR}"
msg2 "Build log        : ${BUILD_LOG}"
msg2 "wine-builder.sh will now run 'make install' into ${INSTALL_PREFIX}"
