#!/usr/bin/env bash
# ╔═════════════════════════════════════════════════════════════════════════════╗
# ║         mythix-build  •  proton-install  —  Proton Installs                 ║
# ║         Download, deploy & manage Proton tools for Steam                   ║
# ╚═════════════════════════════════════════════════════════════════════════════╝
#
# This script handles Proton-specific installs:
#   1. Fetch & install a pre-built release (GE-Proton, custom URL, etc.) directly
#      into Steam's compatibilitytools.d/ so it shows up in the compatibility
#      tool dropdown immediately.
#   2. Deploy a locally-built mythix-proton package from your build output
#      directory into compatibilitytools.d/ without having to manually copy files.
#
# Usage:  ./proton-install.sh [options]
#         ./proton-install.sh --help
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
    printf "  ║  :3 mythix-build  •  proton-install                           ║\n"
    printf "  ║      Proton Installs  •  GE  •  custom  •  local             ║\n"
    printf "  ║                                                               ║\n"
    printf "  ╚═══════════════════════════════════════════════════════════════╝\n"
    printf "${C_R}\n"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Defaults
# ══════════════════════════════════════════════════════════════════════════════
DRY_RUN=0
COMPAT_TOOLS_DIR=""        # auto-detected unless overridden by --compat-dir
ACTION=""                  # set by CLI flags for non-interactive mode
NONINTERACTIVE=0           # 1 when a CLI action flag is given

# GE-Proton GitHub repo
GE_REPO="GloriousEggroll/proton-ge-custom"
GE_ASSET_PATTERN="GE-Proton.*\.tar\.gz"

# Directories to scan for locally-built mythix-proton packages.
# proton-builder writes to the XDG data dir regardless of whether
# it is run from the source tree or after make install, so the first entry
# covers both cases.
LOCAL_BUILD_DIRS=(
    "${XDG_DATA_HOME:-${HOME}/.local/share}/mythix-proton_builder/buildz/install"
    "${HOME}/.local/share/mythix-proton_builder/buildz/install"
)

# ══════════════════════════════════════════════════════════════════════════════
#  Usage
# ══════════════════════════════════════════════════════════════════════════════
print_usage() {
    cat <<USAGE
${C_B}Usage:${C_R} $0 [options]

${C_B}Non-interactive (scriptable) flags:${C_R}
  --install-ge, --ge       Download & install latest GE-Proton
  --install-url URL        Install a Proton package from a direct URL
                           Supports: .tar.gz  .tar.xz  .tar.zst  .tar.bz2
  --deploy PATH            Deploy a specific directory to compatibilitytools.d
  --list                   List installed Proton tools and exit
  --remove NAME            Remove a Proton tool by its directory name

${C_B}Common options:${C_R}
  --compat-dir DIR         Override the auto-detected compatibilitytools.d path
  --dry-run                Show what would happen without making any changes
  -h, --help               Show this help and exit

${C_B}Interactive mode (no flags):${C_R}
  Running without action flags drops into a menu (fzf or numbered fallback).

${C_B}Examples:${C_R}
  $0                          # interactive menu
  $0 --ge                     # install latest GE-Proton silently
  $0 --install-url https://...
  $0 --deploy ~/my-proton-build/
  $0 --list
  $0 --remove GE-Proton9-27
  $0 --dry-run --ge
USAGE
}

# ══════════════════════════════════════════════════════════════════════════════
#  Argument parsing
# ══════════════════════════════════════════════════════════════════════════════
_DEPLOY_PATH=""
_REMOVE_NAME=""
_INSTALL_URL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-ge|--ge)
            ACTION="install-ge"; NONINTERACTIVE=1; shift ;;
        --install-url)
            [[ $# -ge 2 ]] || err "--install-url requires a URL argument"
            ACTION="install-url"; _INSTALL_URL="$2"; NONINTERACTIVE=1; shift 2 ;;
        --deploy)
            [[ $# -ge 2 ]] || err "--deploy requires a PATH argument"
            ACTION="deploy-local"; _DEPLOY_PATH="$2"; NONINTERACTIVE=1; shift 2 ;;
        --list)
            ACTION="list"; NONINTERACTIVE=1; shift ;;
        --remove)
            [[ $# -ge 2 ]] || err "--remove requires a NAME argument"
            ACTION="remove"; _REMOVE_NAME="$2"; NONINTERACTIVE=1; shift 2 ;;
        --compat-dir)
            [[ $# -ge 2 ]] || err "--compat-dir requires a PATH argument"
            COMPAT_TOOLS_DIR="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN=1; shift ;;
        -h|--help)
            print_banner
            print_usage
            exit 0 ;;
        *)
            printf "Unknown option: %s\n" "$1" >&2
            print_usage
            exit 1 ;;
    esac
done

# ══════════════════════════════════════════════════════════════════════════════
#  Dependency check
# ══════════════════════════════════════════════════════════════════════════════
_check_tool() {
    local t="$1"
    command -v "$t" >/dev/null 2>&1
}

check_required_deps() {
    local missing=()
    for t in curl tar; do
        _check_tool "$t" || missing+=("$t")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing required tools: ${missing[*]}"
    fi
}

_warn_zstd_if_needed() {
    local url="$1"
    if [[ "$url" == *.tar.zst ]] && ! _check_tool zstd; then
        warn "This archive is .tar.zst but 'zstd' was not found."
        warn "Install it: sudo apt install zstd   (Debian/Ubuntu)"
        warn "            sudo dnf install zstd   (Fedora/RHEL)"
        err  "zstd is required to extract this archive."
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  Steam compatibilitytools.d discovery
# ══════════════════════════════════════════════════════════════════════════════

# Candidate paths in priority order (excluding env var — handled separately)
_COMPAT_CANDIDATES=(
    "${HOME}/.steam/root/compatibilitytools.d"
    "${HOME}/.steam/steam/compatibilitytools.d"
    "${HOME}/.steam/debian-installation/compatibilitytools.d"
    "${HOME}/.local/share/Steam/compatibilitytools.d"
)

# Additional Steam library root candidates to probe for compatibilitytools.d
_STEAM_LIBRARY_ROOTS=(
    "${HOME}/.steam/root"
    "${HOME}/.steam/steam"
    "${HOME}/.steam/debian-installation"
    "${HOME}/.local/share/Steam"
)

_find_compat_dir() {
    # 1. Honour $STEAM_COMPAT_TOOL_PATHS (colon-separated list)
    if [[ -n "${STEAM_COMPAT_TOOL_PATHS:-}" ]]; then
        local IFS_SAVED="$IFS"
        IFS=':'
        for p in ${STEAM_COMPAT_TOOL_PATHS}; do
            IFS="$IFS_SAVED"
            p="${p%/}"   # strip trailing slash
            if [[ -d "$p" ]]; then
                printf '%s' "$p"
                return
            fi
        done
        IFS="$IFS_SAVED"
    fi

    # 2. Scan well-known paths
    for p in "${_COMPAT_CANDIDATES[@]}"; do
        if [[ -d "$p" ]]; then
            printf '%s' "$p"
            return
        fi
    done

    # 3. Scan Steam library roots — some installs only have the root directory
    for root in "${_STEAM_LIBRARY_ROOTS[@]}"; do
        local p="${root}/compatibilitytools.d"
        if [[ -d "$p" ]]; then
            printf '%s' "$p"
            return
        fi
    done

    # 4. Nothing found — offer to create the default path
    local default="${HOME}/.steam/root/compatibilitytools.d"
    printf '' # return empty to signal caller
}

_resolve_compat_dir() {
    # If the user passed --compat-dir, validate and use it directly
    if [[ -n "$COMPAT_TOOLS_DIR" ]]; then
        if [[ ! -d "$COMPAT_TOOLS_DIR" ]]; then
            if [[ "$DRY_RUN" -eq 1 ]]; then
                warn "[dry-run] Would create: ${COMPAT_TOOLS_DIR}"
            else
                run mkdir -p "$COMPAT_TOOLS_DIR"
                ok "Created: ${COMPAT_TOOLS_DIR}"
            fi
        fi
        return
    fi

    local found
    found="$(_find_compat_dir)"

    if [[ -n "$found" ]]; then
        COMPAT_TOOLS_DIR="$found"
        ok "compatibilitytools.d: ${COMPAT_TOOLS_DIR}"
        return
    fi

    # Nothing found — ask interactively or abort in non-interactive mode
    local default="${HOME}/.steam/root/compatibilitytools.d"
    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
        warn "Could not find Steam's compatibilitytools.d."
        warn "Creating default path: ${default}"
        if [[ "$DRY_RUN" -eq 0 ]]; then
            mkdir -p "$default"
        else
            warn "[dry-run] Would create: ${default}"
        fi
        COMPAT_TOOLS_DIR="$default"
        return
    fi

    printf "\n"
    warn "Could not find Steam's compatibilitytools.d directory."
    printf "  ${C_B}Create it now?${C_R} ${C_DIM}(${default})${C_R}\n"
    printf "  ${C_B}[Y/n]:${C_R} "
    local ans
    read -r ans
    if [[ "${ans,,}" =~ ^n ]]; then
        err "No compatibilitytools.d path available. Aborting."
    fi
    if [[ "$DRY_RUN" -eq 0 ]]; then
        mkdir -p "$default"
        ok "Created: ${default}"
    else
        warn "[dry-run] Would create: ${default}"
    fi
    COMPAT_TOOLS_DIR="$default"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Archive extraction helper
# ══════════════════════════════════════════════════════════════════════════════

# Detect the archive format and return the correct tar flags
_tar_flags_for() {
    local url_or_file="$1"
    case "$url_or_file" in
        *.tar.gz|*.tgz)   printf 'xzf'  ;;
        *.tar.xz)          printf 'xJf'  ;;
        *.tar.zst)         printf 'x --use-compress-program=zstd -f' ;;
        *.tar.bz2|*.tbz2)  printf 'xjf'  ;;
        *)
            # Try to guess from `file` output at runtime if available
            printf 'xaf'   # auto-detect (GNU tar)
            ;;
    esac
}

# Extract archive to a directory, stripping the top-level component
# Usage: _extract_archive <archive_path> <dest_dir>
_extract_archive() {
    local archive="$1"
    local dest="$2"

    _warn_zstd_if_needed "$archive"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "[dry-run] Would extract: ${archive} → ${dest}"
        return
    fi

    mkdir -p "$dest"

    local flags
    flags="$(_tar_flags_for "$archive")"

    # shellcheck disable=SC2086
    if [[ "$flags" == *"zstd"* ]]; then
        # Special case: --use-compress-program needs word splitting
        tar x --use-compress-program=zstd -f "$archive" \
            --strip-components=1 -C "$dest"
    else
        tar "$flags" "$archive" --strip-components=1 -C "$dest"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  Read display_name from a compatibilitytool.vdf
# ══════════════════════════════════════════════════════════════════════════════
_read_display_name() {
    local vdf="$1"
    [[ -f "$vdf" ]] || { printf '(no vdf)'; return; }
    # VDF key-value format: "display_name"   "Some Name"
    local name
    name=$(grep -i '"display_name"' "$vdf" 2>/dev/null \
           | head -1 \
           | sed 's/.*"display_name"[[:space:]]*"\([^"]*\)".*/\1/' || true)
    [[ -n "$name" ]] && printf '%s' "$name" || printf '(unknown)'
}

# ══════════════════════════════════════════════════════════════════════════════
#  Restart reminder
# ══════════════════════════════════════════════════════════════════════════════
restart_reminder() {
    printf "\n"
    printf "  ${C_YLW}${C_B}Restart Steam for changes to take effect.${C_R}\n"
    printf "\n"
}

# ══════════════════════════════════════════════════════════════════════════════
#  GitHub release download helper
#
#  _pi_download_github_release <repo> <asset_pattern> [dest_name]
#
#  - Queries the latest release from api.github.com
#  - Finds the asset matching <asset_pattern> (extended grep regex)
#  - Downloads with curl (progress bar)
#  - Extracts to a temp dir with --strip-components=1
#  - Installs to $COMPAT_TOOLS_DIR/<dest_name>/  (dest_name defaults to the
#    release tag name)
# ══════════════════════════════════════════════════════════════════════════════
_pi_download_github_release() {
    local repo="$1"
    local asset_pattern="$2"
    local dest_name="${3:-}"   # optional override for the install directory name

    section "Fetching release info"
    msg2 "Repo: ${repo}"

    local api_url="https://api.github.com/repos/${repo}/releases/latest"
    msg2 "Querying: ${api_url}"

    local release_json
    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "[dry-run] Would query: ${api_url}"
        warn "[dry-run] Would download and install matching asset."
        return
    fi

    release_json=$(curl -fsSL \
        -H "Accept: application/vnd.github.v3+json" \
        "$api_url") \
        || err "Failed to fetch release info from GitHub. Check your network connection."

    # Extract tag name (release name used as the install directory)
    local tag_name
    tag_name=$(printf '%s' "$release_json" \
               | grep '"tag_name"' \
               | head -1 \
               | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    [[ -n "$tag_name" ]] || err "Could not parse tag_name from GitHub API response."
    ok "Latest release: ${tag_name}"

    # Find the download URL for the matching asset
    local asset_url
    asset_url=$(printf '%s' "$release_json" \
                | grep '"browser_download_url"' \
                | grep -E "$asset_pattern" \
                | head -1 \
                | sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    [[ -n "$asset_url" ]] || err "No asset matching pattern '${asset_pattern}' found in release ${tag_name}."
    ok "Asset: $(basename "$asset_url")"

    # Resolve the final install directory name
    [[ -z "$dest_name" ]] && dest_name="$tag_name"
    local install_dir="${COMPAT_TOOLS_DIR}/${dest_name}"

    if [[ -d "$install_dir" ]]; then
        warn "Already installed: ${install_dir}"
        printf "  ${C_B}Re-install / overwrite? [y/N]:${C_R} "
        local ans
        read -r ans
        [[ "${ans,,}" =~ ^y ]] || { msg2 "Skipped."; return; }
        run rm -rf "$install_dir"
    fi

    # Download to a temp file
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local archive="${tmp_dir}/$(basename "$asset_url")"

    section "Downloading"
    msg2 "URL:  ${asset_url}"
    msg2 "Dest: ${archive}"
    curl -L --progress-bar -o "$archive" "$asset_url" \
        || err "Download failed: ${asset_url}"
    ok "Download complete."

    # Extract
    section "Extracting"
    local extract_dir="${tmp_dir}/extracted"
    _extract_archive "$archive" "$extract_dir"
    ok "Extracted to temp dir."

    # Install into compatibilitytools.d
    section "Installing"
    msg2 "Installing to: ${install_dir}"
    run cp -a "$extract_dir" "$install_dir"

    # Clean up temp
    rm -rf "$tmp_dir"

    # Report display_name if available
    local vdf="${install_dir}/compatibilitytool.vdf"
    local display_name
    display_name="$(_read_display_name "$vdf")"

    ok "Installed: ${dest_name}"
    msg2 "Display name: ${display_name}"
    msg2 "Path:         ${install_dir}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Action: install-ge — download latest GE-Proton
# ══════════════════════════════════════════════════════════════════════════════
action_install_ge() {
    section "GE-Proton — latest release"
    _resolve_compat_dir
    _pi_download_github_release "$GE_REPO" "$GE_ASSET_PATTERN"
    restart_reminder
}

# ══════════════════════════════════════════════════════════════════════════════
#  Action: install-url — install from a direct URL
# ══════════════════════════════════════════════════════════════════════════════
action_install_url() {
    local url="${1:-$_INSTALL_URL}"
    [[ -n "$url" ]] || err "No URL provided."

    _warn_zstd_if_needed "$url"
    _resolve_compat_dir

    section "Install from URL"
    msg2 "URL: ${url}"

    # Derive a candidate name from the URL basename (strip common archive suffixes)
    local basename
    basename="$(basename "$url")"
    local dest_name
    dest_name="${basename%.tar.gz}"
    dest_name="${dest_name%.tar.xz}"
    dest_name="${dest_name%.tar.zst}"
    dest_name="${dest_name%.tar.bz2}"
    dest_name="${dest_name%.tgz}"
    dest_name="${dest_name%.tbz2}"

    local install_dir="${COMPAT_TOOLS_DIR}/${dest_name}"

    if [[ -d "$install_dir" ]]; then
        warn "Already installed: ${install_dir}"
        printf "  ${C_B}Re-install / overwrite? [y/N]:${C_R} "
        local ans
        read -r ans
        [[ "${ans,,}" =~ ^y ]] || { msg2 "Skipped."; return; }
        run rm -rf "$install_dir"
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "[dry-run] Would download: ${url}"
        warn "[dry-run] Would install to: ${install_dir}"
        restart_reminder
        return
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local archive="${tmp_dir}/${basename}"

    msg2 "Downloading..."
    curl -L --progress-bar -o "$archive" "$url" \
        || err "Download failed: ${url}"
    ok "Download complete."

    local extract_dir="${tmp_dir}/extracted"
    _extract_archive "$archive" "$extract_dir"
    ok "Extracted."

    msg2 "Installing to: ${install_dir}"
    run cp -a "$extract_dir" "$install_dir"
    rm -rf "$tmp_dir"

    local display_name
    display_name="$(_read_display_name "${install_dir}/compatibilitytool.vdf")"
    ok "Installed: ${dest_name}"
    msg2 "Display name: ${display_name}"
    msg2 "Path:         ${install_dir}"

    restart_reminder
}

# ══════════════════════════════════════════════════════════════════════════════
#  Action: deploy-local — copy a locally-built proton package into
#  compatibilitytools.d
# ══════════════════════════════════════════════════════════════════════════════

# Return the list of candidate proton packages found in LOCAL_BUILD_DIRS
_find_local_packages() {
    for base_dir in "${LOCAL_BUILD_DIRS[@]}"; do
        [[ -d "$base_dir" ]] || continue
        for pkg_dir in "$base_dir"/*/; do
            [[ -d "$pkg_dir" ]] || continue
            # A valid proton package has toolmanifest.vdf or a 'proton' launcher
            if [[ -f "${pkg_dir}/toolmanifest.vdf" ]] \
               || [[ -f "${pkg_dir}/neutron" ]] \
               || [[ -f "${pkg_dir}/proton" ]]; then
                printf '%s\n' "$pkg_dir"
            fi
        done
    done
}

action_deploy_local() {
    local src="${1:-$_DEPLOY_PATH}"

    _resolve_compat_dir

    if [[ -n "$src" ]]; then
        # Path was given on the command line — validate and deploy directly
        [[ -d "$src" ]] || err "Not a directory: ${src}"
        src="${src%/}"   # strip trailing slash
    else
        # Interactive: scan for packages and present a picker
        section "Local Proton packages"
        local -a candidates=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && candidates+=("$line")
        done < <(_find_local_packages)

        if [[ ${#candidates[@]} -eq 0 ]]; then
            warn "No locally-built packages found."
            dim "  Looked in:"
            for d in "${LOCAL_BUILD_DIRS[@]}"; do
                dim "    ${d}"
            done
            err "Nothing to deploy. Build something with proton-builder first."
        fi

        if command -v fzf >/dev/null 2>&1; then
            local picked
            picked=$(
                for p in "${candidates[@]}"; do
                    local name display
                    name="$(basename "$p")"
                    display="$(_read_display_name "${p}/compatibilitytool.vdf")"
                    printf '%s\t%s  %s\n' "$p" "$name" "${display:+(${display})}"
                done \
                | fzf \
                    --prompt="Package > " \
                    --header="Select a local Proton package to deploy" \
                    --with-nth=2 \
                    --delimiter=$'\t' \
                    --height=25% \
                    --border \
                || true
            )
            [[ -n "$picked" ]] || err "No package selected."
            src="$(printf '%s' "$picked" | cut -d$'\t' -f1)"
            src="${src%/}"
        else
            printf "\n  ${C_B}Select a local Proton package:${C_R}\n\n"
            PS3="  Package: "
            local i=1
            local -a labels=()
            for p in "${candidates[@]}"; do
                local name display
                name="$(basename "$p")"
                display="$(_read_display_name "${p}/compatibilitytool.vdf")"
                labels+=("${name}  ${display:+(${display})}")
            done
            local choice
            select choice in "${labels[@]}"; do
                [[ -z "$choice" ]] && continue
                for i in "${!labels[@]}"; do
                    [[ "${labels[$i]}" == "$choice" ]] && src="${candidates[$i]%/}" && break
                done
                [[ -n "$src" ]] && break
            done
            PS3=""
        fi
    fi

    [[ -d "$src" ]] || err "Package directory not found: ${src}"

    local dest_name
    dest_name="$(basename "$src")"
    local install_dir="${COMPAT_TOOLS_DIR}/${dest_name}"

    section "Deploying"
    msg2 "Source: ${src}"
    msg2 "Dest:   ${install_dir}"

    if [[ -d "$install_dir" ]]; then
        warn "Already exists: ${install_dir}"
        printf "  ${C_B}Overwrite? [y/N]:${C_R} "
        local ans
        read -r ans
        [[ "${ans,,}" =~ ^y ]] || { msg2 "Skipped."; return; }
        run rm -rf "$install_dir"
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "[dry-run] Would copy: ${src} → ${install_dir}"
        restart_reminder
        return
    fi

    run cp -a "$src" "$install_dir"

    local display_name
    display_name="$(_read_display_name "${install_dir}/compatibilitytool.vdf")"
    ok "Deployed: ${dest_name}"
    msg2 "Display name: ${display_name}"
    msg2 "Path:         ${install_dir}"

    restart_reminder
}

# ══════════════════════════════════════════════════════════════════════════════
#  Action: list — show installed tools
# ══════════════════════════════════════════════════════════════════════════════
action_list() {
    _resolve_compat_dir

    section "Installed Proton tools"
    printf "\n"

    local -a entries=()
    for d in "${COMPAT_TOOLS_DIR}"/*/; do
        [[ -d "$d" ]] || continue
        entries+=("$d")
    done

    if [[ ${#entries[@]} -eq 0 ]]; then
        msg2 "No tools found in ${COMPAT_TOOLS_DIR}"
        return
    fi

    printf "  ${C_B}%-36s  %-30s  %s${C_R}\n" "directory name" "display name" "size"
    printf "  %s\n" "$(printf '─%.0s' {1..78})"

    for d in "${entries[@]}"; do
        local name display_name size vdf
        name="$(basename "$d")"
        vdf="${d}/compatibilitytool.vdf"
        display_name="$(_read_display_name "$vdf")"
        size="$(du -sh "$d" 2>/dev/null | cut -f1)"
        printf "  ${C_CYN}%-36s${C_R}  %-30s  %s\n" \
               "$name" "$display_name" "$size"
    done
    printf "\n"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Action: remove — uninstall a Proton tool
# ══════════════════════════════════════════════════════════════════════════════
action_remove() {
    local target="${1:-$_REMOVE_NAME}"
    _resolve_compat_dir

    if [[ -n "$target" ]]; then
        # Name given on the command line
        local target_dir="${COMPAT_TOOLS_DIR}/${target}"
        [[ -d "$target_dir" ]] \
            || err "Not found in ${COMPAT_TOOLS_DIR}: ${target}"
    else
        # Interactive picker
        section "Remove a Proton tool"
        local -a entries=()
        for d in "${COMPAT_TOOLS_DIR}"/*/; do
            [[ -d "$d" ]] || continue
            entries+=("$d")
        done

        if [[ ${#entries[@]} -eq 0 ]]; then
            msg2 "No tools found in ${COMPAT_TOOLS_DIR} — nothing to remove."
            return
        fi

        local target_dir=""
        if command -v fzf >/dev/null 2>&1; then
            local picked
            picked=$(
                for d in "${entries[@]}"; do
                    local name display size
                    name="$(basename "$d")"
                    display="$(_read_display_name "${d}/compatibilitytool.vdf")"
                    size="$(du -sh "$d" 2>/dev/null | cut -f1)"
                    printf '%s\t%s  %s  (%s)\n' \
                           "$d" "$name" "${display:+(${display})}" "$size"
                done \
                | fzf \
                    --prompt="Remove > " \
                    --header="Select a Proton tool to remove" \
                    --with-nth=2 \
                    --delimiter=$'\t' \
                    --height=25% \
                    --border \
                || true
            )
            [[ -n "$picked" ]] || err "No tool selected."
            target_dir="$(printf '%s' "$picked" | cut -d$'\t' -f1)"
            target="$(basename "$target_dir")"
        else
            printf "\n  ${C_B}Select a tool to remove:${C_R}\n\n"
            PS3="  Remove: "
            local -a labels=()
            for d in "${entries[@]}"; do
                local name display size
                name="$(basename "$d")"
                display="$(_read_display_name "${d}/compatibilitytool.vdf")"
                size="$(du -sh "$d" 2>/dev/null | cut -f1)"
                labels+=("${name}  ${display:+(${display})}  (${size})")
            done
            local choice
            select choice in "${labels[@]}"; do
                [[ -z "$choice" ]] && continue
                for i in "${!labels[@]}"; do
                    [[ "${labels[$i]}" == "$choice" ]] \
                        && target_dir="${entries[$i]}" \
                        && target="$(basename "$target_dir")" \
                        && break
                done
                [[ -n "$target_dir" ]] && break
            done
            PS3=""
        fi

        [[ -n "$target_dir" ]] || err "No tool selected."
        local target_dir="${target_dir%/}"
    fi

    local target_dir="${COMPAT_TOOLS_DIR}/${target}"

    section "Remove"
    msg2 "Target: ${target_dir}"
    warn "This will permanently delete: ${target}"
    printf "  ${C_B}Are you sure? [y/N]:${C_R} "
    local ans
    read -r ans
    [[ "${ans,,}" =~ ^y ]] || { msg2 "Aborted."; return; }

    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "[dry-run] Would remove: ${target_dir}"
        restart_reminder
        return
    fi

    run rm -rf "$target_dir"
    ok "Removed: ${target}"

    restart_reminder
}

# ══════════════════════════════════════════════════════════════════════════════
#  Interactive main menu
# ══════════════════════════════════════════════════════════════════════════════

declare -A _MENU_DESC=(
    [install-ge]="install-ge      — Download & install latest GE-Proton"
    [install-url]="install-url     — Install from a custom URL (.tar.gz / .tar.xz / .tar.zst)"
    [deploy-local]="deploy-local    — Deploy a locally-built Proton package"
    [list]="list            — List all Proton tools in compatibilitytools.d"
    [remove]="remove          — Remove a Proton tool from compatibilitytools.d"
)
_MENU_KEYS=( install-ge install-url deploy-local list remove )

pick_action() {
    section "What would you like to do?"

    if command -v fzf >/dev/null 2>&1; then
        local picked
        picked=$(
            for k in "${_MENU_KEYS[@]}"; do
                printf '%s\t%s\n' "$k" "${_MENU_DESC[$k]}"
            done \
            | fzf \
                --prompt="Action > " \
                --header="proton-install — select an action" \
                --with-nth=2 \
                --delimiter=$'\t' \
                --height=25% \
                --border \
            || true
        )
        [[ -n "$picked" ]] || err "No action selected."
        ACTION="$(printf '%s' "$picked" | cut -d$'\t' -f1)"
    else
        printf "\n  ${C_B}Select an action:${C_R}\n\n"
        PS3="  Action: "
        local -a labels=()
        for k in "${_MENU_KEYS[@]}"; do
            labels+=("${_MENU_DESC[$k]}")
        done
        local choice
        select choice in "${labels[@]}"; do
            [[ -z "$choice" ]] && continue
            local i
            for i in "${!labels[@]}"; do
                [[ "${labels[$i]}" == "$choice" ]] \
                    && ACTION="${_MENU_KEYS[$i]}" && break
            done
            [[ -n "$ACTION" ]] && break
        done
        PS3=""
    fi

    ok "Selected: ${ACTION}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Entry point
# ══════════════════════════════════════════════════════════════════════════════
print_banner
check_required_deps

if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "DRY RUN mode — no changes will be made."
fi

# If no CLI action was given, present the interactive menu
if [[ -z "$ACTION" ]]; then
    pick_action
fi

case "$ACTION" in
    install-ge)
        action_install_ge
        ;;
    install-url)
        if [[ -z "$_INSTALL_URL" ]]; then
            printf "\n  ${C_B}Enter URL:${C_R} "
            read -r _INSTALL_URL
            [[ -n "$_INSTALL_URL" ]] || err "No URL provided."
        fi
        action_install_url "$_INSTALL_URL"
        ;;
    deploy-local)
        action_deploy_local "$_DEPLOY_PATH"
        ;;
    list)
        action_list
        ;;
    remove)
        action_remove "$_REMOVE_NAME"
        ;;
    *)
        err "Unknown action: ${ACTION}"
        ;;
esac
