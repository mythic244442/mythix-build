#!/usr/bin/env bash
# ╔═════════════════════════════════════════════════════════════════════════════╗
# ║            mythix-neutron_builder  •  multi-component  v1.0.0               ║
# ║   WineHQ  •  proton-wine  •  DXVK  •  VKD3D-Proton  •  Steam package      ║
# ╚═════════════════════════════════════════════════════════════════════════════╝
#
# Entry point for building a custom Neutron compatibility tool for Steam.
#
# Phase 1 (this release):
#   • proton-wine  — Valve's Wine fork, compiled with --with-mingw + Proton flags
#   • Packaging    — Steam-loadable Neutron layout (compatibilitytool.vdf etc.)
#
# Components:
#   • DXVK        — D3D9/10/11 → Vulkan (neutron-dxvk-build.sh)
#   • VKD3D-Proton — D3D12 → Vulkan (neutron-vkd3d-build.sh)
#
# Usage:  ./neutron-builder.sh [options]
#         ./neutron-builder.sh --help
#
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# ══════════════════════════════════════════════════════════════════════════════
#  Path resolution — works from both the source tree and after `make install`
#
#  Source tree layout:
#    mythix-neutron_builder/
#      neutron-builder.sh        ← this script
#      neutron-build-core.sh     ← engine scripts alongside it
#      neutron-customization.cfg ← config alongside it
#      buildz/                   ← build output
#      src/                      ← git clones
#
#  Installed layout (make install PREFIX=~/.local):
#    ~/.local/bin/neutron-builder                   ← this script
#    ~/.local/lib/mythix-neutron_builder/*.sh        ← engine scripts
#    ~/.config/mythix-build/*.cfg                    ← config
#    ~/.local/share/mythix-neutron_builder/          ← build output + git clones
# ══════════════════════════════════════════════════════════════════════════════
if [ -f "${SCRIPT_DIR}/neutron-build-core.sh" ]; then
    # Running directly from the source tree — lib scripts are alongside us,
    # but data (build output, git clones) always goes to the XDG data dir so
    # builds never accumulate inside the git repo.
    _LIB_DIR="$SCRIPT_DIR"
    _CFG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/mythix-build"
    _DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/mythix-neutron_builder"
elif [ -f "${SCRIPT_DIR}/../lib/mythix-neutron_builder/neutron-build-core.sh" ]; then
    # Running from an installed bin/ directory
    _LIB_DIR="$(cd "${SCRIPT_DIR}/../lib/mythix-neutron_builder" && pwd)"
    _CFG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/mythix-build"
    _DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/mythix-neutron_builder"
else
    printf "ERR! Cannot locate engine scripts.\n" >&2
    printf "     Expected alongside this script or in ../lib/mythix-neutron_builder/\n" >&2
    printf "     Run from the source tree, or install with: make install\n" >&2
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Colour & output helpers
# ══════════════════════════════════════════════════════════════════════════════
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
    C_R="\033[0m" C_B="\033[1m"
    C_GRN="\033[1;32m" C_BLU="\033[1;34m"
    C_YLW="\033[1;33m" C_RED="\033[1;31m"
    C_CYN="\033[1;35m" C_MAG="\033[1;36m"
    C_DIM="\033[2m"
else
    C_R="" C_B="" C_GRN="" C_BLU="" C_YLW="" C_RED="" C_CYN="" C_MAG="" C_DIM=""
fi

# ── Resolve _LIB_DIR early so we can source _output_common.sh from it ────
if [ -f "${SCRIPT_DIR}/neutron-build-core.sh" ]; then
    _LIB_DIR="$SCRIPT_DIR"
elif [ -f "${SCRIPT_DIR}/../lib/mythix-neutron_builder/neutron-build-core.sh" ]; then
    _LIB_DIR="$(cd "${SCRIPT_DIR}/../lib/mythix-neutron_builder" && pwd)"
else
    _LIB_DIR=""
fi

# Source common output helpers (uses the C_* color variables set above)
if [ -n "$_LIB_DIR" ] && [ -f "${_LIB_DIR}/_output_common.sh" ]; then
    . "${_LIB_DIR}/_output_common.sh"
elif [ -f "${SCRIPT_DIR}/_output_common.sh" ]; then
    . "${SCRIPT_DIR}/_output_common.sh"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Banner
# ══════════════════════════════════════════════════════════════════════════════
print_banner() {
    printf "\n${C_MAG}${C_B}"
    cat << 'WOLF'
                     ____________________
                _____   ..            .  _____
             ///.         .     .+            \\\
           //              |\     /\            .\\\
         //  .     .       |#\\  /##\               \\
       //.      +   .     |####_/#/##|  .             \
      (       .   .+     /###::##//###|     .     +.  .))
    (( +. .   +       /////:::########|   .   .  ..      )
   (   .          .///################|    .   .     +    )
   (      . ..    |/############\######\\               . )
  ( .     .   ___//:\\<o<#####\::\#####\\_\   .++          )
  (      ____/###############:##\\\\###\\#\|   ..          )
  ( ..   |################::#:\\#\:\#####\#\\   .           )
  (       \\#############:\\:\\\\\\:###:\\#\|      ..       )
  ( .       \'''''''#######///\\\\\#\:\\\##:#|         ..   )
  (                 |#######:#######\\########|      .     )
  (                 |:/#/::/:#:##\::##########\|       +   )
   (        .      |////////://##/########:\#:#|     +*   )
   (  .            |:/#///////:/:##########\\:##\ .       )
    ((        .    |/#/://///:##################\| +.    )
      (+      .    \/////#/:/::#####\#########\::\\    ))
       \           |/:#####/////////########::\\###|  /
        \\   +     |:########//:/#########\\:##:\#\<//
          \\\     |/#:/:##################/###/##///
             \\\   |##//\####################////
                ----|###/:################----
                    ----------------------
          __  ____     _______ _    _ _______   __
         |  \/  \ \   / /__   __| |  | |_   _\ \ / /
         | \  / |\ \_/ /   | |  | |__| | | |  \ V /
         | |\/| | \   /    | |  |  __  | | |   > <
         | |  | |  | |     | |  | |  | |_| |_ / . \
         |_|  |_|  |_|     |_|  |_|  |_|_____/_/ \_\
WOLF
    printf "\n"
    printf "  ╔═══════════════════════════════════════════════════════════════╗\n"
    printf "  ║                                                               ║\n"
    printf "  ║  🎮  mythix-neutron_builder  •  multi-component v1.0.0         ║\n"
    printf "  ║      proton-wine  •  DXVK  •  VKD3D-Proton  •  package        ║\n"
    printf "  ║                                                               ║\n"
    printf "  ╚═══════════════════════════════════════════════════════════════╝\n"
    printf "${C_R}\n"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Phase modules — sourced in order; everything below runs in this shell.
#
#    lib/     shared definitions: catalogues, CLI parsing, profiles, preflight,
#             container handoff, fetch helpers, Wine prep, interactive pickers
#    phases/  the build pipeline itself, executed top to bottom:
#             setup → fetch wine → patch extras → fetch components →
#             build wine → build components → package
# ══════════════════════════════════════════════════════════════════════════════
_NEUTRON_MODULES=(
    lib/10-catalogue.sh
    lib/20-cli.sh
    lib/30-profiles.sh
    lib/40-preflight.sh
    lib/50-container.sh
    lib/60-fetch.sh
    lib/70-wine-prep.sh
    lib/80-pickers.sh
    phases/10-setup.sh
    phases/20-fetch-wine.sh
    phases/30-patch-extras.sh
    phases/40-fetch-components.sh
    phases/50-build-wine.sh
    phases/60-build-components.sh
    phases/70-package.sh
)
for _m in "${_NEUTRON_MODULES[@]}"; do
    [ -f "${_LIB_DIR}/${_m}" ] || err "Phase module missing: ${_LIB_DIR}/${_m}
     Reinstall with: make install-neutron"
    # shellcheck source=/dev/null
    . "${_LIB_DIR}/${_m}"
done
