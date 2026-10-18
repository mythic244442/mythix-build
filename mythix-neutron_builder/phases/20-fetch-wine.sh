# ── Fetch Wine source ────────────────────────────────────────────────────────
section "Fetching Wine source"

if [ "${PROFILE_PIPELINE:-}" = "patch" ]; then
    # ── Profile (patch pipeline): pinned Valve wine + GE protonprep + profile layers
    section "Mythix Wine — profile ${PROFILE_NAME} (patch pipeline)"
    _pipe_args=( --profile-dir "$PROFILE_DIR" --work-dir "$MYTHIX_PATCH_WORK_DIR"
               --log-dir "$BUILD_RUN_DIR" )
    [ "$ALLOW_PATCH_FAILURES" = "true" ] && _pipe_args+=( --allow-patch-failures )
    if [ "$DRY_RUN" -eq 1 ]; then
        dim "  [dry-run] bash $(basename "$PATCH_PIPELINE") ${_pipe_args[*]}"
    else
        set +e
        bash "$PATCH_PIPELINE" "${_pipe_args[@]}"
        _ge_rc=$?
        set -e
        case "$_ge_rc" in
            0) ok "Profile source ready: ${WINE_SOURCE_DIR}" ;;
            2) err "Profile ${PROFILE_NAME}: a patch layer failed to apply (exit 2).
     Logs: ${BUILD_RUN_DIR}/mythix-ge-wine-section.log
     Re-curate the profile patches (see profiles/README.md), or build anyway
     with --allow-patch-failures while you work on it." ;;
            *) err "Profile ${PROFILE_NAME}: source preparation failed (exit ${_ge_rc})." ;;
        esac
    fi
else
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
fi

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
# Profiles with PROFILE_PIPELINE=legacy inject their pins into this pipeline
# (PIN_* hooks below); the patch pipeline has already prepared its tree.
if [ "$WINE_SOURCE_KEY" = "mythix-wine" ] && [ "${PROFILE_PIPELINE:-legacy}" = "legacy" ]; then

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
            err "Unknown MYTHIX_WINE_BASE: ${MYTHIX_WINE_BASE} (use proton_10.0 or bleeding-edge)"
            ;;
    esac

    # ── Profile pins (legacy profiles: mythix-10.17, mythix-11.11, …) ────
    # Every upstream input of a profile build is pinned; failures to reach a
    # pin are fatal instead of silently building from whatever is checked out.
    if [ -n "$PROFILE_NAME" ] && [ -n "${PIN_TKG_COMMIT:-}" ]; then
        _tkg_pin_commit="$PIN_TKG_COMMIT"
        _tkg_pin_label="profile ${PROFILE_NAME}"
    fi

    section "Mythix Wine — ${_mythix_base_label} + TkG + Staging + GE"
    msg "Base: ${_mythix_base_label}"
    msg "TkG pin: ${_tkg_pin_label}"

    # Pin to a known-good commit on the selected branch (empty = use latest)
    BLEEDING_EDGE_PIN=""
    [ -n "$PROFILE_NAME" ] && BLEEDING_EDGE_PIN="${PIN_WINE_COMMIT:-}"

    BLEEDING_EDGE_REVERTS=()
    BLEEDING_EDGE_CHERRIES=()

    # Fetch the target branch if not already available
    (cd "$WINE_SOURCE_DIR" && git fetch origin "$_mythix_base_branch" 2>/dev/null) || true

    # A pinned commit may no longer be on any branch (Valve rewrites
    # bleeding-edge) — fetch it by hash.
    if [[ -n "$BLEEDING_EDGE_PIN" ]] && \
       ! git -C "$WINE_SOURCE_DIR" cat-file -e "${BLEEDING_EDGE_PIN}^{commit}" 2>/dev/null; then
        msg "Fetching pinned wine commit ${BLEEDING_EDGE_PIN:0:12} by hash…"
        git -C "$WINE_SOURCE_DIR" fetch -q "${PIN_WINE_REPO:-origin}" "$BLEEDING_EDGE_PIN" || \
            err "Could not fetch pinned wine commit ${BLEEDING_EDGE_PIN} from ${PIN_WINE_REPO:-origin}"
    fi

    # Hard reset to clean base before applying patches
    if [[ -n "$BLEEDING_EDGE_PIN" ]]; then
        msg "Resetting source tree to pinned commit: ${BLEEDING_EDGE_PIN:0:12}…"
        (cd "$WINE_SOURCE_DIR" && git reset --hard "$BLEEDING_EDGE_PIN") 2>/dev/null || true
    else
        msg "Resetting source tree to origin/${_mythix_base_branch}…"
        (cd "$WINE_SOURCE_DIR" && git reset --hard "origin/${_mythix_base_branch}") 2>/dev/null || true
    fi
    (cd "$WINE_SOURCE_DIR" && git clean -fdx -- '*.rej' '*.orig' 'autom4te.cache') 2>/dev/null || true
    if [ -n "$PROFILE_NAME" ]; then
        if [[ -n "$BLEEDING_EDGE_PIN" ]] && [ "$(git -C "$WINE_SOURCE_DIR" rev-parse HEAD)" != \
             "$(git -C "$WINE_SOURCE_DIR" rev-parse "${BLEEDING_EDGE_PIN}^{commit}" 2>/dev/null)" ]; then
            err "Wine tree is not at the profile pin ${BLEEDING_EDGE_PIN} after reset"
        fi
        # Pinned builds start from a pristine tree, independent of earlier runs
        git -C "$WINE_SOURCE_DIR" clean -fdxq
    fi
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
        if [ -n "$PROFILE_NAME" ] && \
           ! git -C "$_tkg_dir" cat-file -e "${_tkg_pin_commit}^{commit}" 2>/dev/null; then
            git -C "$_tkg_dir" fetch -q origin "$_tkg_pin_commit" || \
                err "Could not fetch pinned TkG commit ${_tkg_pin_commit}"
        fi
        (cd "$_tkg_dir" && git reset --hard "$_tkg_pin_commit") 2>/dev/null || true
        if [ -n "$PROFILE_NAME" ] && [ "$(git -C "$_tkg_dir" rev-parse HEAD)" != \
             "$(git -C "$_tkg_dir" rev-parse "${_tkg_pin_commit}^{commit}" 2>/dev/null)" ]; then
            err "TkG reference is not at the profile pin ${_tkg_pin_commit}"
        fi
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
    if [ -n "$PROFILE_NAME" ] && [ -n "${PIN_STAGING_REF:-}" ]; then
        if ! git -C "$_staging_dir" checkout -q -f "$PIN_STAGING_REF" 2>/dev/null; then
            git -C "$_staging_dir" fetch -q origin "$PIN_STAGING_REF" && \
                git -C "$_staging_dir" checkout -q -f FETCH_HEAD || \
                err "Could not check out pinned wine-staging ref ${PIN_STAGING_REF}"
        fi
        ok "Staging pinned to ${PIN_STAGING_REF} (profile ${PROFILE_NAME})"
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

    if [ -n "$PROFILE_NAME" ] && [ -n "${PIN_GE_COMMIT:-}" ]; then
        # Pinned GE lives in its own checkout so unpinned builds keep tracking master
        GE_CACHE_DIR="${SRC_ROOT}/proton-ge-custom-pinned"
        if [ ! -d "${GE_CACHE_DIR}/.git" ]; then
            git init -q "$GE_CACHE_DIR"
            git -C "$GE_CACHE_DIR" remote add origin "${PIN_GE_REPO:-$GE_PROTON_REPO}"
        fi
        if ! git -C "$GE_CACHE_DIR" cat-file -e "${PIN_GE_COMMIT}^{commit}" 2>/dev/null; then
            msg "Fetching pinned proton-ge-custom ${PIN_GE_COMMIT:0:12}…"
            git -C "$GE_CACHE_DIR" fetch -q --depth=1 origin "$PIN_GE_COMMIT" || \
                err "Could not fetch pinned GE commit ${PIN_GE_COMMIT}"
        fi
        git -C "$GE_CACHE_DIR" -c advice.detachedHead=false checkout -q -f "$PIN_GE_COMMIT"
        git -C "$GE_CACHE_DIR" clean -fdxq
        ok "GE pinned to ${PIN_GE_COMMIT:0:12} (profile ${PROFILE_NAME})"
    elif [ ! -d "${GE_CACHE_DIR}/.git" ]; then
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
            for _vkd3d_build in "${BUILD_RUN_DIR}/wine-unified/libs/vkd3d" "${BUILD_RUN_DIR}/${BUILD_NAME}/wine64/libs/vkd3d"; do
                [ -d "$_vkd3d_build" ] && { sudo rm -rf "$_vkd3d_build" 2>/dev/null || rm -rf "$_vkd3d_build"; }
            done
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

    # ── Source lock (profile builds) ──────────────────────────────────────
    if [ -n "$PROFILE_NAME" ]; then
        _lock="${BUILD_RUN_DIR}/mythix-source.lock"
        {
            printf '# Mythix source lock — written by neutron-builder.sh (legacy pipeline)\n'
            printf 'profile=%s\n' "$PROFILE_NAME"
            printf 'pipeline=legacy\n'
            printf 'wine_base=%s\n' "$MYTHIX_WINE_BASE"
            printf 'wine_repo=%s\n' "${PIN_WINE_REPO:-${WINE_SOURCE_URL[mythix-wine]}}"
            printf 'wine_commit=%s\n' "$(git -C "$WINE_SOURCE_DIR" rev-parse mythix-base-clean 2>/dev/null)"
            printf 'tkg_repo=%s\n' "$KRON4EK_TKG_REPO"
            printf 'tkg_commit=%s\n' "$(git -C "$_tkg_dir" rev-parse HEAD 2>/dev/null)"
            printf 'staging_commit=%s\n' "$(git -C "$_staging_dir" rev-parse HEAD 2>/dev/null)"
            printf 'ge_repo=%s\n' "${PIN_GE_REPO:-$GE_PROTON_REPO}"
            printf 'ge_commit=%s\n' "$(git -C "$GE_CACHE_DIR" rev-parse HEAD 2>/dev/null)"
            printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        } > "$_lock"
        ok "Source lock: ${_lock}"
    fi
    ok "Mythix Wine — the works"
fi

