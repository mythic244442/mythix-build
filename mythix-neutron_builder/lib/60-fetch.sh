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

