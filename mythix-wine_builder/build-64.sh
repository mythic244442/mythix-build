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
: "${_log_errors_to_file:=${_log_errors_to_file:-true}}"
: "${_SINGLE_MAKE:=${_SINGLE_MAKE:-false}}"
: "${_pkg_strip:=${_pkg_strip:-false}}"

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

# Ensure mingw fastfail is defined only once for cross compiles
: "${MINGW_FASTFAIL_DEF:='-D__MINGW_FASTFAIL_IMPL=0'}"
if ! printf '%s\n' "${CROSSCFLAGS:-} ${CROSSCPPFLAGS:-} ${CPPFLAGS:-}" | grep -q '__MINGW_FASTFAIL_IMPL'; then
  CROSSCFLAGS="${CROSSCFLAGS:-} ${MINGW_FASTFAIL_DEF}"
  CROSSCPPFLAGS="${CROSSCPPFLAGS:-} ${MINGW_FASTFAIL_DEF}"
  CPPFLAGS="${CPPFLAGS:-} ${MINGW_FASTFAIL_DEF}"
  export CROSSCFLAGS CROSSCPPFLAGS CPPFLAGS
fi

_exports_64() {
  if [ "$_NOCCACHE" != "true" ]; then
    if [ -e /usr/bin/ccache ]; then
      export CC="ccache gcc" && echo "CC = ${CC}" >>"$_LAST_BUILD_CONFIG"
      export CXX="ccache g++" && echo "CXX = ${CXX}" >>"$_LAST_BUILD_CONFIG"
    fi
    if [ -e /usr/bin/ccache ] && [ "$_NOMINGW" != "true" ]; then
      export CROSSCC="ccache x86_64-w64-mingw32-gcc" && echo "CROSSCC64 = ${CROSSCC}" >>"$_LAST_BUILD_CONFIG"
      export x86_64_CC="${CROSSCC}"

      # Required for new-style WoW64 builds (otherwise 32-bit portions won't be ccached)
      if [ "${_NOLIB32}" != "false" ]; then
        export i386_CC="ccache i686-w64-mingw32-gcc"
      fi
    fi
  fi
  # If /usr/lib32 doesn't exist (such as on Fedora), make sure we're using /usr/lib64 for 64-bit pkgconfig path
  if [ ! -d '/usr/lib32' ]; then
    export PKG_CONFIG_PATH='/usr/lib64/pkgconfig'
  fi
}

_configure_64() {
  msg2 'Configuring Wine-64...'
  cd "${srcdir}"/"${pkgname}"-64-build
  if [ "$_NUKR" != "debug" ] || [[ "$_DEBUGANSW3" =~ [yY] ]]; then
    chmod +x ../"${_winesrcdir}"/configure
    if [ "$_NOLIB32" != "wow64" ]; then
      ../"${_winesrcdir}"/configure \
        --prefix="$_prefix" \
        --enable-win64 \
        "${_configure_args64[@]}" \
        "${_configure_args[@]}"
    else
      ../"${_winesrcdir}"/configure \
        --prefix="$_prefix" \
        --enable-archs=i386,x86_64 \
        "${_configure_args64[@]}" \
        "${_configure_args[@]}"
    fi
  fi
  if [ "$_pkg_strip" != "true" ]; then
    msg2 "Disable strip"
    sed 's|STRIP = strip|STRIP =|g' "${srcdir}/${pkgname}"-64-build/Makefile -i
  fi
}

# Needed for _SINGLE_MAKE build
_tools_64() (
  msg2 'Building Wine-64 Tools...'
  shopt -s globstar
  for mkfile in tools/Makefile tools/**/Makefile; do
    "$@" -C "${mkfile%/Makefile}"
  done
)

_build_64() {
  msg2 'Building Wine-64...'
  cd "${srcdir}"/"${pkgname}"-64-build
  if [ "$_SINGLE_MAKE" = 'true' ]; then
    exec "$@"
  elif [ "$_LOCAL_OPTIMIZED" = 'true' ]; then
    # make using all available threads
    if [ "$_log_errors_to_file" = "true" ]; then
      make -j$(nproc) 2>"$_where/debug.log"
    else
      #_buildtime64=$( time ( make -j$(nproc) 2>&1 ) 3>&1 1>&2 2>&3 ) - Bash 5.2 is frogged - https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1018727
      make -j$(nproc)
    fi
  else
    # make using makepkg settings
    if [ "$_log_errors_to_file" = "true" ]; then
      make 2>"$_where/debug.log"
    else
      #_buildtime64=$( time ( make 2>&1 ) 3>&1 1>&2 2>&3 ) - Bash 5.2 is frogged - https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1018727
      make
    fi
  fi
}
