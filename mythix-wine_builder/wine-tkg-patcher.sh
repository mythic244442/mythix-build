#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════╗
# ║               wine-tkg-patcher  •  staging + custom patches           ║
# ╚═══════════════════════════════════════════════════════════════════════╝
#
# Applies wine-staging patches to a mainline Wine source tree, then applies
# any additional patches from a user-maintained patches/ directory.
#
# Called by wine-builder.sh for the tkg-patched source.  Can also be run
# standalone:
#
#   ./wine-tkg-patcher.sh <wine-source-dir> [staging-cache-dir]
#
# Arguments:
#   wine-source-dir   — absolute path to a mainline Wine source clone
#   staging-cache-dir — where wine-staging is cloned/cached
#                       (default: <script-dir>/src/wine-staging-patches)
#
# Environment variables (all optional):
#   STAGING_BRANCH   — override the wine-staging branch/tag to use
#                      (default: auto-detected from the wine source version)
#   JOBS             — parallel jobs for any make steps (not used here, but
#                      forwarded to wine-build-core.sh)
#   NO_PULL          — set to "true" to skip git pull on existing staging clone
#   DRY_RUN          — set to "1" to print actions without executing them
#   PATCH_LOG        — path for patch application log
#                      (default: <wine-source-dir>/../tkg-patch.log)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# ── Output helpers ────────────────────────────────────────────────────────
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
    _R="\033[0m" _B="\033[1m"
    _GRN="\033[1;32m" _BLU="\033[1;34m"
    _YLW="\033[1;33m" _RED="\033[1;31m"
    _DIM="\033[2m" _CYN="\033[1;36m"
else
    _R="" _B="" _GRN="" _BLU="" _YLW="" _RED="" _DIM="" _CYN=""
fi
msg()  { printf "${_GRN}==> ${_R}${_B}%s${_R}\n" "$*"; }
msg2() { printf "${_BLU} -> ${_R}%s\n" "$*"; }
ok()   { printf "${_GRN} ✓  ${_R}%s\n" "$*"; }
warn() { printf "${_YLW}warn${_R} %s\n" "$*" >&2; }
err()  { printf "${_RED}ERR!${_R} %s\n" "$*" >&2; exit 1; }
sep()  { printf "\n${_CYN}${_B}── %s ──${_R}\n" "$*"; }
dim()  { printf "${_DIM}%s${_R}\n" "$*"; }

# ── Arguments ─────────────────────────────────────────────────────────────
WINE_SRC="${1:?Usage: $0 <wine-source-dir> [staging-cache-dir]}"
WINE_SRC="$(realpath "$WINE_SRC")"
[ -d "$WINE_SRC" ] || err "Wine source directory not found: $WINE_SRC"

STAGING_CACHE="${2:-${SCRIPT_DIR}/src/wine-staging-patches}"
DRY_RUN="${DRY_RUN:-0}"
NO_PULL="${NO_PULL:-false}"
PATCH_LOG="${PATCH_LOG:-${WINE_SRC}/../tkg-patch.log}"
PATCH_LOG="$(realpath -m "$PATCH_LOG")"

# User-supplied extra patches live here alongside the builder scripts.
PATCHES_DIR="${SCRIPT_DIR}/patches"

sep "Wine TKG Patcher"
msg2 "Wine source   : $WINE_SRC"
msg2 "Staging cache : $STAGING_CACHE"
msg2 "Extra patches : $PATCHES_DIR"
msg2 "Patch log     : $PATCH_LOG"

# Initialise the patch log
{
    printf '# wine-tkg-patcher log\n'
    printf '# Started : %s\n' "$(date)"
    printf '# Source  : %s\n\n' "$WINE_SRC"
} > "$PATCH_LOG"

# ── Detect Wine version from the source tree ──────────────────────────────
# configure.ac carries the version as:  AC_INIT([Wine],[10.6])
# Fall back to git describe if configure.ac doesn't parse cleanly.
sep "Detecting Wine version"

_detect_wine_version() {
    local src="$1"
    local ver=""

    # Priority 1: STAGING_BRANCH_HINT set by wine-builder.sh from the actual
    # tag/branch it cloned.  This is the most reliable source — use it first.
    if [ -n "${STAGING_BRANCH_HINT:-}" ]; then
        ver="${STAGING_BRANCH_HINT#wine-staging-}"
        ver="${ver#wine-}"
        ver="${ver#v}"
        [[ "$ver" =~ ^[0-9]+\.[0-9] ]] || ver=""
    fi

    # Priority 2: git describe — works on depth=1 clones when the tag is at HEAD
    if [ -z "$ver" ] && [ -d "$src/.git" ]; then
        ver=$(git -C "$src" describe --tags --abbrev=0 2>/dev/null \
              | sed 's/^wine-//' || true)
        [[ "$ver" =~ ^[0-9]+\.[0-9] ]] || ver=""
    fi

    # Priority 3: configure.ac literal version field
    # Note: modern Wine uses the macro WINE_VERSION here instead of a literal
    # number, so this often fails — it's a last resort only.
    if [ -z "$ver" ] && [ -f "$src/configure.ac" ]; then
        ver=$(grep -m1 'AC_INIT.*Wine' "$src/configure.ac" \
              | sed -E 's/.*\[([0-9]+\.[0-9]+[^]]*)\].*/\1/' || true)
        [[ "$ver" =~ ^[0-9]+\.[0-9] ]] || ver=""
    fi

    printf '%s' "$ver"
}

WINE_VERSION="$(_detect_wine_version "$WINE_SRC")"
if [ -n "$WINE_VERSION" ]; then
    ok "Wine version detected: $WINE_VERSION"
else
    warn "Could not detect Wine version — will use wine-staging default branch"
fi

# ── Resolve wine-staging branch / tag ────────────────────────────────────
# wine-staging uses tag format: v10.6
# If the user pre-set STAGING_BRANCH, honour it; otherwise derive from version.
sep "Resolving wine-staging version"

STAGING_URL="https://github.com/wine-staging/wine-staging.git"

# Fetch all available staging tags once — used for both exact match and
# best-available fallback.  Returns lines like: v10.3  v10.2  v9.22 ...
_fetch_staging_tags() {
    git ls-remote --tags --refs "$STAGING_URL" 2>/dev/null \
        | awk '{print $2}' \
        | sed 's|refs/tags/||' \
        | grep -E '^v[0-9]+\.[0-9]' \
        | sort -Vr
}

# Find the best staging tag that is <= the requested wine version.
# Wine version format: MAJOR.MINOR (e.g. 10.4)
# Staging tag format:  vMAJOR.MINOR (e.g. v10.3)
# Strategy: take all staging tags, filter to same major, pick highest
# minor that is <= requested minor.  If none, try the previous major.
_best_staging_tag() {
    local wine_ver="$1"   # e.g. "10.4"
    local all_tags="$2"   # newline-separated list of tags
    local major minor best_tag candidate c_major c_minor

    major="${wine_ver%%.*}"
    minor="${wine_ver#*.}"

    # Strip any rc/alpha suffix from minor for numeric comparison
    minor="${minor%%-*}"

    best_tag=""
    while IFS= read -r candidate; do
        # strip leading v
        local cv="${candidate#v}"
        c_major="${cv%%.*}"
        c_minor="${cv#*.}"
        c_minor="${c_minor%%-*}"
        # Same major, minor <= requested
        if [ "$c_major" -eq "$major" ] 2>/dev/null && \
           [ "$c_minor" -le "$minor" ] 2>/dev/null; then
            best_tag="$candidate"
            break   # list is already sorted newest-first
        fi
    done <<< "$all_tags"

    # If nothing found for this major, fall back to the latest tag from
    # the previous major version
    if [ -z "$best_tag" ]; then
        while IFS= read -r candidate; do
            local cv="${candidate#v}"
            c_major="${cv%%.*}"
            if [ "$c_major" -lt "$major" ] 2>/dev/null; then
                best_tag="$candidate"
                break
            fi
        done <<< "$all_tags"
    fi

    printf '%s' "$best_tag"
}

if [ -n "${STAGING_BRANCH:-}" ]; then
    _staging_ref="$STAGING_BRANCH"
    msg2 "Using user-supplied staging ref: $_staging_ref"
elif [ -n "$WINE_VERSION" ]; then
    msg2 "Querying wine-staging for best available tag ≤ v${WINE_VERSION}..."
    _all_staging_tags="$(_fetch_staging_tags)"
    _staging_ref="$(_best_staging_tag "$WINE_VERSION" "$_all_staging_tags")"
    if [ -n "$_staging_ref" ]; then
        if [ "$_staging_ref" = "v${WINE_VERSION}" ]; then
            ok "Exact staging match: $_staging_ref"
        else
            warn "wine-staging v${WINE_VERSION} not found — using closest available: $_staging_ref"
            warn "Patches should apply cleanly; minor version differences are usually fine."
            warn "To override: STAGING_BRANCH=v<ver> ./wine-builder.sh --source tkg-patched"
        fi
    else
        warn "No suitable wine-staging tag found — using default branch."
        warn "Patches may not apply cleanly. Consider: STAGING_BRANCH=v<ver> ./wine-builder.sh"
    fi
else
    _staging_ref=""
    msg2 "No version detected — will use wine-staging default branch"
fi

# ── Clone / update wine-staging ───────────────────────────────────────────
sep "Fetching wine-staging"

if [ "$DRY_RUN" -eq 1 ]; then
    dim "  [dry-run] git clone/pull wine-staging → $STAGING_CACHE"
elif [ -d "$STAGING_CACHE/.git" ]; then
    if [ "$NO_PULL" = "true" ]; then
        ok "Staging cache exists — NO_PULL set, skipping update"
    else
        msg2 "Updating staging cache: $STAGING_CACHE"
        git -C "$STAGING_CACHE" fetch --prune
        if [ -n "$_staging_ref" ]; then
            git -C "$STAGING_CACHE" checkout "$_staging_ref" --
        else
            git -C "$STAGING_CACHE" checkout "$(git -C "$STAGING_CACHE" remote show origin \
                | awk '/HEAD branch/ {print $NF}')" --
            git -C "$STAGING_CACHE" pull --ff-only \
                || warn "git pull failed on staging cache — continuing with current state"
        fi
    fi
else
    msg2 "Cloning wine-staging → $STAGING_CACHE"
    mkdir -p "$(dirname "$STAGING_CACHE")"
    if [ -n "$_staging_ref" ]; then
        git clone --depth=1 --branch "$_staging_ref" "$STAGING_URL" "$STAGING_CACHE"
    else
        git clone --depth=1 "$STAGING_URL" "$STAGING_CACHE"
    fi
fi

[ "$DRY_RUN" -eq 1 ] || ok "wine-staging ready at: $STAGING_CACHE"

# ── Apply wine-staging patches ────────────────────────────────────────────
sep "Applying wine-staging patches"

_PATCHINSTALL="$STAGING_CACHE/staging/patchinstall.py"
_GITAPPLY="$STAGING_CACHE/patches/gitapply.sh"

# Sanity check — need at least one applicator
if [ ! -f "$_PATCHINSTALL" ] && [ ! -f "$_GITAPPLY" ]; then
    err "Neither staging/patchinstall.py nor patches/gitapply.sh found in $STAGING_CACHE
     The staging clone may be incomplete.
     Try removing the cache and re-running: rm -rf \"$STAGING_CACHE\""
fi

if [ "$DRY_RUN" -eq 1 ]; then
    dim "  [dry-run] apply wine-staging patches to $WINE_SRC"
elif [ -f "$_PATCHINSTALL" ]; then
    # ── patchinstall.py path (preferred) ──────────────────────────────────
    # patchinstall.py resolves patch dependencies and applies them in the
    # correct order.  This is the canonical way to apply wine-staging.
    msg2 "Using patchinstall.py (handles patch ordering + dependencies)"
    msg2 "Applying full staging patchset — this may take a minute..."
    (
        cd "$STAGING_CACHE"
        python3 staging/patchinstall.py \
            --all \
            DESTDIR="$WINE_SRC" \
            >> "$PATCH_LOG" 2>&1
    ) || {
        printf "\n${_RED}Staging patch application failed.${_R}\n" >&2
        printf "Last 30 lines of patch log:\n" >&2
        tail -30 "$PATCH_LOG" >&2
        printf "\nFull log: %s\n" "$PATCH_LOG" >&2
        err "patchinstall.py failed — see log above."
    }
    ok "wine-staging patches applied via patchinstall.py"
else
    # ── gitapply.sh fallback ───────────────────────────────────────────────
    # Used when patchinstall.py is absent (newer staging repo layout).
    # Applies all .patch files sorted by path; note that without dependency
    # resolution a small number of patches may fail due to ordering — these
    # are warned about and skipped rather than aborting the build.
    [ -x "$_GITAPPLY" ] || chmod +x "$_GITAPPLY"
    msg2 "patchinstall.py not found — using gitapply.sh fallback"
    msg2 "Applying via gitapply.sh — this may take a minute..."

    mapfile -t _staging_patches < <(
        find "$STAGING_CACHE/patches" -name '*.patch' | sort
    )

    if [ "${#_staging_patches[@]}" -eq 0 ]; then
        warn "No .patch files found in $STAGING_CACHE/patches — staging may be empty."
    else
        ok "Found ${#_staging_patches[@]} staging patch file(s)"
        _s_ok=0 _s_skip=0 _s_fail=0
        for _p in "${_staging_patches[@]}"; do
            _pname="$(basename "$(dirname "$_p")")/$(basename "$_p")"
            if bash "$_GITAPPLY" -d "$WINE_SRC" < "$_p" >> "$PATCH_LOG" 2>&1; then
                (( _s_ok++ )) || true
            else
                if grep -q 'already exists\|Reversed.*already\|patch does not apply' \
                        "$PATCH_LOG" 2>/dev/null; then
                    (( _s_skip++ )) || true
                else
                    warn "Patch failed: $_pname (see $PATCH_LOG)"
                    (( _s_fail++ )) || true
                fi
            fi
        done
        ok "Staging patches: ${_s_ok} applied, ${_s_skip} skipped, ${_s_fail} failed"
        if [ "$_s_fail" -gt 0 ]; then
            warn "${_s_fail} patch(es) failed — the build will continue."
            warn "Check for .rej files in $WINE_SRC and review $PATCH_LOG"
        fi
    fi
fi

# ── Apply user / curated TKG extra patches ────────────────────────────────
sep "Applying extra patches (patches/)"

if [ ! -d "$PATCHES_DIR" ]; then
    mkdir -p "$PATCHES_DIR"
    msg2 "Created $PATCHES_DIR"
    msg2 "Drop .patch or .diff files there to have them applied automatically."
    msg2 "Tip: browse https://github.com/Frogging-Family/wine-tkg-git/tree/master/wine-tkg-git/wine-tkg-patches"
    msg2 "     for patches — download whichever ones interest you into patches/"
else
    shopt -s nullglob
    _extra_patches=( "$PATCHES_DIR"/*.patch "$PATCHES_DIR"/*.diff )
    shopt -u nullglob

    if [ "${#_extra_patches[@]}" -eq 0 ]; then
        msg2 "No extra patches in $PATCHES_DIR — skipping"
        msg2 "Tip: drop .patch / .diff files there to have them applied here."
    else
        ok "Found ${#_extra_patches[@]} extra patch(es)"
        for _p in "${_extra_patches[@]}"; do
            msg2 "Applying: $(basename "$_p")"
            if [ "$DRY_RUN" -eq 1 ]; then
                dim "  [dry-run] patch -d $WINE_SRC -Np1 < $(basename "$_p")"
            else
                if patch -d "$WINE_SRC" -Np1 --forward < "$_p" >> "$PATCH_LOG" 2>&1; then
                    ok "  $(basename "$_p")"
                else
                    warn "  $(basename "$_p") — had fuzz or failed (see $PATCH_LOG)"
                    warn "  The build will continue; check for .rej files in $WINE_SRC"
                fi
            fi
        done
    fi
fi

sep "Patching complete"
ok "Wine source is ready for configure + make"
msg2 "Source : $WINE_SRC"
msg2 "Log    : $PATCH_LOG"
