# ══════════════════════════════════════════════════════════════════════════════
#  COMPILE + INSTALL  — proton-wine  (skipped with --dxvk-only / --vkd3d-only)
# ══════════════════════════════════════════════════════════════════════════════
if [ "$SKIP_WINE_BUILD" = "true" ]; then
    section "Skipping Wine build (--dxvk-only / --vkd3d-only)"
    # Verify a prior Wine install actually exists before proceeding
    [ -f "${WINE_INSTALL_PREFIX}/bin/wine" ] || \
        err "No prior Wine install found at: ${WINE_INSTALL_PREFIX}/bin/wine
     Run a full build first before using --dxvk-only / --vkd3d-only."
    ok "Using existing Wine install at: ${WINE_INSTALL_PREFIX}"
else
    # ── Pre-build fixes and header generation ──────────────────────────────
    section "Pre-build headers"
    fix_opencl_headers
    pregen_headers "$WINE_SOURCE_DIR"

    # ── autoreconf ──────────────────────────────────────────────────────────
    if [ "$RESUME" = "true" ] && { [ -f "${BUILD_RUN_DIR}/wine-unified/Makefile" ] || [ -f "${BUILD_RUN_DIR}/wine64/Makefile" ]; }; then
        msg2 "--resume: skipping autoreconf"
    else
        run_autoreconf "$WINE_SOURCE_DIR"
    fi

    # ── Validate build scripts ──────────────────────────────────────────────
    [ -f "$BUILD_CORE" ] || \
        err "Build core script not found: $BUILD_CORE
     Expected alongside neutron-builder.sh as neutron-build-core.sh"
    [ -x "$BUILD_CORE" ] || chmod +x "$BUILD_CORE"

    [ -f "$PACKAGER" ] || \
        err "Packager script not found: $PACKAGER
     Expected alongside neutron-builder.sh as neutron-package.sh"
    [ -x "$PACKAGER" ] || chmod +x "$PACKAGER"

    # ── Load configuration ──────────────────────────────────────────────────
    # Fallback: if the cfg isn't in _CFG_DIR, check alongside the script
    if [ ! -f "$CUSTOM_CFG" ] && [ -f "${_LIB_DIR}/neutron-customization.cfg" ]; then
        CUSTOM_CFG="${_LIB_DIR}/neutron-customization.cfg"
        msg2 "Config found alongside script: $CUSTOM_CFG"
    fi
    [ -f "$CUSTOM_CFG" ] || \
        err "Configuration file not found: $CUSTOM_CFG
     Copy and edit neutron-customization.cfg — see the README for details.
     (HOME=$HOME, _CFG_DIR=$_CFG_DIR, _LIB_DIR=$_LIB_DIR)"
    # shellcheck source=/dev/null
    source "$CUSTOM_CFG"

    # ── Export env to build-core ────────────────────────────────────────────
    export WINE_SOURCE="$WINE_SOURCE_DIR"
    export PREFIX="$WINE_INSTALL_PREFIX"
    export WINE_BUILD="${BUILD_NAME//-/_}"
    export NEUTRON_SOURCE_KEY="$WINE_SOURCE_KEY"
    export JOBS
    export SKIP_32BIT
    export BUILD_RUN_DIR
    export CUSTOM_CFG
    export RESUME
    export BUILD_LOG
    export NEUTRON_BUILD_MODE

    # ── FFmpeg for winedmo (profiles with PROFILE_FFMPEG=static) ────────────
    # GE's media rework removes winegstreamer: video/audio decoding goes
    # through winedmo + FFmpeg (GE ships its own FFmpeg build). We build GE's
    # pinned FFmpeg and link it statically into winedmo.so, so the package
    # never depends on the host's libavcodec soname.
    unset NEUTRON_FFMPEG_PREFIX_64 NEUTRON_FFMPEG_PREFIX_32
    if [ -n "$PROFILE_NAME" ] && [ "${PROFILE_FFMPEG:-none}" = "static" ]; then
        section "FFmpeg (static, for winedmo)"
        _ff_commit="${PIN_FFMPEG_COMMIT:-}"
        [ -n "$_ff_commit" ] || _ff_commit="$(sed -n 's/^ffmpeg_commit=//p' \
            "${BUILD_RUN_DIR}/mythix-source.lock" 2>/dev/null || true)"
        [ -n "$_ff_commit" ] || \
            err "Profile ${PROFILE_NAME}: no FFmpeg pin (PIN_FFMPEG_COMMIT, or ffmpeg_commit in the source lock)"
        _ff_archs="x86_64"
        [ "$SKIP_32BIT" = "true" ] || _ff_archs="x86_64,i386"
        [ "$DRY_RUN" -eq 1 ] && \
            dim "  [dry-run] bash $(basename "$FFMPEG_BUILDER") --commit ${_ff_commit} --archs ${_ff_archs}"
        [ "$DRY_RUN" -eq 1 ] || bash "$FFMPEG_BUILDER" \
            --repo "${PIN_FFMPEG_REPO:-https://github.com/FFmpeg/FFmpeg.git}" \
            --commit "$_ff_commit" \
            --src-dir "${SRC_ROOT}/ffmpeg" \
            --build-dir "${BUILD_RUN_DIR}/ffmpeg" \
            --archs "$_ff_archs" \
            --jobs "$JOBS" || err "FFmpeg build failed — logs in ${BUILD_RUN_DIR}/ffmpeg/"
        export NEUTRON_FFMPEG_PREFIX_64="${BUILD_RUN_DIR}/ffmpeg/x86_64/prefix"
        if [ -d "${BUILD_RUN_DIR}/ffmpeg/i386/prefix" ]; then
            export NEUTRON_FFMPEG_PREFIX_32="${BUILD_RUN_DIR}/ffmpeg/i386/prefix"
        fi
        if [ -f "${BUILD_RUN_DIR}/mythix-source.lock" ] && \
           ! grep -q '^ffmpeg_build=' "${BUILD_RUN_DIR}/mythix-source.lock"; then
            printf 'ffmpeg_build=static %s (%s)\n' "$_ff_commit" "$_ff_archs" \
                >> "${BUILD_RUN_DIR}/mythix-source.lock"
        fi
    fi

    # ── Compile ─────────────────────────────────────────────────────────────
    section "Compiling proton-wine"
    msg "Handing off to: $BUILD_CORE"
    mkdir -p "$BUILD_RUN_DIR"
    cd "$DEST_ROOT"
    "$BUILD_CORE"

    # ── Install ─────────────────────────────────────────────────────────────
    # Profile builds install into an empty files/ so nothing from an earlier
    # build (other mode, older pins) lingers in the package.
    if [ -n "$PROFILE_NAME" ]; then
        case "$WINE_INSTALL_PREFIX" in
            "${DEST_ROOT}/install/"?*/files)
                msg2 "Profile build: clearing ${WINE_INSTALL_PREFIX} before install"
                rm -rf "$WINE_INSTALL_PREFIX"
                mkdir -p "$WINE_INSTALL_PREFIX"
                ;;
        esac
    fi
    install_wine "$BUILD_RUN_DIR" "$WINE_INSTALL_PREFIX"

fi

