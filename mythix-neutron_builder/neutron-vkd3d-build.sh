#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║         mythix-neutron_builder  •  VKD3D-Proton build                       ║
# ║   Cross-compiles VKD3D-Proton (D3D12 → Vulkan) for x86 and x86_64        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Required env vars (set by neutron-builder.sh):
#   VKD3D_SOURCE_DIR    — path to the cloned VKD3D-Proton source tree
#   VKD3D_SOURCE_KEY    — vkd3d-proton
#   NEUTRON_PACKAGE_DIR  — root of the Proton package being assembled
#
# VKD3D-Proton output layout inside the Proton package:
#   files/lib/wine/vkd3d-proton/   — 32-bit d3d12.dll + d3d12core.dll
#   files/lib64/wine/vkd3d-proton/ — 64-bit d3d12.dll + d3d12core.dll
#
# widl (Wine's IDL compiler) is required and is taken from the built Wine
# install inside NEUTRON_PACKAGE_DIR/files/bin/widl.
#
set -euo pipefail

# ── Output helpers ────────────────────────────────────────────────────────────
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
    _R="\033[0m" _B="\033[1m" _GRN="\033[1;32m" _BLU="\033[1;34m"
    _YLW="\033[1;33m" _RED="\033[1;31m" _DIM="\033[2m"
else
    _R="" _B="" _GRN="" _BLU="" _YLW="" _RED="" _DIM=""
fi
msg()  { printf "${_GRN}==> ${_R}${_B}%s${_R}\n" "$*"; }
msg2() { printf "${_BLU} -> ${_R}%s\n" "$*"; }
ok()   { printf "${_GRN} ✓  ${_R}%s\n" "$*"; }
warn() { printf "${_YLW}warn${_R} %s\n" "$*" >&2; }
err()  { printf "${_RED}ERR!${_R} %s\n" "$*" >&2; exit 1; }
sep()  { printf "\n${_BLU}${_B}── %s ──${_R}\n" "$*"; }

# ── Validate required env ─────────────────────────────────────────────────────
: "${VKD3D_SOURCE_DIR:?VKD3D_SOURCE_DIR must be set}"
: "${NEUTRON_PACKAGE_DIR:?NEUTRON_PACKAGE_DIR must be set}"
: "${VKD3D_SOURCE_KEY:=vkd3d-proton}"
: "${JOBS:=$(nproc)}"

[ -d "$VKD3D_SOURCE_DIR" ] || \
    err "VKD3D-Proton source directory not found: $VKD3D_SOURCE_DIR"
[ -f "${VKD3D_SOURCE_DIR}/meson.build" ] || \
    err "meson.build not found in: $VKD3D_SOURCE_DIR"

# ── Paths ─────────────────────────────────────────────────────────────────────
VKD3D_DEST_32="${NEUTRON_PACKAGE_DIR}/files/lib/wine/vkd3d-proton"
VKD3D_DEST_64="${NEUTRON_PACKAGE_DIR}/files/lib64/wine/vkd3d-proton"
BUILD_DIR_32="${VKD3D_SOURCE_DIR}/build/x32"
BUILD_DIR_64="${VKD3D_SOURCE_DIR}/build/x64"
VKD3D_INCLUDE_DIR="${VKD3D_SOURCE_DIR}/include"
WRAPPER_DIR="${VKD3D_SOURCE_DIR}/.compiler-wrappers"

# widl — Wine's IDL compiler, required by VKD3D-Proton.
# Use the widl we already compiled as part of the Wine build.
WINE_FILES_DIR="${NEUTRON_PACKAGE_DIR}/files"
WIDL_PATH="${WINE_FILES_DIR}/bin/widl"

sep "VKD3D-Proton build"
msg2 "Source dir  : ${VKD3D_SOURCE_DIR}"
msg2 "64-bit dest : ${VKD3D_DEST_64}"
msg2 "32-bit dest : ${VKD3D_DEST_32}"
msg2 "Jobs        : ${JOBS}"

# ══════════════════════════════════════════════════════════════════════════════
#  Auto-detect pre-built DLLs
#
#  If DLLs already exist in the expected build output directories, skip the
#  full Meson + Ninja build and install them directly.  This covers the common
#  case where VKD3D-Proton was built in a prior run and the user just wants to
#  (re)package it into a new Wine build without rebuilding from source.
#
#  Pass FORCE_REBUILD=true (or --vkd3d-only from neutron-builder.sh) to skip
#  this check and always rebuild from source.
# ══════════════════════════════════════════════════════════════════════════════
_vkd3d_prebuilt_count_64=$(find "$BUILD_DIR_64" -name '*.dll' 2>/dev/null | wc -l || true)
_vkd3d_prebuilt_count_32=$(find "$BUILD_DIR_32" -name '*.dll' 2>/dev/null | wc -l || true)

if [ "${FORCE_REBUILD:-false}" != "true" ] \
   && [ "$_vkd3d_prebuilt_count_64" -gt 0 ]; then
    sep "VKD3D-Proton — installing from pre-built DLLs"
    ok "Found ${_vkd3d_prebuilt_count_64} pre-built 64-bit DLLs in: ${BUILD_DIR_64}"
    mkdir -p "$VKD3D_DEST_64" "$VKD3D_DEST_32"
    find "$BUILD_DIR_64" -name '*.dll' -exec cp {} "$VKD3D_DEST_64/" \;
    _n=$(find "$VKD3D_DEST_64" -name '*.dll' | wc -l)
    ok "VKD3D-Proton 64-bit installed: ${_n} DLLs"
    if [ "$_vkd3d_prebuilt_count_32" -gt 0 ]; then
        ok "Found ${_vkd3d_prebuilt_count_32} pre-built 32-bit DLLs in: ${BUILD_DIR_32}"
        find "$BUILD_DIR_32" -name '*.dll' -exec cp {} "$VKD3D_DEST_32/" \;
        _n=$(find "$VKD3D_DEST_32" -name '*.dll' | wc -l)
        ok "VKD3D-Proton 32-bit installed: ${_n} DLLs"
    else
        warn "No pre-built 32-bit DLLs found in: ${BUILD_DIR_32}"
        warn "Pass FORCE_REBUILD=true to rebuild VKD3D-Proton from source."
    fi
    ok "VKD3D-Proton installed from pre-built DLLs (${_vkd3d_prebuilt_count_64} x86_64 + ${_vkd3d_prebuilt_count_32} i686)"
    exit 0
fi

# ── widl check ────────────────────────────────────────────────────────────────
if [ -x "$WIDL_PATH" ]; then
    ok "widl found: ${WIDL_PATH}"
elif command -v widl >/dev/null 2>&1; then
    WIDL_PATH="$(command -v widl)"
    ok "widl found in PATH: ${WIDL_PATH}"
else
    err "widl not found at ${WIDL_PATH} and not in PATH.
     widl is built as part of Wine — it should be at:
       ${WINE_FILES_DIR}/bin/widl
     Make sure the Wine build completed before running this step."
fi

# ── glslangValidator check ────────────────────────────────────────────────────
if command -v glslangValidator >/dev/null 2>&1; then
    ok "glslangValidator: $(glslangValidator --version 2>&1 | head -1)"
else
    err "glslangValidator not found — install: sudo apt install glslang-tools"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Initialize VKD3D-Proton git submodules
#
#  VKD3D-Proton bundles its own Vulkan-Headers and SPIRV-Headers as submodules
#  under subprojects/Vulkan-Headers/ and subprojects/SPIRV-Headers/.
#  It also needs subprojects/dxil-spirv/ and its own nested submodules.
# ══════════════════════════════════════════════════════════════════════════════
sep "Initializing VKD3D-Proton git submodules"
git -C "$VKD3D_SOURCE_DIR" submodule update --init --recursive
ok "Submodules initialized"

# ══════════════════════════════════════════════════════════════════════════════
#  Detect Vulkan + SPIRV header include roots
#
#  VKD3D-Proton submodule layout (Khronos standard):
#    subprojects/Vulkan-Headers/include/vulkan/vulkan.h
#    subprojects/SPIRV-Headers/include/spirv/unified1/spirv.hpp
#  Include root to pass to compiler: subprojects/<n>/include
# ══════════════════════════════════════════════════════════════════════════════
sep "Detecting header include roots"

_find_include_root() {
    # Usage: _find_include_root <search_base> <relative_header>
    # Returns the -I path needed so that #include "<relative_header>" resolves
    local base="$1" header="$2"
    local found
    found="$(find "$base" -path "*/${header}" 2>/dev/null | head -1 || true)"
    [ -n "$found" ] || return 1
    # Strip the header suffix to get the include root
    printf '%s' "${found%/${header}}"
}

VULKAN_INCLUDE_ROOT="$(_find_include_root "$VKD3D_SOURCE_DIR" "vulkan/vulkan.h")" || \
    err "vulkan/vulkan.h not found after submodule init in $VKD3D_SOURCE_DIR"
SPIRV_INCLUDE_ROOT="$(_find_include_root "$VKD3D_SOURCE_DIR" "spirv/unified1/spirv.hpp")" || \
    err "spirv/unified1/spirv.hpp not found after submodule init in $VKD3D_SOURCE_DIR"

ok "Vulkan include root : ${VULKAN_INCLUDE_ROOT}"
ok "SPIRV  include root : ${SPIRV_INCLUDE_ROOT}"

# ══════════════════════════════════════════════════════════════════════════════
#  Create MinGW compiler wrapper scripts
#
#  Same technique as DXVK: bake the include paths into thin wrappers so
#  Meson's internal has_header() checks see the correct headers.
# ══════════════════════════════════════════════════════════════════════════════
sep "Creating MinGW compiler wrappers"
mkdir -p "$WRAPPER_DIR"

_make_wrapper() {
    local real_bin="$1"
    # Prefer the posix-threading variant: it provides std::vswprintf and other
    # POSIX extensions that VKD3D-Proton's C++ code needs.
    local real_path
    if command -v "${real_bin}-posix" >/dev/null 2>&1; then
        real_path="$(command -v "${real_bin}-posix")"
        ok "Using posix variant: ${real_bin}-posix"
    else
        real_path="$(command -v "${real_bin}")" || \
            err "MinGW compiler not found: ${real_bin}
     Install: sudo apt install gcc-mingw-w64 g++-mingw-w64"
        warn "posix variant not found for ${real_bin}, using win32 variant"
    fi
    local _triple="${real_bin%-*}"   # strip trailing -gcc or -g++
    local _mingw_inc="/usr/${_triple}/include"
    local wrapper="${WRAPPER_DIR}/${real_bin}"
    printf '#!/bin/sh\nexec "%s" -I"%s" -I"%s" -I"%s" "$@"\n' \
        "$real_path" "$_mingw_inc" "$VULKAN_INCLUDE_ROOT" "$SPIRV_INCLUDE_ROOT" > "$wrapper"
    chmod +x "$wrapper"
    ok "Wrapper: ${real_bin}  (sysroot: ${_mingw_inc})"
}

_make_wrapper "x86_64-w64-mingw32-gcc"
_make_wrapper "x86_64-w64-mingw32-g++"
_make_wrapper "i686-w64-mingw32-gcc"
_make_wrapper "i686-w64-mingw32-g++"

# ══════════════════════════════════════════════════════════════════════════════
#  _write_cross_file
#  Includes widl from our Wine build so VKD3D-Proton can compile its IDL files.
#  Usage: _write_cross_file <arch>   arch = x86_64 | i686
# ══════════════════════════════════════════════════════════════════════════════
_write_cross_file() {
    local arch="$1"
    local cross_file="${VKD3D_SOURCE_DIR}/build-cross-${arch}.txt"
    local cpu cpu_family

    case "$arch" in
        x86_64) cpu="x86_64"; cpu_family="x86_64" ;;
        i686)   cpu="i686";   cpu_family="x86"    ;;
        *)      err "_write_cross_file: unknown arch '$arch'" ;;
    esac

    cat > "$cross_file" << EOF
[binaries]
c       = '${WRAPPER_DIR}/${arch}-w64-mingw32-gcc'
cpp     = '${WRAPPER_DIR}/${arch}-w64-mingw32-g++'
ar      = '${arch}-w64-mingw32-ar'
strip   = '${arch}-w64-mingw32-strip'
windres = '${arch}-w64-mingw32-windres'
widl    = '${WIDL_PATH}'
pkg-config = ['pkg-config', '--define-variable=prefix=/usr/${arch}-w64-mingw32']

[properties]
needs_exe_wrapper = true
sys_root = '/usr/${arch}-w64-mingw32'

[built-in options]
c_args   = ['-D_UCRT', '-D__USE_MINGW_ANSI_STDIO=1']
cpp_args = ['-D_UCRT', '-D__USE_MINGW_ANSI_STDIO=1']
c_link_args   = ['-static-libgcc',
                 '-Wl,-Bstatic,-lwinpthread,-lgcc,-Bdynamic']
cpp_link_args = ['-static-libgcc',
                 '-Wl,-Bstatic,-lstdc++,-lwinpthread,-lgcc,-lgcc_eh,-Bdynamic']

[host_machine]
system     = 'windows'
cpu_family = '${cpu_family}'
cpu        = '${cpu}'
endian     = 'little'
EOF
    printf '%s' "$cross_file"
}

# ══════════════════════════════════════════════════════════════════════════════
#  _build_vkd3d_arch  —  configure + build one arch
#  Usage: _build_vkd3d_arch <arch> <build_dir> <dest_dir>
# ══════════════════════════════════════════════════════════════════════════════
_build_vkd3d_arch() {
    local arch="$1" build_dir="$2" dest_dir="$3"

    sep "VKD3D-Proton ${arch} configure"
    local cross_file
    cross_file="$(_write_cross_file "$arch")"
    ok "Cross file: $cross_file"

    if [ -d "$build_dir" ]; then
        msg2 "Wiping existing build directory: $build_dir"
        rm -rf "$build_dir"
    fi
    mkdir -p "$(dirname "$build_dir")"

    meson setup \
        --cross-file="$cross_file" \
        --buildtype=release \
        --strip \
        -Denable_tests=false \
        -Denable_extras=false \
        "$build_dir" \
        "$VKD3D_SOURCE_DIR"

    sep "VKD3D-Proton ${arch} compile  (jobs=${JOBS})"
    ninja -C "$build_dir" -j"${JOBS}"
    ok "VKD3D-Proton ${arch} build complete"

    sep "VKD3D-Proton ${arch} install → ${dest_dir}"
    mkdir -p "$dest_dir"
    local _count=0
    while IFS= read -r dll_path; do
        cp "$dll_path" "$dest_dir/"
        ok "  $(basename "$dll_path")"
        _count=$(( _count + 1 ))
    done < <(find "$build_dir" -name '*.dll' 2>/dev/null | sort)
    [ "$_count" -gt 0 ] || err "No .dll files found in VKD3D-Proton ${arch} build tree: $build_dir"
    ok "VKD3D-Proton ${arch} installed: ${_count} DLLs"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Build both architectures
# ══════════════════════════════════════════════════════════════════════════════
_build_vkd3d_arch "x86_64" "$BUILD_DIR_64" "$VKD3D_DEST_64"
_build_vkd3d_arch "i686"   "$BUILD_DIR_32" "$VKD3D_DEST_32"

# ══════════════════════════════════════════════════════════════════════════════
#  Verify output
# ══════════════════════════════════════════════════════════════════════════════
sep "Verifying VKD3D-Proton install"
_total=0
for dir in "$VKD3D_DEST_64" "$VKD3D_DEST_32"; do
    _count=$(find "$dir" -name '*.dll' 2>/dev/null | wc -l)
    ok "$(basename "$dir"): ${_count} .dll files"
    _total=$(( _total + _count ))
done
[ "$_total" -gt 0 ] || err "No VKD3D-Proton .dll files were installed."
ok "VKD3D-Proton installed successfully (${_total} total DLL files)"
