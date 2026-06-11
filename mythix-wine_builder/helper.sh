#!/usr/bin/env bash
# helpers.sh
# Small, well-tested helpers extracted from prepare.sh to improve config loading,
# patch application, autoreconf fixes, temp-state and clean exit handling.
# Source this file from your build script: . /path/to/helpers.sh

set -u

# ---- logging helpers ----
msg2()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warning(){ printf '\033[1;33mWARN:\033[0m %s\n' "$*"; }
error()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*"; }

# ---- basic environment that callers should set ----
# _where : build script directory (defaults to cwd)
# srcdir : where sources are checked out
# _winesrcdir : subdir name of wine source inside srcdir
# _proton_tkg_path : optional path for proton token handling
: "${_where:=${PWD}}"
: "${srcdir:=${PWD}}"
: "${_winesrcdir:=wine-valve}"

# ---- temp / state helpers ----
# persist a simple key=value override to $_where/temp to avoid re-prompts
save_temp() {
  # usage: save_temp "KEY=value"
  local kv="$1"
  mkdir -p "$_where"
  # ensure atomic write
  printf '%s\n' "$kv" > "$_where"/temp.tmp && mv -f "$_where"/temp.tmp "$_where"/temp
}
load_temp() {
  [ -f "$_where"/temp ] && # shellcheck disable=SC1090
    source "$_where"/temp
}

# ---- safe quote-stripping for values coming from cfg files ----
strip_surrounding_quotes() {
  local v="$1"
  # trim whitespace
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    \"*\" ) v="${v#\"}"; v="${v%\"}" ;;
    \'*\' ) v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s' "$v"
}

# ---- config loader (robust precedence) ----
# precedence: proton token -> external cfg -> local customization.cfg
load_config() {
  # optional args: path_to_custom_cfg, path_to_external_cfg
  local custom_cfg="${1:-$_where/customization.cfg}"
  local external_cfg="${2:-${_EXT_CONFIG_PATH:-}}"

  if [ -f "$_where/proton_tkg_token" ] && [ -n "${_proton_tkg_path:-}" ] && [ -f "${_proton_tkg_path}/proton-tkg.cfg" ]; then
    msg2 "Loading config from proton token and proton-tkg.cfg"
    # shellcheck disable=SC1090
    source "$_where/proton_tkg_token"
    # shellcheck disable=SC1090
    source "${_proton_tkg_path}/proton-tkg.cfg"
  elif [ -n "$external_cfg" ] && [ -f "$external_cfg" ]; then
    msg2 "Loading external config: $external_cfg"
    # shellcheck disable=SC1090
    source "$external_cfg"
  elif [ -f "$custom_cfg" ]; then
    msg2 "Loading local customization: $custom_cfg"
    # shellcheck disable=SC1090
    source "$custom_cfg"
  else
    warning "No configuration file found at $custom_cfg; continuing with defaults."
  fi

  # user overrides
  if [ -f "$_where/wine-tkg-userpatches/user.cfg" ]; then
    msg2 "Loading user.cfg"
    # shellcheck disable=SC1090
    source "$_where/wine-tkg-userpatches/user.cfg"
  fi

  # persist interactive choice if any
  load_temp
}

# ---- simple patchpath loader ----
# _patchpathes must be set as an array before calling
_patchpathloader() {
  local _pp
  for _pp in "${_patchpathes[@]:-}"; do
    if [ -f "$_pp" ]; then
      msg2 "Sourcing patch metadata: $_pp"
      # shellcheck disable=SC1090
      source "$_pp"
    elif [ -d "$_pp" ]; then
      # support a directory that contains an apply script or .patch files
      if [ -x "$_pp/apply" ]; then
        msg2 "Running apply script in $_pp"
        ( cd "$_pp" && ./apply )
      else
        # apply any .patch file in alphabetical order
        for p in "$_pp"/*.patch; do
          [ -e "$p" ] || continue
          msg2 "Applying patch $p"
          if ! patch -Np1 < "$p" >> "$_where/prepare.log" 2>&1; then
            error "Failed applying patch $p (see $ _where/prepare.log)"
            return 1
          fi
        done
      fi
    else
      warning "Patch path not found: $_pp"
    fi
  done
  unset _patchpathes
  return 0
}

# ---- user patch helper (apply and revert) ----
# user_patcher <ext> <target-name>
# ext example: my, mystaging, mylate
user_patcher() {
  local ext="${1:?missing ext}" target="${2:-user}"
  local -a _patches
  IFS=$'\n' read -r -d '' -a _patches < <(printf '%s\0' "$_where"/*."${ext}" 2>/dev/null) || true
  if [ "${#_patches[@]}" -eq 0 ]; then
    return 0
  fi

  msg2 "Found ${#_patches[@]} userpatch(es) for ${target}"
  for _f in "${_patches[@]}"; do
    [ -e "$_f" ] || continue
    msg2 "Applying user patch: ${_f##*/}"
    if ! patch -Np1 < "$_f" >> "$_where/prepare.log" 2>&1; then
      error "Patch ${_f##*/} failed. See $_where/prepare.log"
      return 1
    fi
    printf 'Applied user patch %s\n' "${_f##*/}" >> "$_where/last_build_config.log"
  done
  return 0
}

# ---- update configure (autoreconf + optional small sed fix) ----
update_configure() {
  local _file=./configure
  if [ ! -f "$_file" ]; then
    warning "No configure file to update."
    return 0
  fi

  cp -a "$_file" "$_file.old" || { error "failed to create $_file.old"; return 1; }
  if ! autoreconf -f; then
    mv -f "$_file.old" "$_file" 2>/dev/null || true
    error "autoreconf failed"
    return 1
  fi

  # Small LARGE_OFF_T replacement to avoid problematic expression on older autoconf
  sed -i'' -e "s|^#define LARGE_OFF_T .*|#define LARGE_OFF_T (((off_t) 1 << 62) - 1 + ((off_t) 1 << 62))|g" "$_file"

  if cmp -s "$_file.old" "$_file"; then
    mv -f "$_file.old" "$_file"
  else
    rm -f "$_file.old"
  fi
  return 0
}

# ---- exit cleanup (portable) ----
# Provide hooks via global vars before sourcing helpers:
#   _cleanup_reset_pkgver=true  -> resets pkgver in $_where/PKGBUILD to 0 on exit if non-zero
#   _cleanup_remove_temp=true   -> removes $_where/temp
#   _cleanup_remove_patches=true-> removes temporary patch files in $_where
_exit_cleanup() {
  local pkgfile="$_where/PKGBUILD"
  if [ "${_cleanup_reset_pkgver:-false}" = "true" ] && [ -f "$pkgfile" ]; then
    # attempt to reset pkgver to 0 if we edited it
    sed -n '1,200p' "$pkgfile" >/dev/null 2>&1 || true
    # Best-effort: replace line starting with pkgver= but only if it's not 0
    awk 'BEGIN{FS=OFS=FS} /^pkgver=/ { if ($0 !~ /pkgver=0/) { print "pkgver=0"; next } } {print}' "$pkgfile" > "$pkgfile.tmp" 2>/dev/null && mv -f "$pkgfile.tmp" "$pkgfile" || true
  fi

  if [ "${_cleanup_remove_temp:-true}" = "true" ]; then
    rm -f "$_where/temp"
  fi

  if [ "${_cleanup_remove_patches:-false}" = "true" ]; then
    rm -f "$_where"/*.patch "$_where"/*.my* "$_where"/*.orig "$_where"/*.rej 2>/dev/null || true
  fi

  # optional build time logging (if set by caller)
  if [ -n "${_buildtime64:-}" ]; then
    msg2 "64-bit build time: ${_buildtime64}"
  fi
  if [ -n "${_buildtime32:-}" ]; then
    msg2 "32-bit build time: ${_buildtime32}"
  fi
}

# Install trap for callers (idempotent)
install_cleanup_trap() {
  # Only install once
  if [ -z "${_helpers_trap_installed:-}" ]; then
    trap _exit_cleanup EXIT
    _helpers_trap_installed=1
  fi
}

# ---- small utility to write last_build_config.log header ----
write_build_log_header() {
  mkdir -p "$_where"
  {
    printf '# Last build configuration - %s\n\n' "$(date)"
    printf 'Working dir: %s\n' "$_where"
    printf 'SRC dir: %s\n' "$srcdir"
    printf 'Wine source subdir: %s\n\n' "$_winesrcdir"
  } > "$_where/last_build_config.log"
}

# ---- export functions for interactive sourcing ----
export -f msg2 warning error
export -f save_temp load_temp strip_surrounding_quotes
export -f load_config _patchpathloader user_patcher update_configure
export -f _exit_cleanup install_cleanup_trap write_build_log_header

# Helpful micro-usage note when sourced
: <<'USAGE'
To use:
  . /path/to/helpers.sh
  install_cleanup_trap
  load_config "/path/to/customization.cfg" "/path/to/external.cfg"
  write_build_log_header
  # set _patchpathes=( "path/to/patch1" "path/to/patchdir" ) and then:
  _patchpathloader
  # apply user patches:
  user_patcher "my" "plain-wine"
  # update configure if needed:
  update_configure
  # persist a choice:
  save_temp "_LOCAL_PRESET='valve-exp'"
USAGE
