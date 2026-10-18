# ══════════════════════════════════════════════════════════════════════════════
#  Build DXVK
#
#  Calls neutron-dxvk-build.sh to cross-compile DXVK with Meson + MinGW.
#  Output .dll files are placed under:
#    ${NEUTRON_PACKAGE_DIR}/files/lib/wine/dxvk/x32/  (32-bit)
#    ${NEUTRON_PACKAGE_DIR}/files/lib/wine/dxvk/x64/  (64-bit)
# ══════════════════════════════════════════════════════════════════════════════
section "DXVK build  "
if [ "${SKIP_DXVK:-false}" = "true" ]; then
    msg2 "Skipping DXVK (--vkd3d-only)"
elif [ "${REINSTALL_COMPONENTS:-false}" = "true" ]; then
    section "DXVK reinstall from existing build"
    _dxvk_build_64="${SRC_ROOT}/dxvk-${DXVK_SOURCE_KEY}/build/x64"
    _dxvk_build_32="${SRC_ROOT}/dxvk-${DXVK_SOURCE_KEY}/build/x32"
    _dxvk_dest_64="${WINE_INSTALL_PREFIX}/lib/wine/dxvk/x64"
    _dxvk_dest_32="${WINE_INSTALL_PREFIX}/lib/wine/dxvk/x32"
    if [ ! -d "$_dxvk_build_64" ]; then
        warn "DXVK 64-bit build dir not found: $_dxvk_build_64"
        warn "Run --dxvk-only first to build DXVK"
    else
        mkdir -p "$_dxvk_dest_64" "$_dxvk_dest_32"
        find "$_dxvk_build_64" -name '*.dll' -exec cp {} "$_dxvk_dest_64/" \;
        _n=$(find "$_dxvk_dest_64" -name '*.dll' | wc -l)
        ok "DXVK 64-bit: ${_n} DLLs installed"
        if [ -d "$_dxvk_build_32" ]; then
            find "$_dxvk_build_32" -name '*.dll' -exec cp {} "$_dxvk_dest_32/" \;
            _n=$(find "$_dxvk_dest_32" -name '*.dll' | wc -l)
            ok "DXVK 32-bit: ${_n} DLLs installed"
        fi
    fi
elif [ "${DXVK_SOURCE_KEY}" = "dxvk-release" ]; then
    section "DXVK  — downloading pre-built release"
    _download_dxvk_release \
        "${WINE_INSTALL_PREFIX}/lib/wine/dxvk/x64" \
        "${WINE_INSTALL_PREFIX}/lib/wine/dxvk/x32"
elif [ "${DXVK_SOURCE_KEY}" != "none" ]; then
    if [ -x "$DXVK_BUILDER" ]; then
        export NEUTRON_PACKAGE_DIR
        "$DXVK_BUILDER"
    else
        warn "neutron-dxvk-build.sh not found or not executable: $DXVK_BUILDER"
        warn "D3D9/D3D10/D3D11 games will fall back to WineD3D (slower)"
        warn "Try: --dxvk dxvk-release  to download pre-built DLLs instead"
    fi
else
    msg2 "DXVK skipped (--dxvk none)"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Build VKD3D-Proton
#
#  It compiles VKD3D-Proton with Meson + MinGW and places d3d12.dll under:
#    ${NEUTRON_PACKAGE_DIR}/files/lib/wine/vkd3d-proton/i386-windows/      (32-bit)
#    ${NEUTRON_PACKAGE_DIR}/files/lib/wine/vkd3d-proton/x86_64-windows/  (64-bit)
# ══════════════════════════════════════════════════════════════════════════════
section "VKD3D-Proton build  "
if [ "${REINSTALL_COMPONENTS:-false}" = "true" ]; then
    section "VKD3D-Proton reinstall from existing build"
    _vkd3d_build_64="${SRC_ROOT}/vkd3d-proton/build/x64"
    _vkd3d_build_32="${SRC_ROOT}/vkd3d-proton/build/x32"
    _vkd3d_dest_64="${WINE_INSTALL_PREFIX}/lib/wine/vkd3d-proton/x86_64-windows"
    _vkd3d_dest_32="${WINE_INSTALL_PREFIX}/lib/wine/vkd3d-proton/i386-windows"
    if [ ! -d "$_vkd3d_build_64" ]; then
        warn "VKD3D-Proton 64-bit build dir not found: $_vkd3d_build_64"
        warn "Run --vkd3d-only first to build VKD3D-Proton"
    else
        mkdir -p "$_vkd3d_dest_64" "$_vkd3d_dest_32"
        find "$_vkd3d_build_64" -name '*.dll' -exec cp {} "$_vkd3d_dest_64/" \;
        _n=$(find "$_vkd3d_dest_64" -name '*.dll' | wc -l)
        ok "VKD3D-Proton 64-bit: ${_n} DLLs installed"
        if [ -d "$_vkd3d_build_32" ]; then
            find "$_vkd3d_build_32" -name '*.dll' -exec cp {} "$_vkd3d_dest_32/" \;
            _n=$(find "$_vkd3d_dest_32" -name '*.dll' | wc -l)
            ok "VKD3D-Proton 32-bit: ${_n} DLLs installed"
        fi
    fi
elif [ "${VKD3D_SOURCE_KEY}" = "vkd3d-proton-release" ]; then
    section "VKD3D-Proton  — downloading pre-built release"
    _download_vkd3d_release \
        "${WINE_INSTALL_PREFIX}/lib/wine/vkd3d-proton/x86_64-windows" \
        "${WINE_INSTALL_PREFIX}/lib/wine/vkd3d-proton/i386-windows"
elif [ "${VKD3D_SOURCE_KEY}" != "none" ]; then
    if [ -x "$VKD3D_BUILDER" ]; then
        export NEUTRON_PACKAGE_DIR
        "$VKD3D_BUILDER"
    else
        warn "neutron-vkd3d-build.sh not found or not executable: $VKD3D_BUILDER"
        warn "DirectX 12 games will not work without VKD3D-Proton"
        warn "Try: --vkd3d vkd3d-proton-release  to download pre-built DLLs instead"
    fi
else
    msg2 "VKD3D-Proton skipped (--vkd3d none)"
fi

