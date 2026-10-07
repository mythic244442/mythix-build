#!/usr/bin/env bash
# ╔═════════════════════════════════════════════════════════════════════════════╗
# ║   mythix-neutron_builder  •  mythix-ffmpeg-build.sh                         ║
# ║   Static FFmpeg for winedmo (GE media stack)                                ║
# ╚═════════════════════════════════════════════════════════════════════════════╝
#
# GE-Proton's media rework removes winegstreamer: Media Foundation / DirectShow
# decoding goes through winedmo, which links FFmpeg (avformat, avcodec, avutil,
# swscale, swresample).  GE ships its own FFmpeg build; so do we — but linked
# statically into winedmo.so, so a package built in the Ubuntu container never
# depends on the host's libavcodec soname (which changes every FFmpeg major).
#
# Configure flags mirror GE's Makefile.in (FFMPEG_CONFIGURE_ARGS) with
# static + PIC instead of shared, and optional libraries auto-detected per arch.
#
# Output per arch:
#   <build-dir>/<arch>/prefix/{include,lib/*.a,lib/pkgconfig}
#   <build-dir>/<arch>/prefix/ffmpeg-libs.txt   — FFMPEG_LIBS for Wine's configure
#   <build-dir>/<arch>/{configure,make}.log
# A stamp skips rebuilding when commit + flags + compiler are unchanged.
#
# Usage:
#   mythix-ffmpeg-build.sh --commit SHA --src-dir DIR --build-dir DIR
#                          [--repo URL] [--archs x86_64,i386] [--jobs N] [--offline]
#
set -euo pipefail

_SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
    C_R="\033[0m" C_B="\033[1m" C_GRN="\033[1;32m" C_BLU="\033[1;34m"
    C_YLW="\033[1;33m" C_RED="\033[1;31m" C_CYN="\033[1;35m" C_MAG="\033[1;36m" C_DIM="\033[2m"
else
    C_R="" C_B="" C_GRN="" C_BLU="" C_YLW="" C_RED="" C_CYN="" C_MAG="" C_DIM=""
fi
# shellcheck source=_output_common.sh
. "${_SELF_DIR}/_output_common.sh"

REPO="https://github.com/FFmpeg/FFmpeg.git"
COMMIT="" SRC_DIR="" BUILD_DIR=""
ARCHS="x86_64"
JOBS="$(nproc)"
OFFLINE=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo)      REPO="$2";      shift 2 ;;
        --commit)    COMMIT="$2";    shift 2 ;;
        --src-dir)   SRC_DIR="$2";   shift 2 ;;
        --build-dir) BUILD_DIR="$2"; shift 2 ;;
        --archs)     ARCHS="$2";     shift 2 ;;
        --jobs)      JOBS="$2";      shift 2 ;;
        --offline)   OFFLINE=true;   shift   ;;
        -h|--help)   sed -n '2,26p' "$0"; exit 0 ;;
        *) err "Unknown option: $1" ;;
    esac
done
[ -n "$COMMIT" ]    || err "--commit is required"
[ -n "$SRC_DIR" ]   || err "--src-dir is required"
[ -n "$BUILD_DIR" ] || err "--build-dir is required"

_git() { git -c advice.detachedHead=false "$@"; }
git config --global --add safe.directory '*' 2>/dev/null || true

# ── Source at the pinned commit ──────────────────────────────────────────────
section "FFmpeg source  (${COMMIT:0:12})"
if [ ! -d "${SRC_DIR}/.git" ]; then
    mkdir -p "$SRC_DIR"
    _git init -q "$SRC_DIR"
    _git -C "$SRC_DIR" remote add origin "$REPO"
fi
if ! _git -C "$SRC_DIR" cat-file -e "${COMMIT}^{commit}" 2>/dev/null; then
    [ "$OFFLINE" = "false" ] || err "FFmpeg commit ${COMMIT} is not present and --offline was given"
    msg "Fetching FFmpeg ${COMMIT:0:12} from ${REPO}…"
    _git -C "$SRC_DIR" fetch -q --depth 1 origin "$COMMIT" || \
        err "Could not fetch FFmpeg commit ${COMMIT} from ${REPO}"
fi
_git -C "$SRC_DIR" checkout -q -f "$COMMIT"
_git -C "$SRC_DIR" clean -q -xdf
ok "FFmpeg $(cat "${SRC_DIR}/RELEASE" 2>/dev/null || echo '?') at ${COMMIT:0:12}"

# GE's flag set (proton-ge-custom Makefile.in, FFMPEG_CONFIGURE_ARGS), static.
COMMON_ARGS=(
    --enable-static --disable-shared --enable-pic
    --disable-everything
    --disable-programs --disable-doc --disable-inline-asm --disable-debug
    --disable-autodetect --disable-avdevice --disable-avfilter
    --enable-demuxers --enable-decoders --enable-encoders --enable-bsfs
    --disable-decoder=vvc
)

_links_bzlib() {   # <cc> — header AND library for that arch (headers are shared across arches)
    printf '#include <bzlib.h>\nint main(void) { return BZ2_bzlibVersion() == 0; }\n' | \
        "$1" -x c - -lbz2 -o /dev/null >/dev/null 2>&1
}

build_arch() {
    local arch="$1"
    local cc pcdir
    local -a arch_args=()
    case "$arch" in
        x86_64)
            cc="gcc"
            pcdir="/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig:/usr/lib/pkgconfig"
            arch_args=( --arch=x86_64 --target-os=linux )
            if ! command -v nasm >/dev/null 2>&1; then
                warn "nasm not found — FFmpeg x86_64 built without SIMD asm (slower decoding)"
                arch_args+=( --disable-x86asm )
            fi
            ;;
        i386)
            cc="i686-linux-gnu-gcc"
            command -v "$cc" >/dev/null 2>&1 || err "32-bit cross-compiler not found: $cc"
            pcdir="/usr/lib/i386-linux-gnu/pkgconfig:/usr/share/pkgconfig:/usr/lib/pkgconfig"
            # x86-32 asm is not PIC-clean (text relocations in winedmo.so) — C only
            arch_args=( --enable-cross-compile --cross-prefix=i686-linux-gnu-
                        --arch=x86 --target-os=linux --disable-asm )
            ;;
        *) err "Unsupported FFmpeg arch: ${arch}" ;;
    esac

    # Optional libraries — enabled only when this arch's dev files exist.
    # They stay shared (stable sonames: libz.so.1, libgnutls.so.30, liblzma.so.5,
    # libbz2.so.1.0); only FFmpeg itself is linked statically.
    local -a lib_args=() libs_on=()
    if PKG_CONFIG_LIBDIR="$pcdir" pkg-config --exists zlib 2>/dev/null; then
        lib_args+=( --enable-zlib ); libs_on+=( zlib )
    fi
    if PKG_CONFIG_LIBDIR="$pcdir" pkg-config --exists gnutls 2>/dev/null; then
        lib_args+=( --enable-gnutls --enable-protocol=https ); libs_on+=( gnutls/https )
    fi
    if PKG_CONFIG_LIBDIR="$pcdir" pkg-config --exists liblzma 2>/dev/null; then
        lib_args+=( --enable-lzma ); libs_on+=( lzma )
    fi
    if _links_bzlib "$cc"; then
        lib_args+=( --enable-bzlib ); libs_on+=( bzlib )
    fi

    local work="${BUILD_DIR}/${arch}"
    local prefix="${work}/prefix"
    local stamp_val
    stamp_val="$(printf '%s\n' "$COMMIT" "${COMMON_ARGS[@]}" "${arch_args[@]}" "${lib_args[@]}" \
                 "$("$cc" --version 2>/dev/null | head -1)" | sha256sum | cut -d' ' -f1)"

    section "FFmpeg ${arch}  (static, PIC)"
    msg2 "Libraries: ${libs_on[*]:-none}"
    if [ -f "${prefix}/.mythix-ffmpeg-stamp" ] && \
       [ "$(cat "${prefix}/.mythix-ffmpeg-stamp")" = "$stamp_val" ] && \
       [ -f "${prefix}/ffmpeg-libs.txt" ]; then
        ok "Up to date — reusing ${prefix}"
        return 0
    fi

    rm -rf "$work"
    mkdir -p "${work}/build"
    msg "Configuring FFmpeg (${arch})…"
    ( cd "${work}/build" && \
      PKG_CONFIG_LIBDIR="$pcdir" "${SRC_DIR}/configure" \
          --prefix="$prefix" \
          "${COMMON_ARGS[@]}" "${arch_args[@]}" "${lib_args[@]}" ) \
        > "${work}/configure.log" 2>&1 || {
            tail -25 "${work}/configure.log" >&2
            err "FFmpeg configure failed (${arch}) — ${work}/configure.log"; }

    msg "Compiling FFmpeg (${arch}, jobs=${JOBS})…"
    ( cd "${work}/build" && make -j"$JOBS" && make install ) > "${work}/make.log" 2>&1 || {
        grep -E "error:|Error [0-9]" "${work}/make.log" | head -20 >&2
        err "FFmpeg build failed (${arch}) — ${work}/make.log"; }

    # Link line for Wine's configure (FFMPEG_LIBS).  Grouped so static archive
    # order never matters (winedmo also appends -lswscale -lswresample), and
    # --exclude-libs keeps FFmpeg's symbols out of winedmo.so's export table.
    local libs
    libs="$(PKG_CONFIG_LIBDIR="${prefix}/lib/pkgconfig:${pcdir}" pkg-config --static --libs \
            libavformat libavcodec libswscale libswresample libavutil)" || \
        err "pkg-config could not resolve the static FFmpeg link line (${arch})"
    printf '%s\n' "-Wl,--start-group ${libs} -Wl,--end-group -Wl,--exclude-libs,ALL" \
        > "${prefix}/ffmpeg-libs.txt"
    printf '%s\n' "$stamp_val" > "${prefix}/.mythix-ffmpeg-stamp"
    ok "FFmpeg ${arch} → ${prefix}"
    msg2 "FFMPEG_LIBS: $(cat "${prefix}/ffmpeg-libs.txt")"
}

IFS=',' read -ra _arch_list <<< "${ARCHS// /,}"
for _a in "${_arch_list[@]}"; do
    [ -n "$_a" ] && build_arch "$_a"
done
ok "FFmpeg ready for: ${ARCHS}"
