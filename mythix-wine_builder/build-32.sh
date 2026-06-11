#!/bin/bash

# ---- wrapper-friendly defaults and shims (paste in both build-64.sh and build-32.sh) ----
# Provide msg/msg2 if not already present (wrapper supplies them, but allow standalone use)
: "${msg:=$(command -v msg >/dev/null 2>&1 && : || true)}"
if ! declare -f msg >/dev/null 2>&1; then
  msg() { printf "==> %s\n" "$*"; }
fi
if ! declare -f msg2 >/dev/null 2>&1; then
  msg2() { printf "    %s\n" "$*"; }
fi

# Ensure commonly-used env vars exist with safe defaults
: "${srcdir:=${srcdir:-$(pwd)}}"
: "${pkgname:=${pkgname:-wine}}"
: "${_winesrcdir:=${_winesrcdir:-$(basename "${WINE_SOURCE:-$srcdir/$pkgname}")}}"
: "${_prefix:=${_prefix:-${PREFIX:-/usr/local}}}"
: "${_LAST_BUILD_CONFIG:=${_LAST_BUILD_CONFIG:-${PWD}/last_build_config}}"
: "${_where:=${_where:-$(pwd)}}"

# Ensure flags/arrays exist so expansions won't fail under set -u
: "${_NOCCACHE:=${_NOCCACHE:-false}}"
: "${_NOMINGW:=${_NOMINGW:-false}}"
: "${_NOLIB32:=${_NOLIB32:-false}}"
: "${_LOCAL_OPTIMIZED:=${_LOCAL_OPTIMIZED:-true}}"
: "${_log_errors_to_file:=${_log_errors_to_file:-false}}"
: "${_SINGLE_MAKE:=${_SINGLE_MAKE:-false}}"
: "${_NUKR:=}"             # <--- ADDED
: "${_DEBUGANSW3:=}"       # <--- ADDED
: "${_NOLIB64:=false}"     # <--- ADDED
: "${_pkg_strip:=false}"   # <--- ADDED
: "${_plain_version:=}"

# Arrays used by configure step: provide empty defaults if not set
: "${_configure_args64:=${_configure_args64:-}}"
: "${_configure_args:=${_configure_args:-}}"
# Allow them to be used as arrays even if empty
if [ -z "${_configure_args64+x}" ]; then _configure_args64=(); fi
if [ -z "${_configure_args+x}" ]; then _configure_args=(); fi

# Make sure last-build config file is writable (safe creation)
mkdir -p "$(dirname "$_LAST_BUILD_CONFIG")" 2>/dev/null || true
touch "$_LAST_BUILD_CONFIG" 2>/dev/null || true

# Sanity: helper callers expect configure at ../${_winesrcdir}/configure from build dir.
# If it doesn't exist, warn but continue.
_check_configure_path() {
  local cfg="$srcdir/${_winesrcdir}/configure"
  if [ ! -x "$cfg" ]; then
    msg2 "Warning: configure not found/executable at: $cfg"
    msg2 "Caller may be using a different layout; ensure WINE_SOURCE/_winesrcdir are set appropriately."
  fi
}
_check_configure_path
# ---- end defaults and shims ----

_exports_32() {
  if [ "$_NOCCACHE" != "true" ]; then
    if [ -e /usr/bin/ccache ]; then
      export CC="ccache gcc"
      export CXX="ccache g++"
    fi
    if [ -e /usr/bin/ccache ] && [ "$_NOMINGW" != "true" ]; then
      export CROSSCC="ccache i686-w64-mingw32-gcc" && echo "CROSSCC32 = ${CROSSCC}" >>"$_LAST_BUILD_CONFIG"
      export i386_CC="${CROSSCC}"
    fi
  fi

  # build wine 32-bit
  if [ -d '/usr/lib32/pkgconfig' ]; then # Typical Arch path
    export PKG_CONFIG_PATH='/usr/lib32/pkgconfig:/usr/share/pkgconfig'
    # glib/gstreamer detection workaround for proton 8.0 trees
    if [[ "$_plain_version" = *_8.0 ]] || [[ "$_plain_version" = *_9.0 ]]; then
      CFLAGS+=" -I/usr/lib32/glib-2.0/include -I/usr/include/glib-2.0 -I/usr/include/gstreamer-1.0 -I/usr/lib32/gstreamer-1.0/include"
      CROSSCFLAGS+=" -I/usr/lib32/glib-2.0/include -I/usr/include/glib-2.0 -I/usr/include/gstreamer-1.0 -I/usr/lib32/gstreamer-1.0/include"
    fi
  elif [ -d '/usr/lib/i386-linux-gnu/pkgconfig' ]; then # Ubuntu 18.04/19.04 path
    export PKG_CONFIG_PATH='/usr/lib/i386-linux-gnu/pkgconfig:/usr/share/pkgconfig'
    if [[ "$_plain_version" = *_8.0 ]] || [[ "$_plain_version" = *_9.0 ]]; then
      CFLAGS+=" -I/usr/lib/i386-linux-gnu/glib-2.0/include -I/usr/include/glib-2.0 -I/usr/include/gstreamer-1.0 -I/usr/lib/i386-linux-gnu/gstreamer-1.0/include"
      CROSSCFLAGS+=" -I/usr/lib/i386-linux-gnu/glib-2.0/include -I/usr/include/glib-2.0 -I/usr/include/gstreamer-1.0 -I/usr/lib/i386-linux-gnu/gstreamer-1.0/include"
    fi
  else
    export PKG_CONFIG_PATH='/usr/lib/pkgconfig:/usr/share/pkgconfig' # Pretty common path, possibly helpful for OpenSuse & Fedora
    # Workaround for Fedora freetype2 libs not being detected now that it's been moved to a subdir
    CFLAGS+=" -I/usr/include/freetype2"
    CROSSCFLAGS+=" -I/usr/include/freetype2"
    if [[ "$_plain_version" = *_8.0 ]] || [[ "$_plain_version" = *_9.0 ]]; then
      CFLAGS+=" -I/usr/lib/glib-2.0/include -I/usr/include/glib-2.0 -I/usr/include/gstreamer-1.0 -I/usr/lib/gstreamer-1.0/include"
      CROSSCFLAGS+=" -I/usr/lib/glib-2.0/include -I/usr/include/glib-2.0 -I/usr/include/gstreamer-1.0 -I/usr/lib/gstreamer-1.0/include"
    fi
  fi
}

_configure_32() {
  msg2 'Configuring Wine-32...'
  cd "${srcdir}/${pkgname}"-32-build
  if [ "$_NUKR" != "debug" ] || [[ "$_DEBUGANSW3" =~ [yY] ]]; then
    if [ "$_NOLIB64" = "true" ]; then
      ../"${_winesrcdir}"/configure \
        --prefix="$_prefix" \
        "${_configure_args32[@]}" \
        "${_configure_args[@]}"
    else
      ../"${_winesrcdir}"/configure \
        --prefix="$_prefix" \
        "${_configure_args32[@]}" \
        "${_configure_args[@]}" \
        --with-wine64="${srcdir}/${pkgname}"-64-build
    fi
  fi
  if [ "$_pkg_strip" != "true" ]; then
    msg2 "Disable strip"
    sed 's|STRIP = strip|STRIP =|g' "${srcdir}/${pkgname}"-32-build/Makefile -i
  fi
}

_build_32() {
  msg2 'Building Wine-32...'
  cd "${srcdir}/${pkgname}"-32-build
  if [ "$_SINGLE_MAKE" = 'true' ]; then
    MAKEFLAGS="${MFLAGS#-j* }"
    exec "$@"
  elif [ "$_LOCAL_OPTIMIZED" = 'true' ]; then
    # make using all available threads
    if [ "$_log_errors_to_file" = "true" ]; then
      make -j$(nproc) 2>"$_where/debug.log"
    else
      #_buildtime32=$( time ( make -j$(nproc) 2>&1 ) 3>&1 1>&2 2>&3 ) - Bash 5.2 is frogged - https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1018727
      make -j$(nproc)
    fi
  else
    # make using makepkg settings
    if [ "$_log_errors_to_file" = "true" ]; then
      make 2>"$_where/debug.log"
    else
      #_buildtime32=$( time ( make 2>&1 ) 3>&1 1>&2 2>&3 ) - Bash 5.2 is frogged - https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1018727
      make
    fi
  fi
}
