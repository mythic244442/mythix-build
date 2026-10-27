# ── GE-Proton patch application ──────────────────────────────────────────────
# When source is ge-proton, clone the GE repo and run protonprep.sh to apply
# all of GloriousEggroll's gaming patches on top of proton-wine.
if [ "$WINE_SOURCE_KEY" = "ge-proton" ]; then
    section "GE-Proton patches (GloriousEggroll)"

    GE_CACHE_DIR="${SRC_ROOT}/proton-ge-custom"
    _ge_branch_flag=()
    [ -n "${GE_RELEASE_TAG:-}" ] && _ge_branch_flag=( "--branch" "$GE_RELEASE_TAG" )

    if [ ! -d "${GE_CACHE_DIR}/.git" ]; then
        msg "Cloning proton-ge-custom…"
        [ -n "${GE_RELEASE_TAG:-}" ] && msg2 "Release: ${GE_RELEASE_TAG}"
        run git clone --depth=1 \
            "${_ge_branch_flag[@]+"${_ge_branch_flag[@]}"}" \
            "$GE_PROTON_REPO" "$GE_CACHE_DIR"
    else
        msg "Updating proton-ge-custom…"
        if [ -n "${GE_RELEASE_TAG:-}" ]; then
            run git -C "$GE_CACHE_DIR" fetch --depth=1 origin "refs/tags/${GE_RELEASE_TAG}:refs/tags/${GE_RELEASE_TAG}" 2>/dev/null || \
                run git -C "$GE_CACHE_DIR" fetch origin
            run git -C "$GE_CACHE_DIR" checkout "$GE_RELEASE_TAG"
        else
            run git -C "$GE_CACHE_DIR" pull --ff-only 2>/dev/null || true
        fi
    fi

    ok "GE source ready: ${GE_CACHE_DIR}"

    # ── Match GE's own wine + wine-staging pins ─────────────────────────
    # A GE release builds Valve wine and wine-staging at the commits its
    # submodules pin (GE-Proton10/11: Valve bleeding-edge + a staging
    # release, hence "wine-11.0 (Staging)"), not at a proton_X.0 branch tip
    # or staging master. GE's patches are rebased onto exactly those trees.
    _ge_wine_pin="$(git -C "$GE_CACHE_DIR" ls-tree HEAD wine 2>/dev/null | awk '{print $3}')"
    _ge_staging_pin="$(git -C "$GE_CACHE_DIR" ls-tree HEAD wine-staging 2>/dev/null | awk '{print $3}')"
    if [ -n "$_ge_wine_pin" ]; then
        if ! git -C "$WINE_SOURCE_DIR" cat-file -e "${_ge_wine_pin}^{commit}" 2>/dev/null; then
            msg2 "Fetching GE's wine pin ${_ge_wine_pin:0:12}…"
            run git -C "$WINE_SOURCE_DIR" fetch -q origin "$_ge_wine_pin" || \
                err "Could not fetch GE's wine pin ${_ge_wine_pin} from Valve wine"
        fi
        run git -C "$WINE_SOURCE_DIR" -c advice.detachedHead=false checkout -q -f "$_ge_wine_pin"
        ok "Wine at GE's pin ${_ge_wine_pin:0:12} ($(git -C "$WINE_SOURCE_DIR" describe --tags --always 2>/dev/null))"
    else
        warn "GE checkout pins no wine submodule — staying on ${_wine_branch:-the fetched branch}"
    fi

    # ── Apply GE patches via protonprep.sh ──────────────────────────────
    # protonprep.sh expects to be run from the GE repo root with the wine
    # source tree as a subdirectory or sibling.  We adapt to work with our
    # layout: symlink our wine source as "wine" in the GE tree, then run
    # protonprep.sh from within it.
    _ge_patches_dir="${GE_CACHE_DIR}/patches"

    # Find the protonprep script — GE names it differently across releases
    _ge_prep=""
    for _candidate in \
        "${_ge_patches_dir}/protonprep-valve-staging.sh" \
        "${_ge_patches_dir}/protonprep.sh" \
        "${_ge_patches_dir}/protonprep-nofshack.sh"; do
        [ -f "$_candidate" ] && { _ge_prep="$_candidate"; break; }
    done

    if [ -n "$_ge_prep" ]; then
        msg "Applying GE patches via $(basename "$_ge_prep")…"
        msg2 "This applies GE's full gaming patch set on top of proton-wine"

        # protonprep does 'pushd wine' — create a symlink so it finds our tree
        _ge_wine_link="${GE_CACHE_DIR}/wine"
        rm -rf "$_ge_wine_link"
        ln -sf "$WINE_SOURCE_DIR" "$_ge_wine_link"

        # Clone wine-staging — protonprep applies staging patches with exclusions
        _ge_staging_link="${GE_CACHE_DIR}/wine-staging"
        rm -rf "$_ge_staging_link"
        _ge_staging_dir="${SRC_ROOT}/wine-staging-ge"
        if [ ! -d "${_ge_staging_dir}/.git" ]; then
            msg2 "Cloning wine-staging for GE patch application…"
            run git clone --depth=1 \
                "https://github.com/wine-staging/wine-staging.git" \
                "$_ge_staging_dir"
        fi
        if [ -n "$_ge_staging_pin" ]; then
            if ! git -C "$_ge_staging_dir" cat-file -e "${_ge_staging_pin}^{commit}" 2>/dev/null; then
                run git -C "$_ge_staging_dir" fetch -q --depth=1 origin "$_ge_staging_pin" || \
                    err "Could not fetch GE's wine-staging pin ${_ge_staging_pin}"
            fi
            run git -C "$_ge_staging_dir" -c advice.detachedHead=false checkout -q -f "$_ge_staging_pin"
            ok "wine-staging at GE's pin ${_ge_staging_pin:0:12}"
        else
            warn "GE checkout pins no wine-staging submodule — using the wine-staging checkout as is"
        fi
        ln -sf "$_ge_staging_dir" "$_ge_staging_link"

        # Create dummy dirs for components we don't use (protonprep resets them)
        for _dummy in dxvk vkd3d-proton dxvk-nvapi; do
            _dummy_dir="${GE_CACHE_DIR}/${_dummy}"
            if [ ! -d "$_dummy_dir" ]; then
                mkdir -p "$_dummy_dir"
                ( cd "$_dummy_dir" && git init -q && git commit --allow-empty -m "dummy" -q ) 2>/dev/null || true
            fi
        done

        _ge_patch_log="${BUILD_RUN_DIR}/ge-protonprep.log"
        msg2 "Script: $(basename "$_ge_prep")"
        msg2 "Log: ${_ge_patch_log}"

        if [ "${DRY_RUN:-0}" -eq 1 ]; then
            dim "  [dry-run] Would run $(basename "$_ge_prep")"
        else
            set +e
            ( cd "$GE_CACHE_DIR" && bash "$_ge_prep" ) \
                > "$_ge_patch_log" 2>&1
            _ge_exit=$?
            set -e

            if [ "$_ge_exit" -eq 0 ]; then
                ok "GE-Proton patches applied successfully"
            else
                warn "$(basename "$_ge_prep") exited with code ${_ge_exit}"
                warn "Some GE patches may have failed — check: ${_ge_patch_log}"
                msg2 "Continuing build (partial patches are usually fine)…"
            fi

            # Show summary of what was applied
            if [ -f "$_ge_patch_log" ]; then
                _ge_applied=$(grep -c 'patching file\|WINE:' "$_ge_patch_log" 2>/dev/null || echo 0)
                _ge_fails=$(grep -ciE 'FAILED|error|can.t find file' "$_ge_patch_log" 2>/dev/null || echo 0)
                msg2 "Patch log: ~${_ge_applied} operations, ${_ge_fails} potential issues"
            fi
        fi

        # ── Post-patch fixups for known GE/proton-wine incompatibilities ──
        # GE's ntsync patch adds close_inproc_sync_obj() call but the function
        # doesn't exist in all proton-wine branches. Replace with NtClose().
        _thread_c="${WINE_SOURCE_DIR}/dlls/ntdll/unix/thread.c"
        if [ -f "$_thread_c" ] && grep -q 'close_inproc_sync_obj' "$_thread_c"; then
            sed -i 's/close_inproc_sync_obj( wait_handle );/NtClose( wait_handle );/' "$_thread_c"
            ok "Post-patch fixup: close_inproc_sync_obj → NtClose"
        fi

        # Clean up symlinks (leave dummy dirs, they're harmless)
        rm -rf "$_ge_wine_link"
        rm -rf "$_ge_staging_link"
    elif [ -d "$_ge_patches_dir" ]; then
        # No protonprep.sh — try applying .patch files directly
        msg "No protonprep.sh found — applying GE .patch files directly"
        _ge_patch_count=0
        _ge_patch_fail=0
        for _pf in "${_ge_patches_dir}"/**/*.patch "${_ge_patches_dir}"/*.patch; do
            [ -f "$_pf" ] || continue
            _pname="$(basename "$_pf")"
            if (cd "$WINE_SOURCE_DIR" && git apply --check "$_pf" 2>/dev/null); then
                (cd "$WINE_SOURCE_DIR" && git apply "$_pf" 2>/dev/null) && \
                    { printf "  ${C_GRN}✓${C_R}  %s\n" "$_pname"; (( _ge_patch_count++ )) || true; } || \
                    { printf "  ${C_RED}✗${C_R}  %s\n" "$_pname"; (( _ge_patch_fail++ )) || true; }
            elif (cd "$WINE_SOURCE_DIR" && patch -p1 --dry-run < "$_pf" >/dev/null 2>&1); then
                (cd "$WINE_SOURCE_DIR" && patch -p1 < "$_pf" >/dev/null 2>&1) && \
                    { printf "  ${C_GRN}✓${C_R}  %s\n" "$_pname"; (( _ge_patch_count++ )) || true; } || \
                    { printf "  ${C_RED}✗${C_R}  %s\n" "$_pname"; (( _ge_patch_fail++ )) || true; }
            else
                printf "  ${C_YLW}⊘${C_R}  %s (skipped)\n" "$_pname"
            fi
        done
        ok "GE patches: ${_ge_patch_count} applied, ${_ge_patch_fail} failed"
    else
        warn "No patches directory found in proton-ge-custom"
        warn "GE patches could not be applied — building plain proton-wine"
    fi
fi

# ── Apply neutron patch groups ────────────────────────────────────────────────
if [ -f "$PATCHER" ] && [ -d "$PATCHES_DIR" ]; then
    section "Neutron patch system"
    export WINE_SOURCE_KEY PATCH_LOG="${BUILD_RUN_DIR}/neutron-patch.log" DRY_RUN
    mkdir -p "$BUILD_RUN_DIR"

    _patch_args=()
    if [ -n "$PATCH_GROUPS" ]; then
        # Convert comma-separated to space-separated args
        IFS=',' read -ra _pg_list <<< "$PATCH_GROUPS"
        _patch_args=("${_pg_list[@]}")
    fi

    # Profile builds are strict: a patch group the profile asks for must apply.
    if [ -n "$PROFILE_NAME" ] && [ "$ALLOW_PATCH_FAILURES" != "true" ]; then
        export NEUTRON_PATCH_STRICT=1
    fi
    # Record what was applied (appended to the source lock for profile builds)
    export NEUTRON_PATCH_MANIFEST="${BUILD_RUN_DIR}/neutron-patch.manifest"
    : > "$NEUTRON_PATCH_MANIFEST"
    bash "$PATCHER" "$WINE_SOURCE_DIR" "$PATCHES_DIR" "${_patch_args[@]+"${_patch_args[@]}"}" || {
        if [ "${NEUTRON_PATCH_STRICT:-0}" = "1" ]; then
            err "Patch group(s) failed for profile ${PROFILE_NAME} — check ${BUILD_RUN_DIR}/neutron-patch.log
     (--allow-patch-failures builds anyway)"
        fi
        warn "Some patches may have failed — check ${BUILD_RUN_DIR}/neutron-patch.log"
    }
elif [ -d "$PATCHES_DIR" ]; then
    warn "neutron-patcher.sh not found: $PATCHER"
    warn "Skipping patch application"
fi
if [ -n "$PROFILE_NAME" ] && [ -f "${BUILD_RUN_DIR}/mythix-source.lock" ] && \
   [ -s "${NEUTRON_PATCH_MANIFEST:-/nonexistent}" ]; then
    sed 's/^/patch_group_/' "$NEUTRON_PATCH_MANIFEST" >> "${BUILD_RUN_DIR}/mythix-source.lock"
fi

# ── Apply wine-staging patches (staging source only) ─────────────────────────
if [ "${WINE_SOURCE_NEEDS_STAGING[$WINE_SOURCE_KEY]:-false}" = "true" ]; then
    section "Applying wine-staging patches"

    # Locate the patcher script — check neutron's own copy first, then wine-builder's
    _PATCHER=""
    for _p in "${_LIB_DIR}/wine-tkg-patcher.sh" \
              "${SCRIPT_DIR}/wine-tkg-patcher.sh" \
              "${SCRIPT_DIR}/../mythix-wine_builder/wine-tkg-patcher.sh" \
              "${SCRIPT_DIR%/bin}/../mythix-wine_builder/wine-tkg-patcher.sh"; do
        [ -f "$_p" ] && { _PATCHER="$_p"; break; }
    done

    if [ -z "$_PATCHER" ]; then
        # Inline fallback: clone wine-staging and apply via patchinstall.py
        msg2 "wine-tkg-patcher.sh not found — applying staging patches inline"
        _STAGING_CACHE="${SRC_ROOT}/wine-staging-patches"
        _STAGING_URL="https://github.com/wine-staging/wine-staging.git"
        _staging_ref="${STAGING_BRANCH:-}"

        if [ -d "${_STAGING_CACHE}/.git" ]; then
            msg2 "Updating staging cache..."
            git -C "$_STAGING_CACHE" fetch --prune
            [ -n "$_staging_ref" ] && git -C "$_STAGING_CACHE" checkout "$_staging_ref" --
        else
            msg2 "Cloning wine-staging → $_STAGING_CACHE"
            mkdir -p "$(dirname "$_STAGING_CACHE")"
            if [ -n "$_staging_ref" ]; then
                git clone --depth=1 --branch "$_staging_ref" "$_STAGING_URL" "$_STAGING_CACHE"
            else
                git clone --depth=1 "$_STAGING_URL" "$_STAGING_CACHE"
            fi
        fi

        _PATCHINSTALL="${_STAGING_CACHE}/staging/patchinstall.py"
        if [ -f "$_PATCHINSTALL" ]; then
            msg2 "Applying full staging patchset via patchinstall.py..."
            _patch_log="${BUILD_RUN_DIR}/staging-patch.log"
            (
                cd "$_STAGING_CACHE"
                python3 staging/patchinstall.py \
                    --all \
                    DESTDIR="$WINE_SOURCE_DIR" \
                    >> "$_patch_log" 2>&1
            ) || {
                warn "Staging patch application had errors — see ${_patch_log}"
                tail -10 "$_patch_log" >&2
            }
            ok "wine-staging patches applied"
        else
            warn "patchinstall.py not found in staging cache — skipping patches"
        fi
    else
        # Use the shared patcher from wine-builder
        msg2 "Using patcher: $_PATCHER"
        [ -x "$_PATCHER" ] || chmod +x "$_PATCHER"
        export DRY_RUN NO_PULL
        export PATCH_LOG="${BUILD_RUN_DIR}/staging-patch.log"
        export STAGING_BRANCH_HINT="${_wine_branch:-}"
        mkdir -p "$BUILD_RUN_DIR"
        "$_PATCHER" "$WINE_SOURCE_DIR" "${SRC_ROOT}/wine-staging-patches"
    fi
fi

