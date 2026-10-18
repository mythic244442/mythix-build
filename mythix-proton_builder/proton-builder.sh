#!/usr/bin/env bash
# ╔═════════════════════════════════════════════════════════════════════════════╗
# ║      mythix-build  •  proton-builder  —  Delegated Proton Builds  v1.0.0   ║
# ║      Build GE-Proton or TKG-Proton using their own build systems          ║
# ╚═════════════════════════════════════════════════════════════════════════════╝
#
# "Delegated builds" means we clone the upstream project (GE-Proton or
# proton-tkg) and run *their* build scripts — we don't compile Wine/DXVK
# ourselves. The result is an identical build to what the upstream maintainer
# ships, but compiled locally on your machine.
#
# Both projects use containers (Podman/Docker) for a reproducible build
# environment, so the only hard dependency is a container engine.
#
# Usage:  ./proton-builder.sh [options]
#         ./proton-builder.sh --help
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
run()     { printf "${C_BLU}    \$${C_R} %s\n" "$*"; "$@"; }

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
    printf "  ║  :3 mythix-build  •  proton-builder                           ║\n"
    printf "  ║      Delegated Proton Builds  •  GE  •  TKG                  ║\n"
    printf "  ║                                                               ║\n"
    printf "  ╚═══════════════════════════════════════════════════════════════╝\n"
    printf "${C_R}\n"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Defaults & paths
# ══════════════════════════════════════════════════════════════════════════════
DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/mythix-proton_builder"
SRC_DIR="${DATA_DIR}/src"
BUILD_DIR="${DATA_DIR}/buildz/build-run"
INSTALL_DIR="${DATA_DIR}/buildz/install"

SOURCE=""                  # ge | tkg
CONTAINER_ENGINE=""        # auto-detected: podman or docker
JOBS="$(nproc)"
BUILD_NAME=""              # override build name
DRY_RUN=0
NONINTERACTIVE=0

# Upstream repos
GE_REPO_URL="https://github.com/GloriousEggroll/proton-ge-custom.git"
TKG_REPO_URL="https://github.com/Frogging-Family/wine-tkg-git.git"

# ══════════════════════════════════════════════════════════════════════════════
#  Usage
# ══════════════════════════════════════════════════════════════════════════════
print_usage() {
    cat <<USAGE
${C_B}Usage:${C_R} $0 [options]

${C_B}Source selection:${C_R}
  --source ge              Build GE-Proton from source (GloriousEggroll/proton-ge-custom)
  --source tkg             Build proton-tkg from source (Frogging-Family/wine-tkg-git)

${C_B}Build options:${C_R}
  --build-name NAME        Override the build name (default: auto from upstream)
  --jobs N                 Parallel build jobs (default: nproc = ${JOBS})
  --container-engine ENG   Force podman or docker (default: auto-detect)
  --dry-run                Show what would happen without building

${C_B}Maintenance:${C_R}
  --list                   List completed Proton builds
  --clean                  Remove source checkouts and build intermediates

${C_B}Interactive mode (no flags):${C_R}
  Running without flags drops into a menu.

${C_B}Examples:${C_R}
  $0                          # interactive menu
  $0 --source ge              # build latest GE-Proton
  $0 --source tkg             # build proton-tkg
  $0 --list                   # show completed builds
  $0 --dry-run --source ge    # preview GE-Proton build steps

-h, --help                    Show this help and exit
USAGE
}

# ══════════════════════════════════════════════════════════════════════════════
#  Argument parsing
# ══════════════════════════════════════════════════════════════════════════════
ACTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)
            [[ $# -ge 2 ]] || err "--source requires an argument (ge | tkg)"
            SOURCE="$2"; NONINTERACTIVE=1; shift 2 ;;
        --build-name)
            [[ $# -ge 2 ]] || err "--build-name requires an argument"
            BUILD_NAME="$2"; shift 2 ;;
        --jobs)
            [[ $# -ge 2 ]] || err "--jobs requires a number"
            JOBS="$2"; shift 2 ;;
        --container-engine)
            [[ $# -ge 2 ]] || err "--container-engine requires podman or docker"
            CONTAINER_ENGINE="$2"; shift 2 ;;
        --list)
            ACTION="list"; NONINTERACTIVE=1; shift ;;
        --clean)
            ACTION="clean"; NONINTERACTIVE=1; shift ;;
        --dry-run)
            DRY_RUN=1; shift ;;
        -h|--help)
            print_banner; print_usage; exit 0 ;;
        *)
            printf "Unknown option: %s\n" "$1" >&2
            print_usage; exit 1 ;;
    esac
done

# ══════════════════════════════════════════════════════════════════════════════
#  Dependency checks
# ══════════════════════════════════════════════════════════════════════════════
_detect_container_engine() {
    if [[ -n "$CONTAINER_ENGINE" ]]; then
        command -v "$CONTAINER_ENGINE" >/dev/null 2>&1 \
            || err "Container engine not found: ${CONTAINER_ENGINE}"
        return
    fi
    if command -v podman >/dev/null 2>&1; then
        CONTAINER_ENGINE="podman"
    elif command -v docker >/dev/null 2>&1; then
        CONTAINER_ENGINE="docker"
    else
        err "No container engine found. Install podman or docker.\n  sudo apt install podman   # Debian/Ubuntu\n  sudo dnf install podman   # Fedora"
    fi
}

check_deps() {
    local missing=()
    for cmd in git curl; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || err "Missing required tools: ${missing[*]}"
    _detect_container_engine
    ok "Container engine: ${CONTAINER_ENGINE}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Action: list — show completed builds
# ══════════════════════════════════════════════════════════════════════════════
action_list() {
    section "Completed Proton builds"
    printf "\n"

    if [[ ! -d "$INSTALL_DIR" ]]; then
        msg2 "No builds found (${INSTALL_DIR} does not exist)"
        return
    fi

    local -a entries=()
    for d in "${INSTALL_DIR}"/*/; do
        [[ -d "$d" ]] || continue
        entries+=("$d")
    done

    if [[ ${#entries[@]} -eq 0 ]]; then
        msg2 "No builds found in ${INSTALL_DIR}"
        return
    fi

    printf "  ${C_B}%-36s  %-12s  %s${C_R}\n" "build name" "size" "path"
    printf "  %s\n" "$(printf '─%.0s' {1..78})"

    for d in "${entries[@]}"; do
        local name size
        name="$(basename "$d")"
        size="$(du -sh "$d" 2>/dev/null | cut -f1)"
        printf "  ${C_CYN}%-36s${C_R}  %-12s  %s\n" "$name" "$size" "$d"
    done
    printf "\n"
    dim "  Deploy with: proton-install --deploy <path>"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Action: clean — remove source and build intermediates
# ══════════════════════════════════════════════════════════════════════════════
action_clean() {
    section "Clean build data"

    local total=0
    for d in "$SRC_DIR" "$BUILD_DIR"; do
        if [[ -d "$d" ]]; then
            local size
            size="$(du -sh "$d" 2>/dev/null | cut -f1)"
            msg2 "${d}  (${size})"
            total=1
        fi
    done

    if [[ "$total" -eq 0 ]]; then
        msg2 "Nothing to clean."
        return
    fi

    printf "\n"
    warn "This removes source checkouts and build intermediates."
    warn "Completed builds in ${INSTALL_DIR} are NOT affected."
    printf "  ${C_B}Proceed? [y/N]:${C_R} "
    local ans
    read -r ans
    [[ "${ans,,}" =~ ^y ]] || { msg2 "Aborted."; return; }

    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "[dry-run] Would remove: ${SRC_DIR}"
        warn "[dry-run] Would remove: ${BUILD_DIR}"
        return
    fi

    [[ -d "$SRC_DIR" ]]   && { rm -rf "$SRC_DIR";   ok "Removed: ${SRC_DIR}"; }
    [[ -d "$BUILD_DIR" ]] && { rm -rf "$BUILD_DIR"; ok "Removed: ${BUILD_DIR}"; }
}

# ══════════════════════════════════════════════════════════════════════════════
#  GE-Proton build
# ══════════════════════════════════════════════════════════════════════════════
build_ge() {
    section "GE-Proton — delegated build"

    local ge_src="${SRC_DIR}/proton-ge-custom"

    # ── Clone or update ──
    if [[ -d "$ge_src/.git" ]]; then
        msg "Updating existing GE-Proton source"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            warn "[dry-run] Would pull latest changes"
        else
            run git -C "$ge_src" fetch --all --tags
            # Checkout latest tag
            local latest_tag
            latest_tag=$(git -C "$ge_src" tag --sort=-v:refname | grep '^GE-Proton' | head -1)
            if [[ -n "$latest_tag" ]]; then
                run git -C "$ge_src" checkout "$latest_tag"
                ok "Checked out: ${latest_tag}"
            fi
            run git -C "$ge_src" submodule update --init --recursive
        fi
    else
        msg "Cloning GE-Proton source"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            warn "[dry-run] Would clone: ${GE_REPO_URL}"
        else
            mkdir -p "$SRC_DIR"
            run git clone --recurse-submodules "$GE_REPO_URL" "$ge_src"
            # Checkout latest release tag
            local latest_tag
            latest_tag=$(git -C "$ge_src" tag --sort=-v:refname | grep '^GE-Proton' | head -1)
            if [[ -n "$latest_tag" ]]; then
                run git -C "$ge_src" checkout "$latest_tag"
                run git -C "$ge_src" submodule update --init --recursive
                ok "Checked out: ${latest_tag}"
            fi
        fi
    fi

    # ── Resolve build name ──
    local version_name
    if [[ -n "$BUILD_NAME" ]]; then
        version_name="$BUILD_NAME"
    elif [[ -f "${ge_src}/VERSION" ]]; then
        version_name="$(cat "${ge_src}/VERSION")"
    else
        version_name="GE-Proton-localbuild"
    fi
    ok "Build name: ${version_name}"

    # ── Build output directory ──
    local build_obj="${BUILD_DIR}/ge-proton"
    mkdir -p "$build_obj"

    # ── Configure ──
    section "Configure"
    msg2 "Container engine: ${CONTAINER_ENGINE}"
    msg2 "Build directory:  ${build_obj}"
    msg2 "Jobs: ${JOBS}"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "[dry-run] Would run: ./configure.sh --container-engine=${CONTAINER_ENGINE} --build-name=${version_name}"
        warn "[dry-run] Would run: make -j${JOBS} dist"
        warn "[dry-run] Would install to: ${INSTALL_DIR}/${version_name}"
        return
    fi

    cd "$build_obj"
    run bash "${ge_src}/configure.sh" \
        --container-engine="$CONTAINER_ENGINE" \
        --build-name="$version_name"

    # ── Build ──
    section "Build"
    msg "This will take a while — building Wine, DXVK, VKD3D-Proton, and more..."
    msg2 "Building with ${JOBS} jobs inside ${CONTAINER_ENGINE} container"

    run make -j"$JOBS" dist

    ok "Build complete!"

    # ── Install to output directory ──
    section "Install"

    local dist_dir="${build_obj}/dist"
    local final_dir="${INSTALL_DIR}/${version_name}"

    if [[ -d "${dist_dir}/files" ]]; then
        # GE-Proton puts the goods in dist/files/
        mkdir -p "$final_dir"
        run cp -a "${dist_dir}/files/." "$final_dir/"

        # Copy Steam manifests from source if present
        for f in compatibilitytool.vdf toolmanifest.vdf proton; do
            [[ -f "${dist_dir}/${f}" ]] && cp -a "${dist_dir}/${f}" "$final_dir/"
            [[ -f "${ge_src}/${f}" ]]   && cp -a "${ge_src}/${f}" "$final_dir/" 2>/dev/null || true
        done
        # Copy the generated version template if configure created one
        [[ -f "${dist_dir}/version" ]] && cp -a "${dist_dir}/version" "$final_dir/"
    elif [[ -d "$dist_dir" ]]; then
        # Fallback: copy the whole dist directory
        mkdir -p "$final_dir"
        run cp -a "${dist_dir}/." "$final_dir/"
    else
        err "Build succeeded but dist/ directory not found in ${build_obj}"
    fi

    ok "Installed: ${final_dir}"
    printf "\n"
    msg2 "Deploy to Steam with:"
    dim "  proton-install --deploy \"${final_dir}\""
}

# ══════════════════════════════════════════════════════════════════════════════
#  TKG proton-tkg build
# ══════════════════════════════════════════════════════════════════════════════
build_tkg() {
    section "proton-tkg — delegated build"

    local tkg_src="${SRC_DIR}/wine-tkg-git"
    local tkg_dir="${tkg_src}/proton-tkg"

    # ── Clone or update ──
    if [[ -d "$tkg_src/.git" ]]; then
        msg "Updating existing wine-tkg-git source"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            warn "[dry-run] Would pull latest changes"
        else
            run git -C "$tkg_src" pull --rebase
        fi
    else
        msg "Cloning wine-tkg-git source"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            warn "[dry-run] Would clone: ${TKG_REPO_URL}"
        else
            mkdir -p "$SRC_DIR"
            run git clone "$TKG_REPO_URL" "$tkg_src"
        fi
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        section "Configuration"
        msg2 "Container engine: ${CONTAINER_ENGINE}"
        dim "  proton-tkg uses its own container logic via \$_no_container flag."
        dim "  By default it builds inside the Valve SDK container."
        warn "[dry-run] Would run: ./proton-tkg.sh"
        warn "[dry-run] in directory: ${tkg_dir}"
        return
    fi

    [[ -d "$tkg_dir" ]] || err "proton-tkg directory not found in clone: ${tkg_dir}"

    # ── Show config info ──
    section "Configuration"
    local cfg_file="${tkg_dir}/proton-tkg.cfg"
    if [[ -f "$cfg_file" ]]; then
        ok "Config: ${cfg_file}"
        msg2 "Edit this file to customise patches, Wine version, etc."
        msg2 "The build will use whatever is configured there."
    fi

    # ── Container mode info ──
    msg2 "Container engine: ${CONTAINER_ENGINE}"
    dim "  proton-tkg uses its own container logic via \$_no_container flag."
    dim "  By default it builds inside the Valve SDK container."

    # ── Build ──
    section "Build"
    msg "Running proton-tkg.sh — this will take a while..."
    msg2 "The script handles Wine, DXVK, VKD3D-Proton, and packaging."

    cd "$tkg_dir"
    run bash proton-tkg.sh

    ok "proton-tkg build complete!"

    # ── Find and copy output ──
    section "Locating build output"

    # proton-tkg typically installs directly to Steam's compatibilitytools.d
    # or leaves output in the proton-tkg directory. Let's check both.
    local found=0

    # Check if there's a build output we can copy to our install dir
    for d in "${tkg_dir}"/proton_tkg_*/; do
        [[ -d "$d" ]] || continue
        local name
        name="$(basename "$d")"
        local final_dir="${INSTALL_DIR}/${name}"
        mkdir -p "$final_dir"
        run cp -a "${d}/." "$final_dir/"
        ok "Installed: ${final_dir}"
        msg2 "Deploy to Steam with:"
        dim "  proton-install --deploy \"${final_dir}\""
        found=1
    done

    if [[ "$found" -eq 0 ]]; then
        msg2 "proton-tkg may have installed directly to Steam."
        msg2 "Check your compatibilitytools.d/ directory."
        dim "  proton-install --list"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  Interactive menu
# ══════════════════════════════════════════════════════════════════════════════
declare -A _MENU_DESC=(
    [ge]="ge              — Build GE-Proton from source (GloriousEggroll)"
    [tkg]="tkg             — Build proton-tkg from source (Frogging-Family)"
    [list]="list            — List completed Proton builds"
    [clean]="clean           — Remove source checkouts and build intermediates"
)
_MENU_KEYS=( ge tkg list clean )

pick_action() {
    section "What would you like to build?"

    if command -v fzf >/dev/null 2>&1; then
        local picked
        picked=$(
            for k in "${_MENU_KEYS[@]}"; do
                printf '%s\t%s\n' "$k" "${_MENU_DESC[$k]}"
            done \
            | fzf \
                --prompt="proton-builder > " \
                --header="Select a build source or action" \
                --with-nth=2 \
                --delimiter=$'\t' \
                --height=25% \
                --border \
            || true
        )
        [[ -n "$picked" ]] || err "No action selected."
        local key
        key="$(printf '%s' "$picked" | cut -d$'\t' -f1)"
        case "$key" in
            ge|tkg) SOURCE="$key" ;;
            *)      ACTION="$key" ;;
        esac
    else
        printf "\n  ${C_B}Select an option:${C_R}\n\n"
        printf "  ${C_CYN}1)${C_R} %s\n" "${_MENU_DESC[ge]}"
        printf "  ${C_CYN}2)${C_R} %s\n" "${_MENU_DESC[tkg]}"
        printf "  ${C_CYN}3)${C_R} %s\n" "${_MENU_DESC[list]}"
        printf "  ${C_CYN}4)${C_R} %s\n" "${_MENU_DESC[clean]}"
        printf "  ${C_CYN}q)${C_R}  Exit\n"
        printf "\n  ${C_B}Choice [1-4, q]:${C_R} "
        local choice
        read -r choice
        case "$choice" in
            1) SOURCE="ge" ;;
            2) SOURCE="tkg" ;;
            3) ACTION="list" ;;
            4) ACTION="clean" ;;
            q|Q|"") printf "\n  ${C_DIM}Goodbye :3${C_R}\n\n"; exit 0 ;;
            *) err "Invalid choice." ;;
        esac
    fi

    ok "Selected: ${SOURCE:-$ACTION}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Entry point
# ══════════════════════════════════════════════════════════════════════════════
print_banner
check_deps

if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "DRY RUN mode — no changes will be made."
fi

# Ensure data directories exist
mkdir -p "$SRC_DIR" "$BUILD_DIR" "$INSTALL_DIR"

# If no CLI flags, show interactive menu
if [[ -z "$SOURCE" ]] && [[ -z "$ACTION" ]]; then
    pick_action
fi

# Handle maintenance actions first
case "${ACTION:-}" in
    list)  action_list; exit 0 ;;
    clean) action_clean; exit 0 ;;
esac

# Validate source selection
case "$SOURCE" in
    ge)  build_ge ;;
    tkg) build_tkg ;;
    *)   err "Unknown source: ${SOURCE}. Use 'ge' or 'tkg'." ;;
esac
