#!/usr/bin/env bash
# ╔═════════════════════════════════════════════════════════════════════════════╗
# ║                    mythix-build  •  main launcher  v1.0.0                   ║
# ║           Wine  •  Neutron  •  Proton  •  Hybrid  •  Toolz                  ║
# ╚═════════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# ── Path resolution ───────────────────────────────────────────────────────────
# Finds sibling scripts whether running from the source tree or after make install
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

_find_tool() {
    local name="$1"
    local _bin

    # 1. Installed layout: tool is a sibling binary in the same bin/ directory
    _bin="${SCRIPT_DIR}/${name}"
    [ -x "$_bin" ] && { echo "$_bin"; return; }

    # 2. Source tree layout: each tool lives in its own subdirectory
    case "$name" in
        wine-builder)       _bin="${SCRIPT_DIR}/mythix-wine_builder/wine-builder.sh" ;;
        neutron-builder)    _bin="${SCRIPT_DIR}/mythix-neutron_builder/neutron-builder.sh" ;;
        neutron-install)    _bin="${SCRIPT_DIR}/mythix-neutron-install/neutron-install.sh" ;;
        proton-builder)     _bin="${SCRIPT_DIR}/mythix-proton_builder/proton-builder.sh" ;;
        proton-install)     _bin="${SCRIPT_DIR}/mythix-proton-install/proton-install.sh" ;;
        wine-proton_hybrid)  _bin="${SCRIPT_DIR}/mythix-wine-proton_hybrid_builder/wine-proton_hybrid-v1.0.0.sh" ;;
        wine-neutron_hybrid) _bin="${SCRIPT_DIR}/mythix-wine-neutron_hybrid_builder/wine-neutron_hybrid-v1.0.0.sh" ;;
        wine_toolz)         _bin="${SCRIPT_DIR}/mythix-winetoolz/wine_toolz.sh" ;;
        wine_install_mgr)   _bin="${SCRIPT_DIR}/mythix-winetoolz/modules/shared_lib/wine_install_manager.sh" ;;
    esac
    [ -x "$_bin" ] && { echo "$_bin"; return; }

    # 3. Installed lib layout: make install puts modules under prefix/lib/
    #    (SCRIPT_DIR is bin/; strip /bin to get prefix, then look in lib/)
    local _lib="${SCRIPT_DIR%/bin}/lib"
    case "$name" in
        neutron-install)  _bin="${_lib}/mythix-neutron-install/neutron-install.sh" ;;
        proton-builder)   _bin="${_lib}/mythix-proton_builder/proton-builder.sh" ;;
        proton-install)   _bin="${_lib}/mythix-proton-install/proton-install.sh" ;;
        wine_toolz)       _bin="${_lib}/mythix-winetoolz/wine_toolz.sh" ;;
        wine_install_mgr) _bin="${_lib}/mythix-winetoolz/modules/shared_lib/wine_install_manager.sh" ;;
    esac
    [ -x "$_bin" ] && { echo "$_bin"; return; }

    echo ""
}

# ── Colours ───────────────────────────────────────────────────────────────────
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
    C_R="\033[0m" C_B="\033[1m"
    C_MAG="\033[1;36m" C_CYN="\033[1;35m" C_DIM="\033[2m"
else
    C_R="" C_B="" C_MAG="" C_CYN="" C_DIM=""
fi

# ── Banner ────────────────────────────────────────────────────────────────────
clear
printf "\n${C_MAG}${C_B}"
cat << 'WOLF'
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠸⠁⠸⢳⡄⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢠⠃⠀⠀⢸⠸⠀⡠⣄⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡠⠃⠀⠀⢠⣞⣀⡿⠀⠀⣧⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣠⡖⠁⠀⠀⠀⢸⠈⢈⡇⠀⢀⡏⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⡴⠩⢠⡴⠀⠀⠀⠀⠀⠈⡶⠉⠀⠀⡸⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⢀⠎⢠⣇⠏⠀⠀⠀⠀⠀⠀⠀⠁⠀⢀⠄⡇⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⢠⠏⠀⢸⣿⣴⠀⠀⠀⠀⠀⠀⣆⣀⢾⢟⠴⡇⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⢀⣿⠀⠠⣄⠸⢹⣦⠀⠀⡄⠀⠀⢋⡟⠀⠀⠁⣇⠀⠀⠀⠀⠀
⠀⠀⠀⠀⢀⡾⠁⢠⠀⣿⠃⠘⢹⣦⢠⣼⠀⠀⠉⠀⠀⠀⠀⢸⡀⠀⠀⠀⠀
⠀⠀⢀⣴⠫⠤⣶⣿⢀⡏⠀⠀⠘⢸⡟⠋⠀⠀⠀⠀⠀⠀⠀⠀⢳⠀⠀⠀⠀
⠐⠿⢿⣿⣤⣴⣿⣣⢾⡄⠀⠀⠀⠀⠳⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢣⠀⠀⠀
⠀⠀⠀⣨⣟⡍⠉⠚⠹⣇⡄⠀⠀⠀⠀⠀⠀⠀⠀⠈⢦⠀⠀⢀⡀⣾⡇⠀⠀
⠀⠀⢠⠟⣹⣧⠃⠀⠀⢿⢻⡀⢄⠀⠀⠀⠀⠐⣦⡀⣸⣆⠀⣾⣧⣯⢻⠀⠀
⠀⠀⠘⣰⣿⣿⡄⡆⠀⠀⠀⠳⣼⢦⡘⣄⠀⠀⡟⡷⠃⠘⢶⣿⡎⠻⣆⠀⠀
⠀⠀⠀⡟⡿⢿⡿⠀⠀⠀⠀⠀⠙⠀⠻⢯⢷⣼⠁⠁⠀⠀⠀⠀⠀⡄⡈⢆⠀
⠀⠀⠀⠀⡇⣿⡅⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠙⠦⠀⠀⠀⠀⠀⠀⡇⢹⢿⡀
⠀⠀⠀⠀⠁⠛⠓⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠼⠇⠁
WOLF
printf "\n"
printf "  ╔═════════════════════════════════════════════════════════════════╗\n"
printf "  ║                                                                 ║\n"
printf "  ║  :3 mythix-build  •  Wine, Neutron & Proton toolkit  v1.0.0     ║\n"
printf "  ║                                                                 ║\n"
printf "  ╚═════════════════════════════════════════════════════════════════╝\n"
printf "${C_R}\n"

# ── Tool catalogue ────────────────────────────────────────────────────────────
declare -A TOOL_KEY TOOL_DESC
TOOL_KEY=(
    [1]="wine-builder"
    [2]="neutron-builder"
    [3]="proton-builder"
    [4]="wine-proton_hybrid"
    [5]="wine-neutron_hybrid"
    [6]="wine_install_mgr"
    [7]="neutron-install"
    [8]="proton-install"
    [9]="wine_toolz"
)
TOOL_DESC=(
    [1]="🛠  wine-builder          — build Wine from source (mainline, staging, TKG, Valve…)"
    [2]="🎮  neutron-builder       — build Neutron (WineHQ, Valve, Kron4ek, staging…)"
    [3]="🔧  proton-builder        — build Proton from source (GE, TKG build scripts…)"
    [4]="⇌   wine-proton_hybrid    — merge any Wine build over a Proton base"
    [5]="⇌   wine-neutron_hybrid   — merge any Wine build over a Neutron base"
    [6]="📦  wine_install_mgr      — install, switch, and manage custom Wine builds"
    [7]="🚀  neutron-install       — deploy Neutron packages to Steam"
    [8]="🚀  proton-install        — download & deploy GE-Proton / pre-built Proton to Steam"
    [9]="⚙   wine_toolz            — GUI Wine toolkit (DXVK, prefixes, runtimes…)"
)
TOOL_KEYS=( wine-builder neutron-builder proton-builder wine-proton_hybrid wine-neutron_hybrid wine_install_mgr neutron-install proton-install wine_toolz )

# ── Launch + menu loop ────────────────────────────────────────────────────────
_launch() {
    local key="$1"
    local tool_bin
    tool_bin="$(_find_tool "$key")"
    if [ -z "$tool_bin" ]; then
        printf "\n${C_MAG}  ✖  Could not find: %s${C_R}\n" "$key"
        printf "  ${C_DIM}Make sure mythix-build is installed (make install) or run from the repo root.${C_R}\n\n"
        printf "  ${C_DIM}Press Enter to return to the menu...${C_R}"
        read -r
        return
    fi
    # Clear the terminal before each tool so its own banner starts clean
    clear
    # Ignore SIGINT in this (parent) shell while the child runs.
    # Ctrl+C will still kill the child tool, but mythix-build stays alive
    # and loops back to the menu instead of exiting entirely.
    # Also disable errexit — a non-zero child exit (e.g. code 130 from
    # Ctrl+C, or user pressing Esc) must not propagate to this launcher.
    trap '' INT
    set +e
    bash "$tool_bin"
    local _exit=$?
    set -e
    trap - INT   # restore default SIGINT handling
    if [ "$_exit" -ne 0 ] && [ "$_exit" -ne 130 ]; then
        # 130 = killed by SIGINT (Ctrl+C) — no need to print an error for that
        printf "\n${C_MAG}  ✖  %s exited with code %d.${C_R}\n" "$key" "$_exit"
        printf "  ${C_DIM}Press Enter to return to the menu...${C_R}"
        read -r _pause 2>/dev/null || true
    fi
}

_build_menu_input() {
    for k in "${TOOL_KEYS[@]}"; do
        for idx in "${!TOOL_KEY[@]}"; do
            if [ "${TOOL_KEY[$idx]}" = "$k" ]; then
                printf '%s\t%s\n' "$k" "${TOOL_DESC[$idx]}"
            fi
        done
    done
    printf 'exit\t  ←  exit mythix-build\n'
}

while true; do
    if command -v fzf >/dev/null 2>&1; then
        picked=$(
            _build_menu_input             | fzf \
                --prompt="mythix-build > " \
                --header="Select a tool  (Esc or ← exit to quit)" \
                --with-nth=2 \
                --delimiter=$'\t' \
                --height=22% \
                --border \
                --border-label=" mythix-build " \
                --border-label-pos=3 \
            || true
        )
        [ -z "$picked" ] && { printf "\n  ${C_DIM}Goodbye :3${C_R}\n\n"; exit 0; }
        key="$(printf '%s' "$picked" | cut -d$'\t' -f1)"
    else
        # Fallback: numbered menu
        printf "  ${C_B}Select a tool:${C_R}\n\n"
        for idx in 1 2 3 4 5 6 7 8 9; do
            printf "  ${C_CYN}%d)${C_R} %s\n" "$idx" "${TOOL_DESC[$idx]}"
        done
        printf "  ${C_CYN}q)${C_R}  Exit\n"
        printf "\n  ${C_B}Choice [1-9, q]:${C_R} "
        read -r _choice
        case "$_choice" in
            1|2|3|4|5|6|7|8|9) key="${TOOL_KEY[$_choice]}" ;;
            q|Q|"")  printf "\n  ${C_DIM}Goodbye :3${C_R}\n\n"; exit 0 ;;
            *) printf "\n  ${C_MAG}Invalid choice.${C_R}\n\n"; continue ;;
        esac
    fi

    case "$key" in
        exit) printf "\n  ${C_DIM}Goodbye :3${C_R}\n\n"; exit 0 ;;
        *)    _launch "$key" ;;
    esac

    # Clear and redraw banner before looping back
    clear
    printf "\n${C_MAG}${C_B}"
    cat << 'WOLF'
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠸⠁⠸⢳⡄⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢠⠃⠀⠀⢸⠸⠀⡠⣄⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡠⠃⠀⠀⢠⣞⣀⡿⠀⠀⣧⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣠⡖⠁⠀⠀⠀⢸⠈⢈⡇⠀⢀⡏⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⡴⠩⢠⡴⠀⠀⠀⠀⠀⠈⡶⠉⠀⠀⡸⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⢀⠎⢠⣇⠏⠀⠀⠀⠀⠀⠀⠀⠁⠀⢀⠄⡇⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⢠⠏⠀⢸⣿⣴⠀⠀⠀⠀⠀⠀⣆⣀⢾⢟⠴⡇⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⢀⣿⠀⠠⣄⠸⢹⣦⠀⠀⡄⠀⠀⢋⡟⠀⠀⠁⣇⠀⠀⠀⠀⠀
⠀⠀⠀⠀⢀⡾⠁⢠⠀⣿⠃⠘⢹⣦⢠⣼⠀⠀⠉⠀⠀⠀⠀⢸⡀⠀⠀⠀⠀
⠀⠀⢀⣴⠫⠤⣶⣿⢀⡏⠀⠀⠘⢸⡟⠋⠀⠀⠀⠀⠀⠀⠀⠀⢳⠀⠀⠀⠀
⠐⠿⢿⣿⣤⣴⣿⣣⢾⡄⠀⠀⠀⠀⠳⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢣⠀⠀⠀
⠀⠀⠀⣨⣟⡍⠉⠚⠹⣇⡄⠀⠀⠀⠀⠀⠀⠀⠀⠈⢦⠀⠀⢀⡀⣾⡇⠀⠀
⠀⠀⢠⠟⣹⣧⠃⠀⠀⢿⢻⡀⢄⠀⠀⠀⠀⠐⣦⡀⣸⣆⠀⣾⣧⣯⢻⠀⠀
⠀⠀⠘⣰⣿⣿⡄⡆⠀⠀⠀⠳⣼⢦⡘⣄⠀⠀⡟⡷⠃⠘⢶⣿⡎⠻⣆⠀⠀
⠀⠀⠀⡟⡿⢿⡿⠀⠀⠀⠀⠀⠙⠀⠻⢯⢷⣼⠁⠁⠀⠀⠀⠀⠀⡄⡈⢆⠀
⠀⠀⠀⠀⡇⣿⡅⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠙⠦⠀⠀⠀⠀⠀⠀⡇⢹⢿⡀
⠀⠀⠀⠀⠁⠛⠓⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠼⠇⠁
WOLF
    printf "\n"
    printf "  ╔═════════════════════════════════════════════════════════════════╗\n"
    printf "  ║                                                                 ║\n"
    printf "  ║  :3 mythix-build  •  Wine, Neutron & Proton toolkit  v1.0.0      ║\n"
    printf "  ║                                                                 ║\n"
    printf "  ╚═════════════════════════════════════════════════════════════════╝\n"
    printf "${C_R}\n"
done
