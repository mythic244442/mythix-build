#!/usr/bin/env bash
# ╔═════════════════════════════════════════════════════════════════════════════╗
# ║   mythix-neutron_builder  •  mythix-ge-pipeline.sh                          ║
# ║   Mythix Wine source preparation for "ge" pipeline profiles                 ║
# ╚═════════════════════════════════════════════════════════════════════════════╝
#
# Builds the Mythix Wine source tree for a profile whose PROFILE_PIPELINE="ge":
#
#   1. Valve wine at the pinned commit (defaults to GE's own submodule pin)
#   2. GE's protonprep-valve-staging.sh "WINE PATCHING" section, run verbatim
#      from a GE checkout at the pinned commit: wine-staging (with GE's
#      exclusions) + GE's patches, including all of GE's Wayland work
#   3. The profile's own patches  (profiles/<name>/patches/*.patch, strict)
#   4. Mythix version branding    (wine --version → wine-<label>-mythix.<base>)
#
# Every layer is committed inside the wine checkout ("mythix: …") so the tree
# can be inspected/bisected, and the resolved inputs are written to
# <log-dir>/mythix-source.lock.
#
# Layout under --work-dir mirrors the GE repository, so GE's script runs
# exactly as GE runs it:
#   <work-dir>/                GE checkout (proton-ge-custom)
#   <work-dir>/wine            Valve wine checkout  ← the tree that gets built
#   <work-dir>/wine-staging    wine-staging checkout
#
# Usage:
#   mythix-ge-pipeline.sh --profile-dir DIR --work-dir DIR [--log-dir DIR]
#                         [--offline] [--allow-patch-failures]
#
#   --offline               never touch the network; every pinned commit must
#                           already be present locally
#   --allow-patch-failures  keep going when a GE/staging patch fails
#                           (default: stop — a half-applied stack is worse
#                           than no build)
#
# Exit status: 0 success, 1 error, 2 patch failure.
set -euo pipefail

_SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
    C_R="\033[0m" C_B="\033[1m" C_GRN="\033[1;32m" C_BLU="\033[1;34m"
    C_YLW="\033[1;33m" C_RED="\033[1;31m" C_CYN="\033[1;35m" C_MAG="\033[1;36m"
    C_DIM="\033[2m"
else
    C_R="" C_B="" C_GRN="" C_BLU="" C_YLW="" C_RED="" C_CYN="" C_MAG="" C_DIM=""
fi
# shellcheck source=_output_common.sh
. "${_SELF_DIR}/_output_common.sh"

# ── Arguments ─────────────────────────────────────────────────────────────────
PROFILE_DIR="" WORK_DIR="" LOG_DIR=""
OFFLINE=false
ALLOW_PATCH_FAILURES="${MYTHIX_ALLOW_PATCH_FAILURES:-false}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --profile-dir)          PROFILE_DIR="$2"; shift 2 ;;
        --work-dir)             WORK_DIR="$2";    shift 2 ;;
        --log-dir)              LOG_DIR="$2";     shift 2 ;;
        --offline)              OFFLINE=true;     shift   ;;
        --allow-patch-failures) ALLOW_PATCH_FAILURES=true; shift ;;
        -h|--help)              sed -n '2,38p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) err "unknown option: $1" ;;
    esac
done

[ -n "$PROFILE_DIR" ] || err "--profile-dir is required"
[ -n "$WORK_DIR" ]    || err "--work-dir is required"
PROFILE_DIR="$(cd "$PROFILE_DIR" && pwd)" || err "profile dir not found"
mkdir -p "$WORK_DIR"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
LOG_DIR="${LOG_DIR:-${WORK_DIR}/logs}"
mkdir -p "$LOG_DIR"
LOG_DIR="$(cd "$LOG_DIR" && pwd)"

[ -f "${PROFILE_DIR}/profile.conf" ] || err "no profile.conf in ${PROFILE_DIR}"
# shellcheck source=/dev/null
. "${PROFILE_DIR}/profile.conf"

PROFILE_NAME="$(basename "$PROFILE_DIR")"
[ "${PROFILE_PIPELINE:-}" = "ge" ] || \
    err "${PROFILE_NAME}: PROFILE_PIPELINE is '${PROFILE_PIPELINE:-}', expected 'ge'"
[ -n "${PIN_GE_COMMIT:-}" ] || err "${PROFILE_NAME}: PIN_GE_COMMIT is required"

PIN_GE_REPO="${PIN_GE_REPO:-https://github.com/GloriousEggroll/proton-ge-custom.git}"
PIN_WINE_REPO="${PIN_WINE_REPO:-https://github.com/ValveSoftware/wine.git}"
PIN_STAGING_REPO="${PIN_STAGING_REPO:-https://github.com/wine-staging/wine-staging.git}"

for tool in git patch python3 autoreconf perl; do
    command -v "$tool" >/dev/null 2>&1 || err "required tool not found: $tool"
done

# Git with a fixed identity (layer commits) and no detached-HEAD chatter.
_git() {
    git -c advice.detachedHead=false \
        -c user.name="Mythix Builder" -c user.email="builder@mythix.invalid" \
        -c core.autocrlf=false "$@"
}
git config --global --add safe.directory '*' 2>/dev/null || true

# ensure_commit <dir> <url> <sha> [depth]
#   Make sure <sha> exists in the repo at <dir>, fetching it by hash if needed.
#   Pins are fetched by SHA on purpose: Valve rewrites bleeding-edge, so a
#   commit can vanish from every branch while GitHub still serves it by hash.
ensure_commit() {
    local dir="$1" url="$2" sha="$3" depth="${4:-1}"
    if [ ! -d "${dir}/.git" ]; then
        mkdir -p "$dir"
        _git -C "$dir" init -q
        _git -C "$dir" remote add origin "$url"
    fi
    if _git -C "$dir" cat-file -e "${sha}^{commit}" 2>/dev/null; then
        return 0
    fi
    [ "$OFFLINE" = "true" ] && err "commit ${sha} is not present in ${dir} (--offline)"
    msg2 "fetching ${sha:0:12} from ${url}"
    _git -C "$dir" fetch -q --depth="$depth" origin "$sha" || \
        err "could not fetch ${sha} from ${url}
     If upstream garbage-collected this commit, mirror it and set the repo URL
     in ${PROFILE_DIR}/profile.conf."
}

# checkout_clean <dir> <sha>
checkout_clean() {
    _git -C "$1" checkout -q -f "$2"
    _git -C "$1" clean -q -xdf
}

section "Mythix GE pipeline — ${PROFILE_NAME}"
msg2 "Profile : ${PROFILE_DESC:-$PROFILE_NAME}"
msg2 "Work dir: ${WORK_DIR}"
msg2 "Logs    : ${LOG_DIR}"

# ══════════════════════════════════════════════════════════════════════════════
#  1. GE checkout
# ══════════════════════════════════════════════════════════════════════════════
sep "GE (proton-ge-custom) @ ${PIN_GE_COMMIT:0:12}"
ensure_commit "$WORK_DIR" "$PIN_GE_REPO" "$PIN_GE_COMMIT" 1
# Not checkout_clean: a superproject-wide `git clean` must never touch the
# nested wine/ and wine-staging/ checkouts that live inside the GE tree.
_git -C "$WORK_DIR" checkout -q -f "$PIN_GE_COMMIT"
[ "$(_git -C "$WORK_DIR" rev-parse HEAD)" = "$PIN_GE_COMMIT" ] || \
    err "GE checkout is not at ${PIN_GE_COMMIT}"
ok "GE at $(_git -C "$WORK_DIR" log -1 --format='%h %cs %s')"

GE_SCRIPT="${WORK_DIR}/patches/protonprep-valve-staging.sh"
[ -f "$GE_SCRIPT" ] || err "GE patch script not found: ${GE_SCRIPT}"

# Default the wine/staging pins to GE's own submodule pins (GE tests its patch
# stack against exactly these), unless the profile overrides them.
_ge_wine_pin="$(_git -C "$WORK_DIR" ls-tree HEAD wine | awk '{print $3}')"
_ge_staging_pin="$(_git -C "$WORK_DIR" ls-tree HEAD wine-staging | awk '{print $3}')"
PIN_WINE_COMMIT="${PIN_WINE_COMMIT:-$_ge_wine_pin}"
PIN_STAGING_COMMIT="${PIN_STAGING_COMMIT:-$_ge_staging_pin}"
[ -n "$PIN_WINE_COMMIT" ]    || err "could not resolve the wine pin from GE"
[ -n "$PIN_STAGING_COMMIT" ] || err "could not resolve the wine-staging pin from GE"
[ "$PIN_WINE_COMMIT" = "$_ge_wine_pin" ] || \
    warn "profile pins wine ${PIN_WINE_COMMIT:0:12}; GE was tested on ${_ge_wine_pin:0:12}"
[ "$PIN_STAGING_COMMIT" = "$_ge_staging_pin" ] || \
    warn "profile pins staging ${PIN_STAGING_COMMIT:0:12}; GE was tested on ${_ge_staging_pin:0:12}"
# GE ships its own FFmpeg (winedmo media backend); record its pin so the
# builder can build the same FFmpeg (PROFILE_FFMPEG=static).
_ge_ffmpeg_pin="$(_git -C "$WORK_DIR" ls-tree HEAD ffmpeg | awk '{print $3}')"
PIN_FFMPEG_COMMIT="${PIN_FFMPEG_COMMIT:-$_ge_ffmpeg_pin}"
PIN_FFMPEG_REPO="${PIN_FFMPEG_REPO:-https://github.com/FFmpeg/FFmpeg.git}"

# ── Extract GE's wine section: from "pushd wine" after the WINE PATCHING
#    marker to its matching popd (pushd/popd depth tracking).
_ge_start="$(grep -n '^### (2) WINE PATCHING ###' "$GE_SCRIPT" | head -1 | cut -d: -f1)"
[ -n "$_ge_start" ] || err "GE script layout changed: '### (2) WINE PATCHING ###' not found"
read -r _ge_from _ge_to < <(awk -v s="$_ge_start" '
    NR > s && !from && /^[[:space:]]*pushd[[:space:]]+wine[[:space:]]*$/ { from = NR; depth = 0 }
    from {
        if ($0 ~ /^[[:space:]]*pushd[[:space:]]/) depth++
        if ($0 ~ /^[[:space:]]*popd[[:space:]]*$/) { depth--; if (depth == 0) { print from, NR; exit } }
    }' "$GE_SCRIPT") || true
[ -n "${_ge_from:-}" ] && [ -n "${_ge_to:-}" ] || \
    err "GE script layout changed: could not find the 'pushd wine' … 'popd' block"
msg2 "GE wine section: ${GE_SCRIPT##*/} lines ${_ge_from}-${_ge_to}"

# ══════════════════════════════════════════════════════════════════════════════
#  2. Valve wine + wine-staging checkouts
# ══════════════════════════════════════════════════════════════════════════════
sep "Valve wine @ ${PIN_WINE_COMMIT:0:12}"
WINE_DIR="${WORK_DIR}/wine"
ensure_commit "$WINE_DIR" "$PIN_WINE_REPO" "$PIN_WINE_COMMIT" 1
# Commits GE reverts must exist locally (with their parent) for `git revert`.
while read -r _rev; do
    [ -n "$_rev" ] || continue
    ensure_commit "$WINE_DIR" "$PIN_WINE_REPO" "$_rev" 2
done < <(sed -n "${_ge_from},${_ge_to}p" "$GE_SCRIPT" \
            | grep -E '^[[:space:]]*git revert' | grep -oE '\b[0-9a-f]{40}\b' || true)
checkout_clean "$WINE_DIR" "$PIN_WINE_COMMIT"
# Generated junk the layer commits must never pick up.
if ! grep -q 'mythix-ge-pipeline' "${WINE_DIR}/.git/info/exclude" 2>/dev/null; then
    cat >> "${WINE_DIR}/.git/info/exclude" <<'EOF'
# mythix-ge-pipeline: generated files kept out of layer commits
autom4te.cache/
*.orig
*.rej
configure~
include/config.h.in~
EOF
fi
ok "wine at $(_git -C "$WINE_DIR" log -1 --format='%h %cs %s')"

sep "wine-staging @ ${PIN_STAGING_COMMIT:0:12}"
STAGING_DIR="${WORK_DIR}/wine-staging"
ensure_commit "$STAGING_DIR" "$PIN_STAGING_REPO" "$PIN_STAGING_COMMIT" 1
checkout_clean "$STAGING_DIR" "$PIN_STAGING_COMMIT"
ok "wine-staging at $(_git -C "$STAGING_DIR" log -1 --format='%h %cs %s')"

# GE's prep section patches wineopenxr before its files are copied into wine.
if [ -d "${WORK_DIR}/wineopenxr" ] && [ -d "${WORK_DIR}/patches/wineopenxr" ]; then
    (
        cd "${WORK_DIR}/wineopenxr"
        _git checkout -q -- .
        _git clean -q -xdf -- .
        for p in ../patches/wineopenxr/*.patch; do
            [ -e "$p" ] || continue
            patch -Np1 --no-backup-if-mismatch -s < "$p"
        done
    ) || err "GE wineopenxr prep failed"
    msg2 "wineopenxr prepared for in-tree build"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  3. GE layer — run GE's own wine section
# ══════════════════════════════════════════════════════════════════════════════
sep "GE layer (staging + GE patches + Wayland)"
_ge_section="${LOG_DIR}/mythix-ge-wine-section.sh"
_ge_log="${LOG_DIR}/mythix-ge-wine-section.log"
_ge_fail_list="${LOG_DIR}/mythix-ge-failed-patches.txt"
: > "$_ge_fail_list"
{
    printf '# Generated by mythix-ge-pipeline.sh from %s (GE %s), lines %s-%s\n' \
        "${GE_SCRIPT##*/}" "${PIN_GE_COMMIT:0:12}" "$_ge_from" "$_ge_to"
    # Same helpers GE defines, but failures are recorded instead of ignored.
    cat <<'EOF'
apply_patch() {
    local patch_path="$1"
    if ! patch -Np1 --no-backup-if-mismatch < "$patch_path"; then
        printf 'MYTHIX: patch failed: %s\n' "$patch_path" >&2
        printf '%s\n' "$patch_path" >> "$MYTHIX_GE_FAIL_LIST"
    fi
}
apply_all_in_dir() {
    local dir="$1" patch
    for patch in "$dir"/*.patch; do
        [ -e "$patch" ] || continue
        apply_patch "$patch"
    done
}
EOF
    sed -n "${_ge_from},${_ge_to}p" "$GE_SCRIPT"
} > "$_ge_section"

msg "Running GE's wine section (log: ${_ge_log##*/})…"
set +e
( cd "$WORK_DIR" && MYTHIX_GE_FAIL_LIST="$_ge_fail_list" bash "$_ge_section" ) > "$_ge_log" 2>&1
_ge_rc=$?
set -e
msg2 "GE section exit status: ${_ge_rc}"

_problems=0
if [ "$_ge_rc" -ne 0 ]; then
    warn "GE's wine section exited with status ${_ge_rc} (last step: autoreconf/make_requests)"
    tail -5 "$_ge_log" | sed 's/^/       /' >&2
    _problems=1
fi
if [ -s "$_ge_fail_list" ]; then
    warn "$(wc -l < "$_ge_fail_list") GE patch(es) failed to apply:"
    sed 's/^/       /' "$_ge_fail_list" >&2
    _problems=1
fi
# wine-staging's patchinstall stops at the first failing patchset.
if grep -qE '^(ERROR|error): |Failed to apply patch' "$_ge_log"; then
    warn "wine-staging reported errors:"
    grep -E '^(ERROR|error): |Failed to apply patch' "$_ge_log" | head -10 | sed 's/^/       /' >&2
    _problems=1
fi
_rejects="$(cd "$WINE_DIR" && find . -name '*.rej' -not -path './.git/*' | head -20)"
if [ -n "$_rejects" ]; then
    warn "reject files left behind:"
    printf '%s\n' "$_rejects" | sed 's/^/       /' >&2
    _problems=1
fi
if [ -n "$(_git -C "$WINE_DIR" diff --name-only --diff-filter=U)" ]; then
    warn "unmerged paths after GE's git revert step"
    _problems=1
fi
if [ "$_problems" -ne 0 ]; then
    if [ "$ALLOW_PATCH_FAILURES" = "true" ]; then
        warn "continuing anyway (--allow-patch-failures)"
    else
        printf "${C_RED}ERR!${C_R} GE layer did not apply cleanly — see %s\n" "$_ge_log" >&2
        exit 2
    fi
fi

find "$WINE_DIR" -name '*.orig' -not -path '*/.git/*' -delete 2>/dev/null || true
_git -C "$WINE_DIR" add -A
_git -C "$WINE_DIR" commit -q --allow-empty --no-verify \
    -m "mythix: GE layer (GE ${PIN_GE_COMMIT:0:12}, staging ${PIN_STAGING_COMMIT:0:12})"
ok "GE layer applied — $(_git -C "$WINE_DIR" diff --shortstat HEAD~1 HEAD | sed 's/^ *//')"

# ══════════════════════════════════════════════════════════════════════════════
#  4. Profile patches (curated TkG layer etc.) — strict, must apply cleanly
# ══════════════════════════════════════════════════════════════════════════════
sep "Profile patches"
_applied=0
if [ -d "${PROFILE_DIR}/patches" ]; then
    for p in "${PROFILE_DIR}"/patches/*.patch; do
        [ -e "$p" ] || continue
        _name="$(basename "$p")"
        if ! _git -C "$WINE_DIR" apply --check --whitespace=nowarn "$p" 2>"${LOG_DIR}/mythix-profile-patch.err"; then
            printf "  ${C_RED}✗${C_R}  %s\n" "$_name"
            sed 's/^/       /' "${LOG_DIR}/mythix-profile-patch.err" >&2
            printf "${C_RED}ERR!${C_R} %s does not apply on top of the GE layer.\n" "$_name" >&2
            printf "     The profile's pins and its patches must move together —\n" >&2
            printf "     re-curate the patch for the new pins (see profiles/README.md).\n" >&2
            exit 2
        fi
        _git -C "$WINE_DIR" apply --index --whitespace=nowarn "$p"
        _git -C "$WINE_DIR" commit -q --no-verify -m "mythix: ${_name%.patch}"
        printf "  ${C_GRN}✓${C_R}  %s\n" "$_name"
        _applied=$(( _applied + 1 ))
    done
fi
if [ "$_applied" -gt 0 ]; then ok "${_applied} profile patch(es) applied"; else msg2 "no profile patches"; fi

# ══════════════════════════════════════════════════════════════════════════════
#  5. Version branding — wine --version → "wine-<label>-mythix.<base> ( Mythix Wine )"
# ══════════════════════════════════════════════════════════════════════════════
sep "Version branding"
MYTHIX_WINE_VERSION="wine-${PROFILE_VERSION_LABEL:-0.0}-mythix.${PIN_WINE_COMMIT:0:10}"
python3 - "${WINE_DIR}/configure.ac" "$MYTHIX_WINE_VERSION" <<'PYEOF'
import re, sys
path, version = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()
lines = src.split("\n")
hit = False
for i, line in enumerate(lines):
    if "const char wine_build[[]]" not in line:
        continue
    new = re.sub(r'\(GIT_DIR=\$\{wine_srcdir\}\.git git describe HEAD 2>/dev/null \|\| echo \\"wine-\\\$\(PACKAGE_VERSION\)\\"\)',
                 lambda m: '(echo \\"' + version + '\\")', line)
    new = re.sub(r'= \\"\\\\1.*?\\";', lambda m: '= \\"\\\\1  ( Mythix Wine )\\";', new)
    if new == line:
        sys.exit("version rule found but not in the expected form: " + line[:120])
    lines[i] = new
    hit = True
if not hit:
    sys.exit("wine_build version rule not found in configure.ac")
open(path, "w", encoding="utf-8").write("\n".join(lines))
PYEOF
_git -C "$WINE_DIR" commit -q -a --no-verify -m "mythix: version ${MYTHIX_WINE_VERSION}"
ok "wine --version will report: ${MYTHIX_WINE_VERSION}  ( Mythix Wine )"

# ══════════════════════════════════════════════════════════════════════════════
#  6. Source lock — exactly what went into this tree
# ══════════════════════════════════════════════════════════════════════════════
_lock="${LOG_DIR}/mythix-source.lock"
{
    printf '# Mythix source lock — generated %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'profile=%s\n'          "$PROFILE_NAME"
    printf 'pipeline=ge\n'
    printf 'ge_repo=%s\n'          "$PIN_GE_REPO"
    printf 'ge_commit=%s\n'        "$PIN_GE_COMMIT"
    printf 'wine_repo=%s\n'        "$PIN_WINE_REPO"
    printf 'wine_commit=%s\n'      "$PIN_WINE_COMMIT"
    printf 'staging_repo=%s\n'     "$PIN_STAGING_REPO"
    printf 'staging_commit=%s\n'   "$PIN_STAGING_COMMIT"
    printf 'ge_script_sha256=%s\n' "$(sha256sum "$GE_SCRIPT" | cut -d' ' -f1)"
    if [ -n "$PIN_FFMPEG_COMMIT" ]; then
        printf 'ffmpeg_repo=%s\n'   "$PIN_FFMPEG_REPO"
        printf 'ffmpeg_commit=%s\n' "$PIN_FFMPEG_COMMIT"
    fi
    for p in "${PROFILE_DIR}"/patches/*.patch; do
        [ -e "$p" ] || continue
        printf 'patch=%s sha256=%s\n' "$(basename "$p")" "$(sha256sum "$p" | cut -d' ' -f1)"
    done
    printf 'wine_version=%s\n'     "$MYTHIX_WINE_VERSION"
    printf 'tree_head=%s\n'        "$(_git -C "$WINE_DIR" rev-parse HEAD)"
    # content hash of the prepared tree — identical sources give identical values
    printf 'tree_hash=%s\n'        "$(_git -C "$WINE_DIR" rev-parse 'HEAD^{tree}')"
} > "$_lock"

section "Mythix Wine source tree ready"
msg2 "Tree : ${WINE_DIR}"
msg2 "Lock : ${_lock}"
_git -C "$WINE_DIR" log --format='     %h %s' "${PIN_WINE_COMMIT}..HEAD"
ok "${PROFILE_NAME}: source prepared"
