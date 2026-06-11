#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║         mythix-neutron_builder  •  Patch system                           ║
# ║   Discovers, selects, and applies patch groups to the Wine source tree   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage:  neutron-patcher.sh <wine_source_dir> <patches_dir> [patch_groups...]
#
#   wine_source_dir  — path to the Wine source tree to patch
#   patches_dir      — path to the patches/ directory containing patch groups
#   patch_groups     — optional space-separated list of group names to apply
#                      If omitted and interactive, shows an fzf multi-picker.
#                      Special value "all" applies every available group.
#                      Special value "none" skips patching entirely.
#
# Patch directory layout:
#   patches/
#   ├── <group>/
#   │   ├── series          ← optional: ordered list of patches (one per line)
#   │   ├── group.conf      ← optional: metadata (description, priority, compat)
#   │   ├── 0001-*.patch    ← standard git-format patches
#   │   ├── 0002-*.patch
#   │   └── ...
#   └── <group>/
#       └── ...
#
# group.conf format (all fields optional):
#   description="One-line description of what this patch group does"
#   priority=50            # 0-99, lower = applied first (default: 50)
#   min_wine_version=9.0   # skip if Wine is older
#   max_wine_version=      # skip if Wine is newer
#   sources=mainline,staging,proton-wine   # only apply to these source keys (empty = all)
#   conflicts=other-group  # groups that conflict with this one
#   requires=other-group   # groups that must be applied before this one
#
set -euo pipefail

# ── Output helpers ────────────────────────────────────────────────────────────
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
    _R="\033[0m" _B="\033[1m" _GRN="\033[1;32m" _BLU="\033[1;34m"
    _YLW="\033[1;33m" _RED="\033[1;31m" _DIM="\033[2m" _CYN="\033[1;36m"
else
    _R="" _B="" _GRN="" _BLU="" _YLW="" _RED="" _DIM="" _CYN=""
fi
msg()  { printf "${_GRN}==> ${_R}${_B}%s${_R}\n" "$*"; }
msg2() { printf "${_BLU} -> ${_R}%s\n" "$*"; }
ok()   { printf "${_GRN} ✓  ${_R}%s\n" "$*"; }
warn() { printf "${_YLW}warn${_R} %s\n" "$*" >&2; }
err()  { printf "${_RED}ERR!${_R} %s\n" "$*" >&2; exit 1; }
sep()  { printf "\n${_BLU}${_B}── %s ──${_R}\n" "$*"; }

# ── Args ──────────────────────────────────────────────────────────────────────
WINE_SRC="${1:?Usage: neutron-patcher.sh <wine_source_dir> <patches_dir> [groups...]}"
PATCHES_DIR="${2:?Usage: neutron-patcher.sh <wine_source_dir> <patches_dir> [groups...]}"
shift 2
REQUESTED_GROUPS=("$@")

[ -d "$WINE_SRC" ]    || err "Wine source directory not found: $WINE_SRC"
[ -d "$PATCHES_DIR" ] || err "Patches directory not found: $PATCHES_DIR"

# Env vars from neutron-builder.sh
WINE_SOURCE_KEY="${WINE_SOURCE_KEY:-}"
PATCH_LOG="${PATCH_LOG:-/dev/null}"
DRY_RUN="${DRY_RUN:-0}"

# ── Discover available patch groups ───────────────────────────────────────────
# A group is any subdirectory of PATCHES_DIR that contains at least one .patch file
declare -A GROUP_DESC
declare -A GROUP_PRIO
declare -A GROUP_SOURCES
declare -A GROUP_CONFLICTS
declare -A GROUP_REQUIRES
AVAILABLE_GROUPS=()

_discover_groups() {
    local gdir gname conf_file
    for gdir in "${PATCHES_DIR}"/*/; do
        [ -d "$gdir" ] || continue
        gname="$(basename "$gdir")"

        # Must have at least one .patch file (or a series file pointing to patches)
        local has_patches=false
        if ls "$gdir"/*.patch >/dev/null 2>&1; then
            has_patches=true
        elif [ -f "${gdir}/series" ]; then
            has_patches=true
        fi
        [ "$has_patches" = "true" ] || continue

        # Read group.conf if present
        local desc="$gname" prio=50 sources="" conflicts="" requires=""
        conf_file="${gdir}/group.conf"
        if [ -f "$conf_file" ]; then
            # Source it in a subshell to avoid polluting our namespace
            eval "$(grep -E '^(description|priority|sources|conflicts|requires)=' "$conf_file" 2>/dev/null)" || true
            desc="${description:-$gname}"
            prio="${priority:-50}"
            sources="${sources:-}"
            conflicts="${conflicts:-}"
            requires="${requires:-}"
        fi

        # Filter by source key if specified
        if [ -n "$sources" ] && [ -n "$WINE_SOURCE_KEY" ]; then
            local _match=false
            IFS=',' read -ra _src_list <<< "$sources"
            for _s in "${_src_list[@]}"; do
                [ "${_s// /}" = "$WINE_SOURCE_KEY" ] && { _match=true; break; }
            done
            if [ "$_match" = "false" ]; then
                msg2 "Skipping ${gname} (not compatible with source: ${WINE_SOURCE_KEY})"
                continue
            fi
        fi

        AVAILABLE_GROUPS+=("$gname")
        GROUP_DESC[$gname]="$desc"
        GROUP_PRIO[$gname]="$prio"
        GROUP_SOURCES[$gname]="$sources"
        GROUP_CONFLICTS[$gname]="$conflicts"
        GROUP_REQUIRES[$gname]="$requires"
    done

    # Sort by priority (lower first)
    if [ ${#AVAILABLE_GROUPS[@]} -gt 1 ]; then
        local sorted
        sorted=$(for g in "${AVAILABLE_GROUPS[@]}"; do
            printf '%03d\t%s\n' "${GROUP_PRIO[$g]}" "$g"
        done | sort -n | cut -f2)
        AVAILABLE_GROUPS=()
        while IFS= read -r g; do
            [ -n "$g" ] && AVAILABLE_GROUPS+=("$g")
        done <<< "$sorted"
    fi
}

_discover_groups

if [ ${#AVAILABLE_GROUPS[@]} -eq 0 ]; then
    msg "No patch groups found in ${PATCHES_DIR}"
    msg2 "Add patch directories with .patch files to enable patching"
    exit 0
fi

msg "Found ${#AVAILABLE_GROUPS[@]} patch group(s):"
for g in "${AVAILABLE_GROUPS[@]}"; do
    printf "  ${_CYN}%-25s${_R} %s ${_DIM}(priority: %s)${_R}\n" \
        "$g" "${GROUP_DESC[$g]}" "${GROUP_PRIO[$g]}"
done

# ── Select patch groups ──────────────────────────────────────────────────────
SELECTED_GROUPS=()

if [ ${#REQUESTED_GROUPS[@]} -gt 0 ]; then
    # Groups specified on command line
    if [ "${REQUESTED_GROUPS[0]}" = "none" ]; then
        msg2 "Patching skipped (--patches none)"
        exit 0
    elif [ "${REQUESTED_GROUPS[0]}" = "all" ]; then
        SELECTED_GROUPS=("${AVAILABLE_GROUPS[@]}")
        msg2 "Applying all ${#SELECTED_GROUPS[@]} patch groups"
    else
        for rg in "${REQUESTED_GROUPS[@]}"; do
            local_found=false
            for ag in "${AVAILABLE_GROUPS[@]}"; do
                if [ "$rg" = "$ag" ]; then
                    SELECTED_GROUPS+=("$rg")
                    local_found=true
                    break
                fi
            done
            if [ "$local_found" = "false" ]; then
                warn "Unknown patch group: ${rg} — skipping"
            fi
        done
    fi
elif [ -t 0 ]; then
    # Interactive selection via fzf or numbered menu
    if command -v fzf >/dev/null 2>&1; then
        _fzf_input=$'[ALL]\tApply all available patch groups\n'
        for g in "${AVAILABLE_GROUPS[@]}"; do
            _fzf_input+="${g}"$'\t'"${GROUP_DESC[$g]}  (priority: ${GROUP_PRIO[$g]})"$'\n'
        done

        _picked="$(printf '%s' "$_fzf_input" \
            | fzf --multi \
                  --prompt="Patches > " \
                  --header="Select patch groups (Tab to toggle, Enter to confirm, Esc for none)" \
                  --with-nth=2 \
                  --delimiter=$'\t' \
                  --height=40% \
                  --border \
                  --preview="ls ${PATCHES_DIR}/{1}/*.patch 2>/dev/null | head -20 | xargs -I{} basename {}" \
                  --preview-label='Patches in group' \
            | cut -f1)" || true

        if [ -n "$_picked" ]; then
            # Check if [ALL] was selected
            if printf '%s\n' "$_picked" | grep -qF '[ALL]'; then
                SELECTED_GROUPS=("${AVAILABLE_GROUPS[@]}")
            else
                while IFS= read -r g; do
                    [ -n "$g" ] && SELECTED_GROUPS+=("$g")
                done <<< "$_picked"
            fi
        fi
    else
        # Numbered fallback
        printf "\n  ${_B}Select patch groups to apply:${_R}\n"
        printf "    0) [none]  — skip patching\n"
        printf "    a) [all]   — apply everything\n"
        local _idx=1
        for g in "${AVAILABLE_GROUPS[@]}"; do
            printf "    %d) %-25s %s\n" "$_idx" "$g" "${GROUP_DESC[$g]}"
            (( _idx++ )) || true
        done
        printf "\n"
        read -rp "  Enter numbers separated by spaces [0]: " _choices
        _choices="${_choices:-0}"

        if [ "$_choices" = "0" ]; then
            : # none selected
        elif [ "$_choices" = "a" ] || [ "$_choices" = "A" ]; then
            SELECTED_GROUPS=("${AVAILABLE_GROUPS[@]}")
        else
            for _c in $_choices; do
                if [[ "$_c" =~ ^[0-9]+$ ]] && [ "$_c" -ge 1 ] && [ "$_c" -le ${#AVAILABLE_GROUPS[@]} ]; then
                    SELECTED_GROUPS+=("${AVAILABLE_GROUPS[$((_c - 1))]}")
                fi
            done
        fi
    fi
else
    # Non-interactive, no groups specified — apply all by default
    SELECTED_GROUPS=("${AVAILABLE_GROUPS[@]}")
    msg2 "Non-interactive mode — applying all ${#SELECTED_GROUPS[@]} patch groups"
fi

if [ ${#SELECTED_GROUPS[@]} -eq 0 ]; then
    msg "No patch groups selected — skipping"
    exit 0
fi

# ── Validate dependencies and conflicts ───────────────────────────────────────
_validate_selection() {
    local g req conf
    for g in "${SELECTED_GROUPS[@]}"; do
        # Check requires
        if [ -n "${GROUP_REQUIRES[$g]:-}" ]; then
            IFS=',' read -ra _reqs <<< "${GROUP_REQUIRES[$g]}"
            for req in "${_reqs[@]}"; do
                req="${req// /}"
                local _found=false
                for sg in "${SELECTED_GROUPS[@]}"; do
                    [ "$sg" = "$req" ] && { _found=true; break; }
                done
                if [ "$_found" = "false" ]; then
                    warn "Patch group '${g}' requires '${req}' which is not selected"
                    warn "Auto-adding '${req}' to selection"
                    SELECTED_GROUPS+=("$req")
                fi
            done
        fi
        # Check conflicts
        if [ -n "${GROUP_CONFLICTS[$g]:-}" ]; then
            IFS=',' read -ra _confs <<< "${GROUP_CONFLICTS[$g]}"
            for conf in "${_confs[@]}"; do
                conf="${conf// /}"
                for sg in "${SELECTED_GROUPS[@]}"; do
                    if [ "$sg" = "$conf" ]; then
                        warn "Patch group '${g}' conflicts with '${conf}'"
                        warn "Remove one of them to proceed"
                        err "Conflicting patch groups — aborting"
                    fi
                done
            done
        fi
    done
}
_validate_selection

# ── Re-sort selected by priority ──────────────────────────────────────────────
if [ ${#SELECTED_GROUPS[@]} -gt 1 ]; then
    _sorted_sel=$(for g in "${SELECTED_GROUPS[@]}"; do
        printf '%03d\t%s\n' "${GROUP_PRIO[$g]}" "$g"
    done | sort -n | cut -f2)
    SELECTED_GROUPS=()
    while IFS= read -r g; do
        [ -n "$g" ] && SELECTED_GROUPS+=("$g")
    done <<< "$_sorted_sel"
fi

sep "Applying ${#SELECTED_GROUPS[@]} patch group(s)"
for g in "${SELECTED_GROUPS[@]}"; do
    msg2 "  ${g} — ${GROUP_DESC[$g]}"
done

# ── Create a git checkpoint for easy revert ───────────────────────────────────
_git_available=false
if [ -d "${WINE_SRC}/.git" ]; then
    _git_available=true
    # Stash any uncommitted changes, then create a checkpoint tag
    _checkpoint="neutron-pre-patch-$(date +%s)"
    (cd "$WINE_SRC" && git stash --include-untracked -q 2>/dev/null || true)
    (cd "$WINE_SRC" && git tag -f "$_checkpoint" HEAD 2>/dev/null || true)
    msg2 "Git checkpoint: ${_checkpoint}"
fi

# ── Apply patches ─────────────────────────────────────────────────────────────
_total_applied=0
_total_failed=0
_total_skipped=0

_apply_group() {
    local group="$1"
    local gdir="${PATCHES_DIR}/${group}"
    local patches=()

    sep "Patch group: ${group}"
    msg2 "${GROUP_DESC[$group]}"

    # Build ordered patch list: use series file if present, otherwise sort *.patch
    if [ -f "${gdir}/series" ]; then
        while IFS= read -r line; do
            # Skip comments and blank lines
            line="${line%%#*}"
            line="${line// /}"
            [ -z "$line" ] && continue
            if [ -f "${gdir}/${line}" ]; then
                patches+=("${gdir}/${line}")
            else
                warn "Series entry not found: ${line}"
            fi
        done < "${gdir}/series"
    else
        # Glob sorted — 0001-*.patch ordering
        while IFS= read -r pf; do
            patches+=("$pf")
        done < <(find "$gdir" -maxdepth 1 -name '*.patch' -type f | sort)
    fi

    if [ ${#patches[@]} -eq 0 ]; then
        warn "No patches found in group: ${group}"
        return
    fi

    local applied=0 failed=0 skipped=0

    for pf in "${patches[@]}"; do
        local pname
        pname="$(basename "$pf")"

        if [ "$DRY_RUN" = "1" ]; then
            msg2 "[dry-run] Would apply: ${pname}"
            (( skipped++ )) || true
            continue
        fi

        # Try git apply first (handles renames, binary diffs)
        # Fall back to patch(1) for compatibility
        local apply_ok=false
        if [ "$_git_available" = "true" ]; then
            if (cd "$WINE_SRC" && git apply --check "$pf" 2>/dev/null); then
                if (cd "$WINE_SRC" && git apply "$pf" 2>>"$PATCH_LOG"); then
                    apply_ok=true
                fi
            elif (cd "$WINE_SRC" && git apply --check --3way "$pf" 2>/dev/null); then
                if (cd "$WINE_SRC" && git apply --3way "$pf" 2>>"$PATCH_LOG"); then
                    apply_ok=true
                fi
            fi
        fi

        if [ "$apply_ok" = "false" ]; then
            # Fallback to patch -p1
            if (cd "$WINE_SRC" && patch -p1 --dry-run < "$pf" >/dev/null 2>&1); then
                if (cd "$WINE_SRC" && patch -p1 < "$pf" >> "$PATCH_LOG" 2>&1); then
                    apply_ok=true
                fi
            fi
        fi

        if [ "$apply_ok" = "true" ]; then
            printf "  ${_GRN}✓${_R}  %s\n" "$pname"
            (( applied++ )) || true
        else
            # Check if already applied (reverse applies cleanly)
            local already_applied=false
            if (cd "$WINE_SRC" && patch -Rp1 --dry-run < "$pf" >/dev/null 2>&1); then
                already_applied=true
            fi
            if [ "$already_applied" = "true" ]; then
                printf "  ${_DIM}≡${_R}  %s ${_DIM}(already applied)${_R}\n" "$pname"
                (( skipped++ )) || true
            else
                printf "  ${_RED}✗${_R}  %s ${_RED}(FAILED)${_R}\n" "$pname"
                warn "Failed to apply: ${pf}"
                warn "Check ${PATCH_LOG} for details"
                (( failed++ )) || true
            fi
        fi
    done

    ok "${group}: ${applied} applied, ${skipped} skipped, ${failed} failed"
    (( _total_applied += applied )) || true
    (( _total_failed  += failed  )) || true
    (( _total_skipped += skipped )) || true
}

for group in "${SELECTED_GROUPS[@]}"; do
    _apply_group "$group"
done

# ── Summary ───────────────────────────────────────────────────────────────────
sep "Patch summary"
ok "Total: ${_total_applied} applied, ${_total_skipped} skipped, ${_total_failed} failed"
if [ "$_total_failed" -gt 0 ]; then
    warn "Some patches failed to apply — the build may not succeed."
    if [ "$_git_available" = "true" ]; then
        msg2 "To revert all patches: cd ${WINE_SRC} && git checkout ${_checkpoint}"
    fi
fi

# Commit the patched state if git is available
if [ "$_git_available" = "true" ] && [ "$_total_applied" -gt 0 ] && [ "$DRY_RUN" != "1" ]; then
    (cd "$WINE_SRC" && git add -A && \
     git commit -q -m "neutron: apply ${#SELECTED_GROUPS[@]} patch group(s): ${SELECTED_GROUPS[*]}" \
     2>/dev/null) || true
    msg2 "Patched state committed to git"
fi

exit 0
