#!/usr/bin/env bash
# _output_common.sh — Common output helpers for looni-build shell scripts.
#
# Source this AFTER setting your color variables. Expects these variables
# to be set by the caller:
#   C_R (or _R)  — reset/normal
#   C_B (or _B)  — bold
#   C_GRN         — green (for success/ok)
#   C_BLU         — blue   (for sub-messages)
#   C_YLW         — yellow (for warnings)
#   C_RED         — red    (for errors)
#   C_CYN         — cyan   (for section headers)
#   C_MAG         — magenta (for banner/titles)
#   C_DIM         — dim    (for secondary text)
#
# If a shorter underscore-prefixed naming scheme is used (_R, _GRN, etc.),
# those names are tried as fallback.
#
# Usage:
#   # Define colors first (any of the two schemes)
#   if [ -t 1 ] && ...; then
#       C_R="\033[0m" C_B="\033[1m"
#       C_GRN="\033[1;32m" C_BLU="\033[1;34m"
#       ...
#   else
#       C_R="" C_B="" ... ; fi
#
#   # Then source the common helpers
#   SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
#   . "${SELF_DIR}/_output_common.sh"

# ── Resolve color variable names ────────────────────────────────────────
# Prefer C_* scheme; fall back to _* scheme for scripts that use that.
__r="${C_R:-${_R:-}}"
__b="${C_B:-${_B:-}}"
__grn="${C_GRN:-${_GRN:-}}"
__blu="${C_BLU:-${_BLU:-}}"
__ylw="${C_YLW:-${_YLW:-}}"
__red="${C_RED:-${_RED:-}}"
__cyn="${C_CYN:-${_CYN:-}}"
__mag="${C_MAG:-${_MAG:-}}"
__dim="${C_DIM:-${_DIM:-}}"

# ── Message functions ───────────────────────────────────────────────────
# These check if the color is non-empty so they work even when colors are
# disabled (empty strings).

msg()     { printf "${__grn}==> ${__r}${__b}%s${__r}\n" "$*"; }
msg2()    { printf "${__blu} -> ${__r}%s\n" "$*"; }
ok()      { printf "${__grn} ✓  ${__r}%s\n" "$*"; }
warn()    { printf "${__ylw}warn${__r} %s\n" "$*" >&2; }
err()     { printf "${__red}ERR!${__r} %s\n" "$*" >&2; exit 1; }
dim()     { printf "${__dim}%s${__r}\n" "$*"; }
section() { printf "\n${__cyn}${__b}── %s ──${__r}\n" "$*"; }
sep()     { section "$@"; }  # alias used by build-core scripts

# ── Additional helpers used by wine-builder / neutron-builder ───────────
run()     { printf "${__blu}    \$${__r} %s\n" "$*"; [ "${DRY_RUN:-0}" -eq 1 ] || "$@"; }