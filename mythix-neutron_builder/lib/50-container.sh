# ══════════════════════════════════════════════════════════════════════════════
#  Container build support
#
#  pick_build_method  — interactively ask native vs container (if not set via CLI)
#  _detect_container_engine — find podman or docker
#  _run_container_build — build image if needed, re-exec inside the container
# ══════════════════════════════════════════════════════════════════════════════
_detect_container_engine() {
    if command -v podman >/dev/null 2>&1; then
        printf 'podman'
    elif command -v docker >/dev/null 2>&1; then
        printf 'docker'
    else
        printf ''
    fi
}

pick_build_method() {
    # Already set by --container / --native flag
    [ -n "$CONTAINER_BUILD" ] && return 0
    # No interactive terminal — default to native (we may already be inside the container)
    ( : >/dev/tty ) 2>/dev/null || { CONTAINER_BUILD=false; return 0; }

    local _engine
    _engine="$(_detect_container_engine)"

    section "Build method"

    local _native_desc="Native     — build directly on this machine (requires deps)"
    local _container_desc="Container  — build inside Podman/Docker (no local deps)"
    [ -n "$_engine" ] && _container_desc="${_container_desc}  [${_engine}]"
    [ -z "$_engine" ] && _container_desc="${_container_desc}  (not available — install podman/docker)"

    if command -v fzf >/dev/null 2>&1; then
        local picked
        picked=$(
            printf 'native\t%s\n' "$_native_desc"
            printf 'container\t%s\n' "$_container_desc"
        ) && picked=$(
            printf '%s\n' "$picked" \
            | fzf \
                --prompt="Build method > " \
                --header="Select build method" \
                --with-nth=2 \
                --delimiter=$'\t' \
                --height=10% \
                --border \
            || true
        )
        [ -n "$picked" ] || { CONTAINER_BUILD=false; ok "Build method: native (default)"; return 0; }
        local _key; _key="$(printf '%s' "$picked" | cut -d$'\t' -f1)"
    else
        printf "  ${C_B}1) ${_native_desc}${C_R}\n"
        printf "  ${C_B}2) ${_container_desc}${C_R}\n\n"
        printf "  ${C_CYN}Build method [1=native, 2=container]:${C_R} "
        local _pick; read -r _pick </dev/tty
        case "$_pick" in
            2) _key="container" ;;
            *) _key="native" ;;
        esac
    fi

    case "$_key" in
        container)
            if [ -z "$_engine" ]; then
                err "No container engine found. Install podman or docker first.
     Podman (recommended): sudo apt install podman
     Docker: https://docs.docker.com/engine/install/"
            fi
            CONTAINER_BUILD=true
            ok "Build method: container (${_engine})"
            ;;
        *)
            CONTAINER_BUILD=false
            ok "Build method: native"
            ;;
    esac
}

_run_container_build() {
    local engine
    engine="$(_detect_container_engine)"
    [ -n "$engine" ] || err "No container engine found (podman or docker required)."

    local image_name="mythix-neutron_builder"
    local containerfile="${_LIB_DIR}/Containerfile.neutron"

    # If running from the source tree, Containerfile is alongside us.
    # If installed, it's in the lib dir.
    if [ ! -f "$containerfile" ]; then
        containerfile="${SCRIPT_DIR}/Containerfile.neutron"
    fi
    [ -f "$containerfile" ] || \
        err "Containerfile not found: $containerfile
     Expected in the source tree or lib directory."

    # ntsync.h must be in the build context alongside the Containerfile
    local _build_context
    _build_context="$(dirname "$containerfile")"

    # ── Build or rebuild the container image ──────────────────────────────
    # The image bakes in UID/GID/username at build time.  If it was built on
    # a different machine (or by a different user), the baked-in UID won't
    # match the current user and podman/docker will fail with "no matching
    # entries in the password file".  Detect this and auto-rebuild.
    local _need_build=false
    if ! "$engine" image exists "$image_name" 2>/dev/null; then
        _need_build=true
        msg "Image not found — will build."
    else
        # Check whether the image's baked-in UID matches ours
        local _image_uid
        _image_uid=$("$engine" run --rm "$image_name" id -u 2>/dev/null || true)
        if [ "$_image_uid" != "$(id -u)" ]; then
            warn "Image was built for UID ${_image_uid:-?} but you are UID $(id -u)"
            msg "Rebuilding image for current user..."
            "$engine" rmi -f "$image_name" >/dev/null 2>&1 || true
            _need_build=true
        else
            ok "Container image found: ${image_name}  (UID matches)"
        fi
    fi

    # Rebuild when Containerfile.neutron changed since the image was built
    # (new build deps would otherwise never reach an existing image).
    local _cf_sum _img_sum
    _cf_sum="$(sha256sum "$containerfile" | cut -d' ' -f1)"
    if [ "$_need_build" = "false" ]; then
        _img_sum="$("$engine" image inspect \
            --format '{{ index .Config.Labels "mythix.containerfile.sha256" }}' \
            "$image_name" 2>/dev/null || true)"
        if [ "$_img_sum" != "$_cf_sum" ]; then
            warn "Containerfile.neutron changed since the image was built — rebuilding"
            "$engine" rmi -f "$image_name" >/dev/null 2>&1 || true
            _need_build=true
        fi
    fi

    if [ "$_need_build" = "true" ]; then
        section "Building container image"
        msg "Building ${image_name} (this takes a few minutes)..."
        msg2 "Containerfile: $containerfile"
        msg2 "BUILD_USER=$(whoami)  BUILD_UID=$(id -u)  BUILD_GID=$(id -g)"

        run "$engine" build \
            --build-arg "BUILD_USER=$(whoami)" \
            --build-arg "BUILD_UID=$(id -u)" \
            --build-arg "BUILD_GID=$(id -g)" \
            --label "mythix.containerfile.sha256=${_cf_sum}" \
            -t "$image_name" \
            -f "$containerfile" \
            "$_build_context"

        ok "Container image built: ${image_name}"
    fi

    # ── Volume flags ─────────────────────────────────────────────────────
    # :z is needed for SELinux relabelling (harmless on non-SELinux systems)
    local vol_flag=":z"

    # ── Build the command to run inside the container ────────────────────
    # Re-invoke neutron-builder.sh with --no-container (skip the method
    # picker inside the container) plus all the user's original arguments.
    local -a inner_args=( "--no-container" )

    [ -n "$WINE_SOURCE_KEY" ]        && inner_args+=( "--source" "$WINE_SOURCE_KEY" )
    [ -n "$WINE_SOURCE_BRANCH_ARG" ] && inner_args+=( "--branch" "$WINE_SOURCE_BRANCH_ARG" )
    [ -n "$BUILD_NAME" ]             && inner_args+=( "--name" "$BUILD_NAME" )
    [ "$MYTHIX_WINE_BASE" != "proton_10.0" ] && inner_args+=( "--wine-base" "$MYTHIX_WINE_BASE" )
    [ "$DXVK_SOURCE_KEY" != "dxvk-release" ] && inner_args+=( "--dxvk" "$DXVK_SOURCE_KEY" )
    [ "$VKD3D_SOURCE_KEY" != "vkd3d-proton-release" ] && inner_args+=( "--vkd3d" "$VKD3D_SOURCE_KEY" )
    [ -n "$DXVK_BRANCH_ARG" ]        && inner_args+=( "--dxvk-branch" "$DXVK_BRANCH_ARG" )
    [ -n "$VKD3D_BRANCH_ARG" ]       && inner_args+=( "--vkd3d-branch" "$VKD3D_BRANCH_ARG" )
    [ "$JOBS" != "$(nproc)" ]        && inner_args+=( "--jobs" "$JOBS" )
    [ "$SKIP_32BIT" = "true" ]       && inner_args+=( "--skip-32" )
    [ "$NO_CCACHE" = "true" ]        && inner_args+=( "--no-ccache" )
    [ "$KEEP_SYMBOLS" = "true" ]     && inner_args+=( "--keep-symbols" )
    [ "$BUILD_TYPE" != "release" ]   && inner_args+=( "--build-type" "$BUILD_TYPE" )
    [ "$NATIVE_MARCH" = "true" ]     && inner_args+=( "--native" )
    [ "$LTO" = "true" ]              && inner_args+=( "--lto" )
    [ "$RESUME" = "true" ]           && inner_args+=( "--resume" )
    [ "$NO_PULL" = "true" ]          && inner_args+=( "--no-pull" )
    [ "$DRY_RUN" -eq 1 ]            && inner_args+=( "--dry-run" )
    [ "$SNIPER_MODE" = "true" ]      && inner_args+=( "--sniper" )
    [ -n "$PATCH_GROUPS" ]           && inner_args+=( "--patches" "$PATCH_GROUPS" )
    [ -n "$NEUTRON_BUILD_MODE" ]     && inner_args+=( "--build-mode" "$NEUTRON_BUILD_MODE" )
    [ "$ALLOW_PATCH_FAILURES" = "true" ] && inner_args+=( "--allow-patch-failures" )

    # Profiles inside the script dir are visible in the container (the script
    # dir is mounted); a profile kept elsewhere gets its own read-only mount.
    local -a profile_mount=()
    if [ -n "$PROFILE_DIR" ]; then
        if [ "$PROFILE_DIR" = "${PROFILES_DIR}/${PROFILE_NAME}" ]; then
            inner_args+=( "--profile" "$PROFILE_NAME" )
        else
            profile_mount=( -v "${PROFILE_DIR}:/profiles/${PROFILE_NAME}:ro,${vol_flag#:}" )
            inner_args+=( "--profile" "/profiles/${PROFILE_NAME}" )
        fi
    fi

    # ── Resolve mount paths ──────────────────────────────────────────────
    # Two bind mounts:
    #   1. _LIB_DIR  → WORKDIR  (scripts: neutron-builder.sh + helpers)
    #   2. _DATA_DIR → /data    (persistent: buildz/ + src/)
    # We pass --dest and --src-dir so the build writes to /data inside the
    # container, which maps back to _DATA_DIR on the host.
    local container_home="/home/$(whoami)/mythix-neutron_builder"
    local container_data="/data"
    mkdir -p "$_DATA_DIR"

    inner_args+=( "--dest" "${container_data}/buildz" )
    inner_args+=( "--src-dir" "${container_data}/src" )

    section "Launching container build"
    # ── Engine-specific flags ────────────────────────────────────────────
    # Podman rootless needs --userns=keep-id so the host UID is mapped
    # into the container with a proper /etc/passwd entry.
    local -a engine_flags=()
    if [ "$engine" = "podman" ]; then
        engine_flags+=( "--userns=keep-id" )
    else
        # Docker: run as the current user so file ownership matches the host
        engine_flags+=( "--user" "$(id -u):$(id -g)" )
    fi

    msg2 "Engine     : ${engine}"
    msg2 "Image      : ${image_name}"
    msg2 "Scripts    : ${_LIB_DIR} → ${container_home}"
    msg2 "Config     : ${CUSTOM_CFG}"
    msg2 "Data dir   : ${_DATA_DIR} → ${container_data}"
    msg2 "Inner args : $(printf '%s ' "${inner_args[@]}")"

    # Mount _LIB_DIR as the WORKDIR (helper scripts), then overlay the main
    # script on top.  In the installed layout the main script lives in bin/
    # (as "neutron-builder", no .sh) while helpers live in lib/.  The file
    # bind mount adds it into the directory mount so both are visible.
    local _self
    _self="$(readlink -f "${BASH_SOURCE[0]}")"

    # ── Config file mount ──────────────────────────────────────────────
    # Inside the container _CFG_DIR resolves to ~/.config/mythix-build,
    # so mount the host cfg file to that same path inside the container.
    local container_cfg="/home/$(whoami)/.config/mythix-build/neutron-customization.cfg"
    local -a cfg_mount=()
    if [ -f "$CUSTOM_CFG" ]; then
        cfg_mount=( -v "${CUSTOM_CFG}:${container_cfg}:ro,${vol_flag#:}" )
        inner_args+=( "--cfg" "$container_cfg" )
    fi

    # Only allocate a TTY when stdin is a real terminal; without this,
    # running via nohup/redirection causes podman to exit silently.
    local tty_flag="-i"
    [ -t 0 ] && tty_flag="-it"

    "$engine" run --rm $tty_flag \
        "${engine_flags[@]}" \
        -v "${_LIB_DIR}:${container_home}${vol_flag}" \
        -v "${_self}:${container_home}/neutron-builder.sh:ro,${vol_flag#:}" \
        "${cfg_mount[@]}" \
        "${profile_mount[@]+"${profile_mount[@]}"}" \
        -v "${_DATA_DIR}:${container_data}${vol_flag}" \
        -v "mythix-neutron_builder-ccache:/home/$(whoami)/.ccache${vol_flag}" \
        "$image_name" \
        bash neutron-builder.sh "${inner_args[@]}"
    local _container_exit=$?

    # Fix output ownership: if we ran as root but the script dir is owned by
    # another user (e.g. ember2442), chown the data dir to match so the user
    # can copy/move the finished package without needing sudo.
    local _dir_uid _dir_gid
    _dir_uid=$(stat -c '%u' "$_LIB_DIR")
    _dir_gid=$(stat -c '%g' "$_LIB_DIR")
    if [ "$_dir_uid" != "0" ] && [ "$(id -u)" = "0" ]; then
        msg "Fixing output ownership → ${_dir_uid}:${_dir_gid}"
        chown -R "${_dir_uid}:${_dir_gid}" "$_DATA_DIR" 2>/dev/null || true
    fi

    exit "$_container_exit"
}

