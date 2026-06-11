#!/usr/bin/env bash
# ╔═════════════════════════════════════════════════════════════════════════════╗
# ║         mythix-build  •  neutron-install  —  Neutron Package Manager       ║
# ║         Install, deploy, switch, and manage Neutron/Wine packages         ║
# ╚═════════════════════════════════════════════════════════════════════════════╝
#
# Manages Neutron packages:
#   - Install from builder output, directories, or tarballs
#   - Deploy to Steam's compatibilitytools.d
#   - Set as system Wine (symlink binaries + neutron launcher to PATH)
#   - Switch active, list, uninstall, inspect installs
#
# Usage:  neutron-install [options]
#         neutron-install --help
#
set -euo pipefail
IFS=$'\n\t'

# ══════════════════════════════════════════════════════════════════════════════
#  Colour & output helpers
# ══════════════════════════════════════════════════════════════════════════════
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
    C_R="\033[0m" C_B="\033[1m"
    C_GRN="\033[1;32m" C_BLU="\033[1;34m"
    C_YLW="\033[1;33m" C_RED="\033[1;31m"
    C_CYN="\033[1;36m" C_MAG="\033[1;35m"
    C_DIM="\033[2m"
else
    C_R="" C_B="" C_GRN="" C_BLU="" C_YLW="" C_RED="" C_CYN="" C_MAG="" C_DIM=""
fi

msg()     { printf "${C_GRN}==> ${C_R}${C_B}%s${C_R}\n" "$*"; }
msg2()    { printf "${C_BLU} -> ${C_R}%s\n" "$*"; }
ok()      { printf "${C_GRN} ✓  ${C_R}%s\n" "$*"; }
warn()    { printf "${C_YLW}warn${C_R} %s\n" "$*" >&2; }
err()     { printf "${C_RED}ERR!${C_R} %s\n" "$*" >&2; exit 1; }
section() { printf "\n${C_CYN}${C_B}── %s ──${C_R}\n" "$*"; }
dim()     { printf "${C_DIM}%s${C_R}\n" "$*"; }
run()     { printf "${C_BLU}    \$${C_R} %s\n" "$*"; [ "${DRY_RUN:-0}" -eq 1 ] || "$@"; }
sep()     { printf "\n${C_DIM}%s${C_R}\n" "$(printf '─%.0s' {1..60})"; }

# ══════════════════════════════════════════════════════════════════════════════
#  Banner
# ══════════════════════════════════════════════════════════════════════════════
print_banner() {
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
⠀⠀⠀⡟⡿⢿⡿⠀⠀⠀⠀⠀⠙⠀⠻⢯⢷⣼⠁⠁⠀⠀⠀⠙⢿⡄⡈⢆⠀
⠀⠀⠀⠀⡇⣿⡅⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠙⠦⠀⠀⠀⠀⠀⠀⡇⢹⢿⡀
⠀⠀⠀⠀⠁⠛⠓⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠼⠇⠁
WOLF
    printf "\n"
    printf "  ╔═══════════════════════════════════════════════════════════════╗\n"
    printf "  ║                                                               ║\n"
    printf "  ║  :3 mythix-build  •  neutron-install                          ║\n"
    printf "  ║      Neutron Package Manager                                 ║\n"
    printf "  ║                                                               ║\n"
    printf "  ╚═══════════════════════════════════════════════════════════════╝\n"
    printf "${C_R}\n"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Constants
# ══════════════════════════════════════════════════════════════════════════════
INSTALL_BASE="${HOME}/.local/share/mythix-neutron-installs"
SYMLINK_DIR="${HOME}/.local/bin"
META_FILE=".mythix-meta"

# Binaries to symlink into PATH
WINE_BINS=( wine wine64 wine-preloader wine64-preloader wineserver wineboot winecfg msidb msiexec regedit regsvr32 winedbg winepath )

# Directories to scan for locally-built mythix-neutron packages
LOCAL_BUILD_DIRS=(
    "${XDG_DATA_HOME:-${HOME}/.local/share}/mythix-neutron_builder/buildz/install"
    "${HOME}/.local/share/mythix-neutron_builder/buildz/install"
)

# ══════════════════════════════════════════════════════════════════════════════
#  Defaults
# ══════════════════════════════════════════════════════════════════════════════
DRY_RUN=0
COMPAT_TOOLS_DIR=""
ACTION=""
NONINTERACTIVE=0

# CLI value holders
_DEPLOY_PATH=""
_REMOVE_NAME=""
_SYSWINE_PATH=""
_INSTALL_PATH=""
_SWITCH_NAME=""

# ══════════════════════════════════════════════════════════════════════════════
#  Usage
# ══════════════════════════════════════════════════════════════════════════════
print_usage() {
    cat <<USAGE
${C_B}Usage:${C_R} $0 [options]

${C_B}Non-interactive (scriptable) flags:${C_R}
  --install [PATH]         Install a Neutron package (from builder output, dir, or tarball)
  --deploy  [PATH]         Deploy a package to Steam's compatibilitytools.d
  --system-wine [NAME]     Set a managed install as the active system Wine
  --list                   List managed Neutron installs
  --remove NAME            Remove a managed install
  --info NAME              Show details about a managed install

${C_B}Common options:${C_R}
  --compat-dir DIR         Override the auto-detected compatibilitytools.d path
  --bin-dir DIR            Override symlink directory (default: ~/.local/bin)
  --dry-run                Show what would happen without making any changes
  -h, --help               Show this help and exit

${C_B}Interactive mode (no flags):${C_R}
  Running without action flags drops into a menu (fzf or numbered fallback).

${C_B}Examples:${C_R}
  $0                                  # interactive menu
  $0 --install                        # install from builder output (interactive pick)
  $0 --install ~/builds/my-neutron/   # install from a specific directory
  $0 --deploy                         # deploy a managed install to Steam
  $0 --system-wine my-neutron         # set a managed install as system Wine
  $0 --list
  $0 --remove my-old-neutron
USAGE
}

# ══════════════════════════════════════════════════════════════════════════════
#  Argument parsing
# ══════════════════════════════════════════════════════════════════════════════
while [[ $# -gt 0 ]]; do
    case "$1" in
        --install)
            ACTION="install"; NONINTERACTIVE=1
            if [[ $# -ge 2 ]] && [[ "$2" != --* ]]; then
                _INSTALL_PATH="$2"; shift 2
            else shift; fi ;;
        --deploy)
            ACTION="deploy"; NONINTERACTIVE=1
            if [[ $# -ge 2 ]] && [[ "$2" != --* ]]; then
                _DEPLOY_PATH="$2"; shift 2
            else shift; fi ;;
        --system-wine)
            ACTION="system-wine"; NONINTERACTIVE=1
            if [[ $# -ge 2 ]] && [[ "$2" != --* ]]; then
                _SWITCH_NAME="$2"; shift 2
            else shift; fi ;;
        --list)
            ACTION="list"; NONINTERACTIVE=1; shift ;;
        --remove)
            [[ $# -ge 2 ]] || err "--remove requires a NAME argument"
            ACTION="remove"; _REMOVE_NAME="$2"; NONINTERACTIVE=1; shift 2 ;;
        --info)
            [[ $# -ge 2 ]] || err "--info requires a NAME argument"
            ACTION="info"; _SWITCH_NAME="$2"; NONINTERACTIVE=1; shift 2 ;;
        --compat-dir)
            [[ $# -ge 2 ]] || err "--compat-dir requires a PATH argument"
            COMPAT_TOOLS_DIR="$2"; shift 2 ;;
        --bin-dir)
            [[ $# -ge 2 ]] || err "--bin-dir requires a PATH argument"
            SYMLINK_DIR="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN=1; shift ;;
        -h|--help)
            print_banner; print_usage; exit 0 ;;
        *)
            printf "Unknown option: %s\n" "$1" >&2
            print_usage; exit 1 ;;
    esac
done

mkdir -p "$INSTALL_BASE" "$SYMLINK_DIR"

# ══════════════════════════════════════════════════════════════════════════════
#  Helpers
# ══════════════════════════════════════════════════════════════════════════════

_read_display_name() {
    local vdf="$1"
    [[ -f "$vdf" ]] || { printf ''; return; }
    local name
    name=$(grep -i '"display_name"' "$vdf" 2>/dev/null \
           | head -1 \
           | sed 's/.*"display_name"[[:space:]]*"\([^"]*\)".*/\1/' || true)
    printf '%s' "${name:-}"
}

# _fzf_pick <prompt> <header> [height]
#   Reads tab-delimited lines from stdin (key\tlabel).
#   Returns the selected key, or "" if cancelled.
_fzf_pick() {
    local prompt="$1" header="$2" height="${3:-25%}"
    if command -v fzf >/dev/null 2>&1; then
        local picked
        picked=$(fzf \
            --prompt="${prompt} > " \
            --header="$header" \
            --with-nth=2 \
            --delimiter=$'\t' \
            --height="$height" \
            --border \
        || true)
        [[ -n "$picked" ]] && printf '%s' "$picked" | cut -d$'\t' -f1
    else
        # Numbered fallback
        local -a keys=() labels=()
        while IFS=$'\t' read -r k l; do
            keys+=("$k"); labels+=("$l")
        done
        printf "\n" >&2
        local i
        for i in "${!labels[@]}"; do
            printf "  ${C_CYN}%d)${C_R} %s\n" "$(( i + 1 ))" "${labels[$i]}" >&2
        done
        printf "\n  ${C_B}${prompt} [1-%d]:${C_R} " "${#labels[@]}" >&2
        local _choice; read -r _choice
        if [[ "$_choice" =~ ^[0-9]+$ ]] && (( _choice >= 1 && _choice <= ${#labels[@]} )); then
            printf '%s' "${keys[$(( _choice - 1 ))]}"
        fi
    fi
}

# _fzf_multi_pick <prompt> <header>
#   Like _fzf_pick but allows multiple selections.
_fzf_multi_pick() {
    local prompt="$1" header="$2"
    if command -v fzf >/dev/null 2>&1; then
        local picked
        picked=$(fzf \
            --prompt="${prompt} > " \
            --header="$header" \
            --with-nth=2 \
            --delimiter=$'\t' \
            --height=30% \
            --border \
            --multi \
        || true)
        while IFS=$'\t' read -r k _rest; do
            [[ -n "$k" ]] && printf '%s\n' "$k"
        done <<< "$picked"
    else
        # Numbered fallback — comma-separated selection
        local -a keys=() labels=()
        while IFS=$'\t' read -r k l; do
            keys+=("$k"); labels+=("$l")
        done
        printf "\n" >&2
        local i
        for i in "${!labels[@]}"; do
            printf "  ${C_CYN}%d)${C_R} %s\n" "$(( i + 1 ))" "${labels[$i]}" >&2
        done
        printf "\n  ${C_B}${prompt} (comma-separated) [1-%d]:${C_R} " "${#labels[@]}" >&2
        local _input; read -r _input
        IFS=',' read -ra _nums <<< "$_input"
        for n in "${_nums[@]}"; do
            n="${n// /}"
            if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#labels[@]} )); then
                printf '%s\n' "${keys[$(( n - 1 ))]}"
            fi
        done
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  Metadata helpers
# ══════════════════════════════════════════════════════════════════════════════

_write_meta() {
    local dir="$1" source_desc="$2"
    local version="unknown"
    [[ -x "$dir/files/bin/wine" ]] && \
        version="$("$dir/files/bin/wine" --version 2>/dev/null | head -1 || echo "unknown")"
    [[ -x "$dir/bin/wine" ]] && [[ "$version" == "unknown" ]] && \
        version="$("$dir/bin/wine" --version 2>/dev/null | head -1 || echo "unknown")"
    cat > "$dir/$META_FILE" <<EOF
name=$(basename "$dir")
version=$version
source=$source_desc
installed=$(date '+%Y-%m-%d %H:%M')
EOF
}

_read_meta() {
    local dir="$1" field="$2"
    [[ -f "$dir/$META_FILE" ]] || { printf 'unknown'; return; }
    local val
    val=$(grep "^${field}=" "$dir/$META_FILE" 2>/dev/null | cut -d= -f2- || true)
    printf '%s' "${val:-unknown}"
}

_wine_version() {
    local dir="$1"
    # Check for Neutron package layout (files/bin/wine) and plain layout (bin/wine)
    for p in "$dir/files/bin/wine" "$dir/bin/wine"; do
        if [[ -x "$p" ]]; then
            "$p" --version 2>/dev/null | head -1 || printf 'unknown'
            return
        fi
    done
    printf 'unknown'
}

# _list_installs — print one line per managed install: name\tversion\tdate\tactive
_list_installs() {
    local active_target=""
    if [[ -L "$SYMLINK_DIR/wine" ]]; then
        active_target="$(readlink -f "$SYMLINK_DIR/wine" 2>/dev/null || true)"
    fi

    for dir in "$INSTALL_BASE"/*/; do
        [[ -d "$dir" ]] || continue
        local name; name="$(basename "$dir")"
        local version; version="$(_read_meta "$dir" "version")"
        [[ "$version" == "unknown" ]] && version="$(_wine_version "$dir")"
        local date; date="$(_read_meta "$dir" "installed")"
        local active="no"
        if [[ -n "$active_target" ]]; then
            for p in "$dir/files/bin/wine" "$dir/bin/wine"; do
                local this_wine
                this_wine="$(readlink -f "$p" 2>/dev/null || true)"
                [[ "$active_target" == "$this_wine" ]] && active="YES"
            done
        fi
        printf '%s\t%s\t%s\t%s\n' "$name" "$version" "$date" "$active"
    done
}

# ══════════════════════════════════════════════════════════════════════════════
#  Symlink management — set / clear active Wine
# ══════════════════════════════════════════════════════════════════════════════

# _find_bin_dir <install_dir> — returns the directory containing the wine binary
_find_bin_dir() {
    local dir="$1"
    if [[ -x "$dir/files/bin/wine" ]]; then
        printf '%s' "$dir/files/bin"
    elif [[ -x "$dir/bin/wine" ]]; then
        printf '%s' "$dir/bin"
    fi
}

_set_active() {
    local name="$1"
    local dir="$INSTALL_BASE/$name"
    local bin_dir; bin_dir="$(_find_bin_dir "$dir")"
    [[ -n "$bin_dir" ]] || err "No wine binary found in install: $name"

    local _linked=0
    for b in "${WINE_BINS[@]}"; do
        # Remove existing symlink if it points into our managed installs
        if [[ -L "$SYMLINK_DIR/$b" ]]; then
            local target
            target="$(readlink -f "$SYMLINK_DIR/$b" 2>/dev/null || true)"
            if [[ "$target" == "$INSTALL_BASE"/* ]]; then
                rm -f "$SYMLINK_DIR/$b"
            fi
        fi
        # Create new symlink if the binary exists
        if [[ -x "$bin_dir/$b" ]]; then
            ln -sf "$bin_dir/$b" "$SYMLINK_DIR/$b"
            (( _linked++ )) || true
        fi
    done

    # Also symlink the neutron launcher if present
    local pkg_dir="$dir"
    if [[ -x "$pkg_dir/neutron" ]]; then
        if [[ -L "$SYMLINK_DIR/neutron" ]]; then
            local target; target="$(readlink -f "$SYMLINK_DIR/neutron" 2>/dev/null || true)"
            [[ "$target" == "$INSTALL_BASE"/* ]] && rm -f "$SYMLINK_DIR/neutron"
        fi
        ln -sf "$pkg_dir/neutron" "$SYMLINK_DIR/neutron"
        (( _linked++ )) || true
    fi

    ok "Linked ${_linked} binaries in ${SYMLINK_DIR}"

    # PATH check
    case ":${PATH}:" in
        *":${SYMLINK_DIR}:"*) ;;
        *)
            warn "${SYMLINK_DIR} is not in your PATH."
            printf "  Add to your shell profile (~/.bashrc or ~/.zshrc):\n"
            printf "    ${C_B}export PATH=\"${SYMLINK_DIR}:\$PATH\"${C_R}\n"
            ;;
    esac
}

_clear_active() {
    local name="$1"
    local dir="$INSTALL_BASE/$name"
    for b in "${WINE_BINS[@]}" neutron; do
        if [[ -L "$SYMLINK_DIR/$b" ]]; then
            local target; target="$(readlink -f "$SYMLINK_DIR/$b" 2>/dev/null || true)"
            if [[ "$target" == "$dir"/* ]] || [[ "$target" == "$INSTALL_BASE/$name"/* ]]; then
                rm -f "$SYMLINK_DIR/$b"
            fi
        fi
    done
}

# ══════════════════════════════════════════════════════════════════════════════
#  Steam compatibilitytools.d discovery
# ══════════════════════════════════════════════════════════════════════════════

_COMPAT_CANDIDATES=(
    "${HOME}/.steam/steam/compatibilitytools.d"
    "${HOME}/.steam/root/compatibilitytools.d"
    "${HOME}/.steam/debian-installation/compatibilitytools.d"
    "${HOME}/.local/share/Steam/compatibilitytools.d"
    "${HOME}/.var/app/com.valvesoftware.Steam/.local/share/Steam/compatibilitytools.d"
)

_find_compat_dir() {
    if [[ -n "${STEAM_COMPAT_TOOL_PATHS:-}" ]]; then
        local IFS_SAVED="$IFS"; IFS=':'
        for p in ${STEAM_COMPAT_TOOL_PATHS}; do
            IFS="$IFS_SAVED"; p="${p%/}"
            [[ -d "$p" ]] && { printf '%s' "$p"; return; }
        done
        IFS="$IFS_SAVED"
    fi
    for p in "${_COMPAT_CANDIDATES[@]}"; do
        [[ -d "$p" ]] && { printf '%s' "$p"; return; }
    done
}

_resolve_compat_dir() {
    if [[ -n "$COMPAT_TOOLS_DIR" ]]; then
        [[ -d "$COMPAT_TOOLS_DIR" ]] || mkdir -p "$COMPAT_TOOLS_DIR"
        return
    fi
    COMPAT_TOOLS_DIR="$(_find_compat_dir)"
    if [[ -n "$COMPAT_TOOLS_DIR" ]]; then
        ok "compatibilitytools.d: ${COMPAT_TOOLS_DIR}"
        return
    fi
    local default="${HOME}/.steam/steam/compatibilitytools.d"
    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
        warn "Could not find Steam's compatibilitytools.d — creating ${default}"
        mkdir -p "$default"
    else
        warn "Could not find Steam's compatibilitytools.d."
        printf "  ${C_B}Create it?${C_R} ${C_DIM}(${default})${C_R}  [Y/n]: "
        local ans; read -r ans
        [[ "${ans,,}" =~ ^n ]] && err "No compatibilitytools.d available."
        mkdir -p "$default"
        ok "Created: ${default}"
    fi
    COMPAT_TOOLS_DIR="$default"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Discovery: find Neutron packages from builder output
# ══════════════════════════════════════════════════════════════════════════════

_find_builder_packages() {
    for base_dir in "${LOCAL_BUILD_DIRS[@]}"; do
        [[ -d "$base_dir" ]] || continue
        for pkg_dir in "$base_dir"/*/; do
            [[ -d "$pkg_dir" ]] || continue
            # A valid neutron package has files/bin/wine or bin/wine
            if [[ -x "${pkg_dir}files/bin/wine" ]] || [[ -x "${pkg_dir}bin/wine" ]] \
               || [[ -f "${pkg_dir}toolmanifest.vdf" ]]; then
                printf '%s\n' "${pkg_dir%/}"
            fi
        done
    done
}

# ══════════════════════════════════════════════════════════════════════════════
#  Action: install — add a Neutron package to managed installs
# ══════════════════════════════════════════════════════════════════════════════

action_install() {
    local src="$_INSTALL_PATH"

    if [[ -n "$src" ]]; then
        # Path given on CLI — use directly
        [[ -d "$src" || -f "$src" ]] || err "Not found: ${src}"
    else
        # Interactive: pick source type first
        section "Install source"
        local src_type
        src_type=$( {
            printf 'builder\tFrom neutron-builder output (locally-built packages)\n'
            printf 'directory\tFrom a local directory containing a Neutron/Wine build\n'
            printf 'tarball\tFrom a .tar.gz / .tar.xz / .tar.zst archive\n'
        } | _fzf_pick "Source type" "Where is the Neutron package?" )
        [[ -n "$src_type" ]] || return 0

        case "$src_type" in
            builder)
                section "Select a package"
                local -a candidates=()
                while IFS= read -r line; do
                    [[ -n "$line" ]] && candidates+=("$line")
                done < <(_find_builder_packages)
                if [[ ${#candidates[@]} -eq 0 ]]; then
                    warn "No locally-built Neutron packages found."
                    dim "  Looked in:"
                    for d in "${LOCAL_BUILD_DIRS[@]}"; do dim "    ${d}"; done
                    err "Build something with neutron-builder first."
                fi
                src=$( {
                    for p in "${candidates[@]}"; do
                        local name ver
                        name="$(basename "$p")"
                        ver="$(_wine_version "$p")"
                        local display; display="$(_read_display_name "${p}/compatibilitytool.vdf")"
                        if [[ -n "$display" ]]; then
                            printf '%s\t%s  (%s)  [%s]\n' "$p" "$name" "$display" "$ver"
                        else
                            printf '%s\t%s  [%s]\n' "$p" "$name" "$ver"
                        fi
                    done
                } | _fzf_pick "Package" "Select a Neutron package to install" "30%" )
                [[ -n "$src" ]] || return 0
                ;;
            directory)
                printf "\n  ${C_B}Path to Neutron/Wine build directory:${C_R} "
                read -r src
                [[ -d "$src" ]] || err "Not a directory: ${src}"
                ;;
            tarball)
                printf "\n  ${C_B}Path to archive (.tar.gz/.tar.xz/.tar.zst):${C_R} "
                read -r src
                [[ -f "$src" ]] || err "File not found: ${src}"
                ;;
        esac
    fi

    # Determine if it's a tarball or directory
    local is_tarball=false
    if [[ -f "$src" ]] && [[ "$src" =~ \.(tar\.(gz|xz|zst|bz2)|tgz)$ ]]; then
        is_tarball=true
    elif [[ ! -d "$src" ]]; then
        err "Not a valid source: ${src}"
    fi

    # Pick install name
    local default_name
    if [[ "$is_tarball" == "true" ]]; then
        default_name="$(basename "$src" | sed 's/\.tar\.\(gz\|xz\|zst\|bz2\)$//; s/\.tgz$//')"
    else
        default_name="$(basename "$src")"
    fi

    section "Install name"
    printf "  Packages are installed to: ${C_B}${INSTALL_BASE}/<name>/${C_R}\n"
    printf "  ${C_B}Name${C_R} [default: ${default_name}]: "
    local install_name; read -r install_name
    install_name="${install_name:-$default_name}"
    # Sanitise
    install_name="${install_name//[^a-zA-Z0-9._-]/_}"
    [[ -n "$install_name" ]] || err "Install name cannot be empty."

    local dest="$INSTALL_BASE/$install_name"

    if [[ -d "$dest" ]]; then
        warn "Install '${install_name}' already exists."
        printf "  ${C_B}Overwrite? [y/N]:${C_R} "
        local ans; read -r ans
        [[ "${ans,,}" =~ ^y ]] || { msg2 "Aborted."; return 0; }
        _clear_active "$install_name"
        rm -rf "$dest"
    fi

    section "Installing"
    msg2 "Source: ${src}"
    msg2 "Dest:   ${dest}"
    mkdir -p "$dest"

    if [[ "$is_tarball" == "true" ]]; then
        msg "Extracting archive…"
        local _tar_ok=false
        _try_tar() {
            if tar "$@" "$src" -C "$dest" --strip-components=1 2>/dev/null; then
                _tar_ok=true
            elif tar "$@" "$src" -C "$dest" 2>/dev/null; then
                _tar_ok=true
            fi
        }
        case "$src" in
            *.tar.zst)
                command -v zstd >/dev/null 2>&1 || err "zstd required for .tar.zst — install it: sudo apt install zstd"
                _try_tar --use-compress-program=zstd -xf ;;
            *.tar.xz)  _try_tar -xJf ;;
            *.tar.bz2) _try_tar -xjf ;;
            *)         _try_tar -xzf ;;
        esac
        $_tar_ok || err "Failed to extract archive."
    else
        msg "Copying…"
        if command -v rsync >/dev/null 2>&1; then
            rsync -aH --info=progress2 "$src/" "$dest/"
        else
            cp -a "$src/." "$dest/"
        fi
    fi

    # Fix permissions
    chmod -R u+w,a+rX "$dest"
    for d in "$dest/bin" "$dest/files/bin"; do
        [[ -d "$d" ]] && chmod +x "$d"/* 2>/dev/null || true
    done
    # Make neutron launcher executable if present
    [[ -f "$dest/neutron" ]] && chmod +x "$dest/neutron"

    # Validate
    if [[ ! -x "$dest/files/bin/wine" ]] && [[ ! -x "$dest/bin/wine" ]]; then
        warn "No wine binary found after install."
        warn "Contents of ${dest}:"
        ls -la "$dest/" 2>/dev/null || true
        err "Installation appears invalid — expected files/bin/wine or bin/wine"
    fi

    _write_meta "$dest" "installed from: $src"
    ok "Installed: ${install_name}"

    local ver; ver="$(_wine_version "$dest")"
    msg2 "Version: ${ver}"
    msg2 "Location: ${dest}"

    # Offer to set as active
    printf "\n  ${C_B}Set as active system Wine?${C_R} [Y/n]: "
    local ans; read -r ans
    if [[ ! "${ans,,}" =~ ^n ]]; then
        _set_active "$install_name"
        ok "Active Wine set to: ${install_name}"
    fi

    # Offer to deploy to Steam
    printf "\n  ${C_B}Also deploy to Steam?${C_R} [y/N]: "
    read -r ans
    if [[ "${ans,,}" =~ ^y ]]; then
        _resolve_compat_dir
        local steam_dest="${COMPAT_TOOLS_DIR}/${install_name}"
        if [[ -d "$steam_dest" ]]; then
            warn "Already exists in Steam: ${steam_dest}"
            printf "  ${C_B}Overwrite? [y/N]:${C_R} "
            read -r ans
            [[ "${ans,,}" =~ ^y ]] || { msg2 "Skipped Steam deploy."; return 0; }
            rm -rf "$steam_dest"
        fi
        run cp -a "$dest" "$steam_dest"
        ok "Deployed to Steam: ${steam_dest}"
        _restart_reminder
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  Action: deploy — copy a managed install to Steam's compatibilitytools.d
# ══════════════════════════════════════════════════════════════════════════════

action_deploy() {
    local src="$_DEPLOY_PATH"
    _resolve_compat_dir

    if [[ -n "$src" ]] && [[ -d "$src" ]]; then
        # Direct path given — deploy it
        src="${src%/}"
    elif [[ -n "$src" ]]; then
        # Maybe it's a managed install name
        [[ -d "$INSTALL_BASE/$src" ]] && src="$INSTALL_BASE/$src" || err "Not found: $src"
    else
        # Interactive: pick from managed installs + builder output
        section "Select package to deploy"
        local listing; listing="$(_list_installs)"
        local -a candidates=()

        # Managed installs
        if [[ -n "$listing" ]]; then
            while IFS=$'\t' read -r name version date active; do
                candidates+=("$INSTALL_BASE/$name"$'\t'"[managed] ${name}  ${version}  (${date})  active=${active}")
            done <<< "$listing"
        fi

        # Builder output
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            local name ver
            name="$(basename "$line")"
            ver="$(_wine_version "$line")"
            candidates+=("${line}"$'\t'"[builder] ${name}  [${ver}]")
        done < <(_find_builder_packages)

        if [[ ${#candidates[@]} -eq 0 ]]; then
            err "No packages found. Install or build something first."
        fi

        src=$( printf '%s\n' "${candidates[@]}" | _fzf_pick "Deploy" "Select a package to deploy to Steam" "30%" )
        [[ -n "$src" ]] || return 0
    fi

    [[ -d "$src" ]] || err "Not a directory: ${src}"
    local dest_name; dest_name="$(basename "$src")"
    local install_dir="${COMPAT_TOOLS_DIR}/${dest_name}"

    section "Deploying to Steam"
    msg2 "Source: ${src}"
    msg2 "Dest:   ${install_dir}"

    if [[ -d "$install_dir" ]]; then
        warn "Already exists: ${install_dir}"
        printf "  ${C_B}Overwrite? [y/N]:${C_R} "
        local ans; read -r ans
        [[ "${ans,,}" =~ ^y ]] || { msg2 "Skipped."; return 0; }
        run rm -rf "$install_dir"
    fi

    run cp -a "$src" "$install_dir"
    local display_name; display_name="$(_read_display_name "${install_dir}/compatibilitytool.vdf")"
    ok "Deployed: ${dest_name}"
    [[ -n "$display_name" ]] && msg2 "Display name: ${display_name}"
    msg2 "Path: ${install_dir}"
    _restart_reminder
}

# ══════════════════════════════════════════════════════════════════════════════
#  Action: system-wine — set a managed install as the active system Wine
# ══════════════════════════════════════════════════════════════════════════════

action_system_wine() {
    local name="$_SWITCH_NAME"

    if [[ -n "$name" ]]; then
        [[ -d "$INSTALL_BASE/$name" ]] || err "No managed install named: ${name}"
    else
        section "Switch active system Wine"
        local listing; listing="$(_list_installs)"
        if [[ -z "$listing" ]]; then
            err "No managed Neutron installs. Use 'install' to add one first."
        fi
        name=$( while IFS=$'\t' read -r n ver date active; do
            local marker=""
            [[ "$active" == "YES" ]] && marker=" <<<ACTIVE"
            printf '%s\t%s  %s  (%s)%s\n' "$n" "$n" "$ver" "$date" "$marker"
        done <<< "$listing" | _fzf_pick "Active Wine" "Select which install to set as system Wine" )
        [[ -n "$name" ]] || return 0
    fi

    section "Setting active Wine"
    msg2 "Install: ${name}"
    _set_active "$name"
    ok "System Wine set to: ${name}"
    printf "\n  ${C_B}Verify:${C_R}  wine --version\n"

    # Show neutron launcher status
    if [[ -L "$SYMLINK_DIR/neutron" ]]; then
        msg2 "Neutron launcher: ${SYMLINK_DIR}/neutron"
        printf "  ${C_B}Usage:${C_R}  neutron waitforexitandrun /path/to/game.exe\n"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  Action: list
# ══════════════════════════════════════════════════════════════════════════════

action_list() {
    section "Managed Neutron installs"
    printf "  ${C_DIM}Install directory: ${INSTALL_BASE}${C_R}\n"
    printf "  ${C_DIM}Symlink directory: ${SYMLINK_DIR}${C_R}\n\n"

    local listing; listing="$(_list_installs)"
    if [[ -z "$listing" ]]; then
        msg2 "No managed installs found."
        dim "  Use 'install' to add a Neutron package."
        return 0
    fi

    printf "  ${C_B}%-28s  %-24s  %-18s  %s${C_R}\n" "name" "version" "installed" "active"
    printf "  %s\n" "$(printf '─%.0s' {1..78})"

    while IFS=$'\t' read -r name version date active; do
        local colour="$C_CYN"
        [[ "$active" == "YES" ]] && colour="$C_GRN"
        printf "  ${colour}%-28s${C_R}  %-24s  %-18s  %s\n" \
               "$name" "$version" "$date" "$active"
    done <<< "$listing"
    printf "\n"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Action: remove
# ══════════════════════════════════════════════════════════════════════════════

action_remove() {
    local target="$_REMOVE_NAME"

    if [[ -n "$target" ]]; then
        [[ -d "$INSTALL_BASE/$target" ]] || err "Not found: ${target}"
    else
        section "Remove a managed install"
        local listing; listing="$(_list_installs)"
        if [[ -z "$listing" ]]; then
            msg2 "No managed installs found."; return 0
        fi

        local -a selected=()
        while IFS= read -r n; do
            [[ -n "$n" ]] && selected+=("$n")
        done < <(
            while IFS=$'\t' read -r n ver date active; do
                local size; size="$(du -sh "$INSTALL_BASE/$n" 2>/dev/null | cut -f1)"
                printf '%s\t%s  %s  (%s)  [%s]  active=%s\n' "$n" "$n" "$ver" "$date" "$size" "$active"
            done <<< "$listing" | _fzf_multi_pick "Remove" "Select install(s) to remove (Tab to multi-select)"
        )

        if [[ ${#selected[@]} -eq 0 ]]; then
            msg2 "Nothing selected."; return 0
        fi

        section "Confirm removal"
        for s in "${selected[@]}"; do
            printf "  ${C_RED}×${C_R}  %s\n" "$s"
        done
        printf "\n  ${C_B}This will permanently delete these installs. Continue? [y/N]:${C_R} "
        local ans; read -r ans
        [[ "${ans,,}" =~ ^y ]] || { msg2 "Aborted."; return 0; }

        for s in "${selected[@]}"; do
            _clear_active "$s"
            rm -rf "$INSTALL_BASE/$s"
            ok "Removed: ${s}"
        done
        return 0
    fi

    # CLI single removal
    section "Remove"
    msg2 "Target: ${INSTALL_BASE}/${target}"
    warn "This will permanently delete: ${target}"
    printf "  ${C_B}Are you sure? [y/N]:${C_R} "
    local ans; read -r ans
    [[ "${ans,,}" =~ ^y ]] || { msg2 "Aborted."; return 0; }

    _clear_active "$target"
    rm -rf "$INSTALL_BASE/$target"
    ok "Removed: ${target}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Action: info
# ══════════════════════════════════════════════════════════════════════════════

action_info() {
    local name="$_SWITCH_NAME"

    if [[ -z "$name" ]]; then
        local listing; listing="$(_list_installs)"
        if [[ -z "$listing" ]]; then
            msg2 "No managed installs found."; return 0
        fi
        name=$( while IFS=$'\t' read -r n ver date active; do
            printf '%s\t%s  %s  (%s)  active=%s\n' "$n" "$n" "$ver" "$date" "$active"
        done <<< "$listing" | _fzf_pick "Info" "Select an install to inspect" )
        [[ -n "$name" ]] || return 0
    fi

    local dir="$INSTALL_BASE/$name"
    [[ -d "$dir" ]] || err "Not found: ${name}"

    section "Info: ${name}"
    printf "\n"
    msg2 "Name     : ${name}"
    msg2 "Location : ${dir}"
    msg2 "Version  : $(_read_meta "$dir" "version")"
    msg2 "Installed: $(_read_meta "$dir" "installed")"
    msg2 "Source   : $(_read_meta "$dir" "source")"

    local disk; disk="$(du -sh "$dir" 2>/dev/null | cut -f1)"
    msg2 "Disk     : ${disk}"

    # Active?
    local active_target=""
    [[ -L "$SYMLINK_DIR/wine" ]] && active_target="$(readlink -f "$SYMLINK_DIR/wine" 2>/dev/null || true)"
    local bin_dir; bin_dir="$(_find_bin_dir "$dir")"
    if [[ -n "$bin_dir" ]] && [[ -n "$active_target" ]]; then
        local this_wine; this_wine="$(readlink -f "$bin_dir/wine" 2>/dev/null || true)"
        if [[ "$active_target" == "$this_wine" ]]; then
            msg2 "Active   : ${C_GRN}YES${C_R} (symlinked in ${SYMLINK_DIR})"
        else
            msg2 "Active   : no"
        fi
    else
        msg2 "Active   : no"
    fi

    sep
    if [[ -n "$bin_dir" ]]; then
        local bin_count; bin_count="$(find "$bin_dir" -maxdepth 1 -type f -executable 2>/dev/null | wc -l)"
        msg2 "Binaries : ${bin_count} files in $(basename "$(dirname "$bin_dir")")/bin/"
    fi
    [[ -d "$dir/files/lib" || -d "$dir/lib" ]] && msg2 "lib/     : present"
    [[ -d "$dir/files/lib64" || -d "$dir/lib64" ]] && msg2 "lib64/   : present"
    [[ -d "$dir/files/share" || -d "$dir/share" ]] && msg2 "share/   : present"
    [[ -f "$dir/neutron" ]] && msg2 "Launcher : neutron  (Python launcher for Steam verbs)"
    [[ -f "$dir/toolmanifest.vdf" ]] && msg2 "VDF      : toolmanifest.vdf present"

    local display; display="$(_read_display_name "$dir/compatibilitytool.vdf")"
    [[ -n "$display" ]] && msg2 "Display  : ${display}"
    printf "\n"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Helpers
# ══════════════════════════════════════════════════════════════════════════════

_restart_reminder() {
    printf "\n  ${C_YLW}${C_B}Restart Steam for changes to take effect.${C_R}\n\n"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Interactive main menu
# ══════════════════════════════════════════════════════════════════════════════

declare -A _MENU_DESC=(
    [install]="install         — Install a Neutron package (from builder, directory, or archive)"
    [deploy]="deploy          — Deploy a package to Steam's compatibilitytools.d"
    [system-wine]="system-wine     — Set a managed install as the active system Wine"
    [switch]="switch          — Switch which managed install is active"
    [list]="list            — List all managed Neutron installs"
    [remove]="remove          — Remove a managed install"
    [info]="info            — Show details about a managed install"
)
_MENU_KEYS=( install deploy system-wine switch list remove info )

pick_action() {
    section "What would you like to do?"
    local picked
    picked=$( for k in "${_MENU_KEYS[@]}"; do
        printf '%s\t%s\n' "$k" "${_MENU_DESC[$k]}"
    done | _fzf_pick "Action" "neutron-install — select an action" "25%" )
    [[ -n "$picked" ]] || err "No action selected."
    ACTION="$picked"
    ok "Selected: ${ACTION}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Entry point
# ══════════════════════════════════════════════════════════════════════════════
print_banner

if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "DRY RUN mode — no changes will be made."
fi

# Menu loop
while true; do
    if [[ -z "$ACTION" ]]; then
        pick_action
    fi

    case "$ACTION" in
        install)      action_install ;;
        deploy)       action_deploy ;;
        system-wine)  action_system_wine ;;
        switch)       action_system_wine ;;
        list)         action_list ;;
        remove)       action_remove ;;
        info)         action_info ;;
        *)            err "Unknown action: ${ACTION}" ;;
    esac

    # If we were called with a CLI flag, exit after one action
    [[ "$NONINTERACTIVE" -eq 1 ]] && break

    # Reset for the next menu loop iteration
    ACTION=""
    _DEPLOY_PATH=""
    _INSTALL_PATH=""
    _SWITCH_NAME=""
    _REMOVE_NAME=""
done
