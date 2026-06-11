#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Hybrid Wine/Neutron Installer  —  mythix edition
# ============================================================================
# Merges a custom Wine build over a Neutron package base, producing a
# single hybrid tool that can be registered with Steam as a compatibility
# tool or used standalone via  ./neutron run <game.exe>.
#
# Usage:
#   ./wine-neutron_hybrid-v1.0.0.sh [OPTIONS]
#
# All interactive prompts can be bypassed with CLI flags for headless/CI use.
# ============================================================================

VERSION="v1.0.0"
DRY_RUN=0
VERBOSE=0
DEBUG=0

# ── CLI-settable inputs (bypass interactive prompts when provided) ────────────
CLI_WINE_SRC=""
CLI_NEUTRON_SRC=""
CLI_TOOL_NAME=""
CLI_INSTALL_DIR=""
CLI_INSTALL_MODE=""   # steam | steam-pick | custom
CLI_PROTONFIXES_DIR=""
UNINSTALL_MODE=0

# ============================================================================
# Utilities & Progress Management
# ============================================================================

# ── Terminal colours ─────────────────────────────────────────────────────────
C_RESET='\e[0m'
C_BOLD='\e[1m'
C_GREEN='\e[1;32m'
C_BLUE='\e[1;34m'
C_CYAN='\e[1;36m'
C_YELLOW='\e[1;33m'
C_RED='\e[1;31m'
C_DIM='\e[2m'
C_MAGENTA='\e[1;35m'

msg()   { printf "${C_GREEN}==>${C_RESET} ${C_BOLD}%s${C_RESET}\n" "$*"; }
info()  { printf "${C_BLUE}  ->${C_RESET} %s\n" "$*"; }
good()  { printf "${C_GREEN}  ✓${C_RESET} %s\n" "$*"; }
warn()  { printf "${C_YELLOW}  ⚠ WARN:${C_RESET} %s\n" "$*" >&2; }
error() { printf "${C_RED}  ✖ ERROR:${C_RESET} %s\n" "$*" >&2; exit 1; }
step()  {
  local n="$1" total="$2"; shift 2
  printf "\n${C_CYAN}${C_BOLD}[%s/%s]${C_RESET}${C_BOLD} %s${C_RESET}\n" "$n" "$total" "$*"
  printf "${C_DIM}%s${C_RESET}\n" "$(printf '─%.0s' {1..60})"
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf "${C_DIM}[DRY-RUN]${C_RESET} %s\n" "$*"
  else
    [ "$VERBOSE" -eq 1 ] && printf "${C_DIM}[RUN]${C_RESET} %s\n" "$*"
    eval "$@"
  fi
}

# rsync wrapper: suppress per-file progress output when a GUI bar is open
# (flooding the progress pipe with rsync's output garbles the GUI display)
run_rsync() {
  if [ "$GUI_MODE" != "none" ]; then
    eval "$@" --no-progress 2>/dev/null || eval "$@" 2>/dev/null || true
  else
    eval "$@" || true
  fi
}

pick_dir() {
  local prompt="${1:-Select directory}" start="${2:-$HOME}" choice=""
  if command -v yad >/dev/null 2>&1; then
    choice=$(yad --file-selection --directory \
                 --title="$prompt" \
                 --filename="$start/" \
                 --width=700 --height=500 \
                 2>/dev/null || echo "")
  elif command -v zenity >/dev/null 2>&1; then
    choice=$(zenity --file-selection --directory \
                    --title="$prompt" \
                    --filename="$start/" \
                    --width=700 --height=500 \
                    2>/dev/null || echo "")
  else
    read -rp "  $prompt: " choice
  fi
  echo "$choice"
}

# ── Terminal progress bar ─────────────────────────────────────────────────────
TERM_BAR_WIDTH=50

_draw_term_bar() {
  local pct="$1" label="$2"
  local filled=$(( pct * TERM_BAR_WIDTH / 100 ))
  local empty=$(( TERM_BAR_WIDTH - filled ))
  local bar
  bar="$(printf '%0.s█' $(seq 1 $filled))$(printf '%0.s░' $(seq 1 $empty))"
  printf "\r  ${C_CYAN}%3d%%${C_RESET} [${C_GREEN}%s${C_RESET}] ${C_DIM}%-45s${C_RESET}" \
         "$pct" "$bar" "$label"
  if [ "$pct" -ge 100 ]; then printf "\n"; fi
}

# ── GUI progress (yad / zenity) ───────────────────────────────────────────────
PROGRESS_PIPE=""
PROGRESS_FD_OPEN=0
GUI_MODE="none"
_CURRENT_STEP_LABEL=""

cleanup_progress() {
  if [ "$PROGRESS_FD_OPEN" -eq 1 ]; then
    exec 3>&- 2>/dev/null || true
    PROGRESS_FD_OPEN=0
  fi
  [ -n "$PROGRESS_PIPE" ] && [ -p "$PROGRESS_PIPE" ] && rm -f "$PROGRESS_PIPE" 2>/dev/null || true
}

# cleanup_staging: called on exit to remove the temp build directory
# Only cleans up if the variable is set and the dir exists
cleanup_staging() {
  if [ -n "${STAGING_DIR:-}" ] && [ -d "${STAGING_DIR:-}" ]; then
    info "Cleaning up staging directory…"
    rm -rf "$STAGING_DIR" 2>/dev/null || true
  fi
}

cleanup_all() {
  cleanup_progress
  cleanup_staging
}

init_progress() {
  if command -v yad >/dev/null 2>&1; then
    GUI_MODE="yad"
  elif command -v zenity >/dev/null 2>&1; then
    GUI_MODE="zenity"
  else
    GUI_MODE="none"
    echo
    return
  fi

  PROGRESS_PIPE=$(mktemp -u)
  mkfifo "$PROGRESS_PIPE"

  case "$GUI_MODE" in
    yad)
      yad --progress \
          --title="Hybrid Wine/Neutron Installer  v${VERSION}" \
          --text="Initialising…" \
          --width=680 --height=120 --center \
          --no-cancel --auto-close \
          --bar-color='#5dade2' \
          < "$PROGRESS_PIPE" &
      ;;
    zenity)
      zenity --progress \
             --title="Hybrid Wine/Neutron Installer  v${VERSION}" \
             --text="Initialising…" \
             --width=680 --height=120 \
             --no-cancel --auto-close \
             < "$PROGRESS_PIPE" &
      ;;
  esac

  exec 3>"$PROGRESS_PIPE"
  PROGRESS_FD_OPEN=1
}

# update_progress <percent> <action> [step_label]
update_progress() {
  local pct="$1" action="$2"
  local step_label="${3:-$_CURRENT_STEP_LABEL}"
  local display_text
  if [ -n "$step_label" ]; then
    display_text="[${step_label}]  ${action}"
    _CURRENT_STEP_LABEL="$step_label"
  else
    display_text="$action"
  fi

  if [ "$GUI_MODE" = "none" ]; then
    _draw_term_bar "$pct" "$display_text"
  else
    [ "$PROGRESS_FD_OPEN" -eq 1 ] && {
      echo "$pct"
      echo "# ${display_text}"
    } >&3 2>/dev/null || true
  fi
}

finish_progress() {
  if [ "$GUI_MODE" = "none" ]; then
    _draw_term_bar 100 "Installation complete!"
    echo
  elif [ "$PROGRESS_FD_OPEN" -eq 1 ]; then
    echo "100" >&3 2>/dev/null || true
    echo "# ✓  Installation complete!" >&3 2>/dev/null || true
  fi
  cleanup_progress
}

trap cleanup_all EXIT

# ============================================================================
# Dependency Pre-flight Check
# ============================================================================

check_deps() {
  local missing=()
  local required=(rsync file python3 find bash)
  for cmd in "${required[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  # GUI is optional but warn if neither is available
  if ! command -v yad >/dev/null 2>&1 && ! command -v zenity >/dev/null 2>&1; then
    warn "Neither 'yad' nor 'zenity' found — using terminal-only mode (no GUI dialogs)"
  fi

  if [ "${#missing[@]}" -gt 0 ]; then
    printf "${C_RED}  ✖ ERROR:${C_RESET} Missing required tools: %s\n" "${missing[*]}" >&2
    printf "  Install them and re-run.  On Debian/Ubuntu:\n" >&2
    printf "    sudo apt install rsync python3 file\n" >&2
    exit 1
  fi
}

# ============================================================================
# Uninstall Helper
# ============================================================================

do_uninstall() {
  # Locate the tool by reading its install receipt, or accept --name + --install-dir
  local name="${CLI_TOOL_NAME:-}"
  local idir="${CLI_INSTALL_DIR:-}"

  if [ -z "$name" ]; then
    read -rp "  Tool name to uninstall [wine-neutron_mythix]: " name
    name="${name:-wine-neutron_mythix}"
  fi

  # Search known Steam dirs + custom dir
  local found_path=""
  local search_dirs=(
    "$HOME/.steam/debian-installation/compatibilitytools.d"
    "$HOME/.steam/steam/compatibilitytools.d"
    "$HOME/.local/share/Steam/compatibilitytools.d"
    "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/compatibilitytools.d"
  )
  [ -n "$idir" ] && search_dirs=("$idir" "${search_dirs[@]}")

  for d in "${search_dirs[@]}"; do
    if [ -d "${d}/${name}" ]; then
      found_path="${d}/${name}"
      break
    fi
  done

  if [ -z "$found_path" ]; then
    error "Could not find '${name}' in any known location. Use --install-dir to specify."
  fi

  printf "${C_YELLOW}  ⚠${C_RESET}  About to remove: ${C_BOLD}%s${C_RESET}\n" "$found_path"
  read -rp "  Confirm uninstall? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { info "Uninstall cancelled."; exit 0; }

  rm -rf "$found_path"
  good "Removed: $found_path"
  printf "\n  ${C_DIM}Restart Steam to deregister the tool from the compat list.${C_RESET}\n\n"
  exit 0
}

# ============================================================================
# Argument Parsing
# ============================================================================

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)       DRY_RUN=1; shift ;;
    --verbose)       VERBOSE=1; shift ;;
    --debug)         DEBUG=1; shift ;;
    --uninstall)     UNINSTALL_MODE=1; shift ;;
    --wine-src)      CLI_WINE_SRC="$2"; shift 2 ;;
    --neutron-src)   CLI_NEUTRON_SRC="$2"; shift 2 ;;
    --name)          CLI_TOOL_NAME="$2"; shift 2 ;;
    --install-dir)   CLI_INSTALL_DIR="$2"; CLI_INSTALL_MODE="custom"; shift 2 ;;
    --install-mode)  CLI_INSTALL_MODE="$2"; shift 2 ;;  # steam|steam-pick|custom
    --protonfixes-dir)  CLI_PROTONFIXES_DIR="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF

${C_BOLD}Hybrid Wine/Neutron Installer  —  mythix edition  v${VERSION}${C_RESET}

Usage: $0 [OPTIONS]

${C_BOLD}Build options:${C_RESET}
  --wine-src   <dir>    Path to the custom Wine build directory
  --neutron-src <dir>   Path to the Neutron package directory
  --name       <name>   Tool name (default: wine-neutron_mythix)
  --protonfixes-dir <dir>  Path to a protonfixes source (umu-protonfixes, plain checkout, etc.)

${C_BOLD}Install options:${C_RESET}
  --install-mode <mode> steam | steam-pick | custom
  --install-dir  <dir>  Parent directory for custom installs
                        (implies --install-mode custom)

${C_BOLD}Runtime options:${C_RESET}
  --dry-run             Show commands without executing
  --verbose             Print every command before running it
  --debug               Dump Neutron lib/wine layout after install

${C_BOLD}Maintenance:${C_RESET}
  --uninstall           Remove a previously installed tool
                        (use --name and optionally --install-dir to target it)
  -h, --help            Show this help

${C_BOLD}Standalone launcher env vars (set before  ./neutron run):${C_RESET}
  MYTHIX_PREFIX          Exact prefix path to use for this game
                        (default: ~/.wine-neutron-pfx shared prefix)
  WINE_USE_START        Set to 1 for launcher-wrapped games (e.g. GTA IV)
  PROTON_LOG            Set to 1 for verbose Wine debug log in /tmp/
  DXVK_HUD             Set to 1 for DXVK overlay
  WINEARCH              win64 (default) or win32

EOF
      exit 0
      ;;
    *) warn "Unknown argument: $1"; shift ;;
  esac
done

clear
printf '\e[1;35m'
cat <<'WOLF'
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
printf '\n'
printf '  ╔══════════════════════════════════════════════════════════════╗\n'
printf '  ║                                                              ║\n'
printf '  ║  🍷  Hybrid Wine/Neutron Installer  —  mythix edition          ║\n'
printf '  ║      merge any Wine build over any Neutron base               ║\n'
printf '  ║                                                              ║\n'
printf '  ╚══════════════════════════════════════════════════════════════╝\n'
printf '\e[0m\n'
printf "  \e[2mVersion %s   •   Neutron-First Overlay build\e[0m\n\n" "$VERSION"

# ── Dependency check (fail fast before touching anything) ────────────────────
check_deps

# ── Uninstall mode ────────────────────────────────────────────────────────────
[ "$UNINSTALL_MODE" -eq 1 ] && do_uninstall

# ============================================================================
# PRE-FLIGHT: Collect ALL user input before starting the progress bar.
# This ensures the progress bar/GUI window stays on top during the actual
# build work and is never obscured by file picker dialogs.
# ============================================================================

printf "${C_BOLD}  Pre-flight: gathering inputs…${C_RESET}\n\n"

# ── Step 1 inputs: Wine source ────────────────────────────────────────────────
if [ -n "$CLI_WINE_SRC" ]; then
  WINE_SRC="$CLI_WINE_SRC"
  good "Wine source (CLI): $WINE_SRC"
else
  printf "  ${C_BLUE}Select your custom Wine build directory${C_RESET}\n"
  WINE_SRC=$(pick_dir "Select Wine Build Directory" "$HOME/wine-custom")
fi
[ -z "$WINE_SRC" ]    && error "Wine directory required"
[ ! -d "$WINE_SRC" ]  && error "Wine directory does not exist: $WINE_SRC"
good "Wine source: $WINE_SRC"

# ── Step 1 inputs: Neutron source ──────────────────────────────────────────────
if [ -n "$CLI_NEUTRON_SRC" ]; then
  NEUTRON_SRC="$CLI_NEUTRON_SRC"
  good "Neutron source (CLI): $NEUTRON_SRC"
else
  printf "  ${C_BLUE}Select your Neutron package source directory${C_RESET}\n"
  NEUTRON_SRC=$(pick_dir "Select Neutron Package Directory" \
    "$HOME/.steam/debian-installation/compatibilitytools.d")
fi
[ -z "$NEUTRON_SRC" ]   && error "Neutron directory required"
[ ! -d "$NEUTRON_SRC" ] && error "Neutron directory does not exist: $NEUTRON_SRC"
good "Neutron source: $NEUTRON_SRC"

# ── Step 3 inputs: tool name ──────────────────────────────────────────────────
if [ -n "$CLI_TOOL_NAME" ]; then
  TOOL_NAME="$CLI_TOOL_NAME"
else
  read -rp "  Tool name [wine-neutron_mythix]: " TOOL_NAME
  TOOL_NAME="${TOOL_NAME:-wine-neutron_mythix}"
fi
good "Tool name: $TOOL_NAME"

# ── Step 5 inputs: optional protonfixes ──────────────────────────────────────
# Accepts any protonfixes directory — umu-protonfixes build, a standalone
# protonfixes checkout, or any directory containing a protonfixes/ subfolder.
PROTONFIXES_FOUND=0
PROTONFIXES_SRC=""

# Helper: check if a directory looks like a usable protonfixes source
_is_protonfixes_dir() {
  local d="$1"
  # Accept: the dir itself has game fixes (gamefixes/ or __init__.py),
  # OR it's a umu-protonfixes repo with a build/ subdir
  [ -d "$d/gamefixes" ]   && return 0
  [ -f "$d/__init__.py" ] && return 0
  [ -d "$d/build" ]       && return 0
  [ -d "$d/protonfixes" ] && return 0
  return 1
}

if [ -n "$CLI_PROTONFIXES_DIR" ]; then
  if _is_protonfixes_dir "$CLI_PROTONFIXES_DIR"; then
    PROTONFIXES_SRC="$CLI_PROTONFIXES_DIR"
    PROTONFIXES_FOUND=1
    good "protonfixes source (CLI): $PROTONFIXES_SRC"
  else
    warn "--protonfixes-dir path doesn't look like a protonfixes source — skipping"
  fi
else
  _PF_SEARCH_PATHS=(
    "$HOME/umu-protonfixes"
    "$HOME/protonfixes"
    "$HOME/projects/umu-protonfixes"
    "$HOME/projects/protonfixes"
    "$HOME/git/umu-protonfixes"
    "$HOME/git/protonfixes"
    "$(dirname "$WINE_SRC")/umu-protonfixes"
    "$(dirname "$WINE_SRC")/protonfixes"
    "${NEUTRON_SRC}/protonfixes"
  )
  for _p in "${_PF_SEARCH_PATHS[@]}"; do
    if [ -d "$_p" ] && _is_protonfixes_dir "$_p"; then
      PROTONFIXES_SRC="$_p"; PROTONFIXES_FOUND=1
      good "Found protonfixes: $_p"
      break
    fi
  done
  if [ "$PROTONFIXES_FOUND" -eq 0 ]; then
    info "No protonfixes directory found automatically"
    read -rp "  Specify a protonfixes path? [y/N]: " _ans
    if [[ "$_ans" =~ ^[Yy]$ ]]; then
      PROTONFIXES_SRC=$(pick_dir "Select protonfixes Directory" "$HOME")
      if [ -d "${PROTONFIXES_SRC:-}" ] && _is_protonfixes_dir "$PROTONFIXES_SRC"; then
        PROTONFIXES_FOUND=1
        good "Using protonfixes: $PROTONFIXES_SRC"
      else
        warn "Directory doesn't look like a protonfixes source — skipping"
        PROTONFIXES_SRC=""
      fi
    fi
  fi
fi

# ── Step 9 inputs: install destination ───────────────────────────────────────
pick_install_mode() {
  local choice=""
  if command -v yad >/dev/null 2>&1; then
    choice=$(yad --list \
      --title="Install Destination" \
      --text="Where would you like to install <b>${TOOL_NAME}</b>?" \
      --column="Mode" --column="Description" \
      --width=640 --height=300 --center \
      --no-headers \
      "steam"      "Auto-detect Steam compatibilitytools.d (default)" \
      "steam-pick" "Pick a Steam compatibilitytools.d manually" \
      "custom"     "Install into any directory of your choice" \
      2>/dev/null | cut -d'|' -f1 || echo "")
  elif command -v zenity >/dev/null 2>&1; then
    choice=$(zenity --list \
      --title="Install Destination" \
      --text="Where would you like to install ${TOOL_NAME}?" \
      --column="Mode" --column="Description" \
      --width=640 --height=300 \
      "steam"      "Auto-detect Steam compatibilitytools.d (default)" \
      "steam-pick" "Pick a Steam compatibilitytools.d manually" \
      "custom"     "Install into any directory of your choice" \
      2>/dev/null | cut -d'|' -f1 || echo "")
  else
    echo
    echo "  Install destination:"
    echo "    1) steam      – Auto-detect Steam compatibilitytools.d"
    echo "    2) steam-pick – Pick a Steam compatibilitytools.d manually"
    echo "    3) custom     – Install into any directory of your choice"
    echo
    read -rp "  Choice [1/2/3, default=1]: " raw
    case "$raw" in
      2) choice="steam-pick" ;;
      3) choice="custom" ;;
      *) choice="steam" ;;
    esac
  fi
  case "$choice" in steam-pick|custom) ;; *) choice="steam" ;; esac
  echo "$choice"
}

INSTALL_IS_STEAM=1
INSTALL_DIR=""

if [ -n "$CLI_INSTALL_MODE" ]; then
  INSTALL_MODE="$CLI_INSTALL_MODE"
else
  INSTALL_MODE=$(pick_install_mode)
fi
good "Install mode: $INSTALL_MODE"

# Resolve the install directory based on mode — all picker calls happen here,
# before init_progress, so no GUI window ordering issues.
_STEAM_DIRS=(
  "$HOME/.steam/debian-installation/compatibilitytools.d"
  "$HOME/.steam/steam/compatibilitytools.d"
  "$HOME/.local/share/Steam/compatibilitytools.d"
  "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/compatibilitytools.d"
)

case "$INSTALL_MODE" in
  steam)
    for _d in "${_STEAM_DIRS[@]}"; do
      if [ -d "$(dirname "$_d")" ]; then
        INSTALL_DIR="$_d"; break
      fi
    done
    if [ -z "$INSTALL_DIR" ]; then
      warn "Steam not found automatically — switching to manual picker"
      INSTALL_MODE="steam-pick"
    fi
    ;;&   # fall through ONLY on empty INSTALL_DIR

  steam-pick)
    if [ -z "$INSTALL_DIR" ]; then
      _START="$HOME"
      [ -n "${SUDO_USER:-}" ] && _START="/home/$SUDO_USER"
      INSTALL_DIR=$(pick_dir "Select Steam compatibilitytools.d Directory" "$_START")
      [ -z "$INSTALL_DIR" ] || [ ! -d "$INSTALL_DIR" ] && \
        error "No valid Steam directory selected."
    fi
    ;;

  custom)
    INSTALL_IS_STEAM=0
    if [ -n "$CLI_INSTALL_DIR" ]; then
      INSTALL_DIR="$CLI_INSTALL_DIR"
    else
      _START="$HOME"
      [ -n "${SUDO_USER:-}" ] && _START="/home/$SUDO_USER"
      INSTALL_DIR=$(pick_dir "Select Install Parent Directory" "$_START")
      [ -z "$INSTALL_DIR" ] && error "No directory selected."
    fi
    ;;
esac

mkdir -p "$INSTALL_DIR"
FINAL_PATH="${INSTALL_DIR}/${TOOL_NAME}"
good "Install path: $FINAL_PATH"
echo

# ── All user input collected — NOW start the progress bar ────────────────────
printf "  ${C_DIM}Starting build…${C_RESET}\n"
init_progress
update_progress 1 "Installer starting up…" "Init"
sleep 1

# ============================================================================
# Step 1: Detect Wine Layout & Read Neutron Version
# ============================================================================

step 1 9 "Detect Source Layouts"
update_progress 5 "Auto-detecting Wine directory layout…" "1/9 • Layout detection"

WINE_ROOT=""
if [ -d "${WINE_SRC}/bin" ]; then
  WINE_ROOT="$WINE_SRC"
  info "Layout: standard  (bin/ at root)"
elif [ -d "${WINE_SRC}/files/bin" ]; then
  WINE_ROOT="${WINE_SRC}/files"
  info "Layout: Wine-GE   (files/bin/)"
elif [ -d "${WINE_SRC}/dist/bin" ]; then
  WINE_ROOT="${WINE_SRC}/dist"
  info "Layout: dist       (dist/bin/)"
else
  error "Cannot find Wine binaries in $WINE_SRC (no bin/, files/bin/, or dist/bin/)"
fi
[ ! -d "${WINE_ROOT}/bin" ] && error "Wine root detected but bin/ is missing: ${WINE_ROOT}/bin"

BIN_FILES=$(ls "${WINE_ROOT}/bin" 2>/dev/null | wc -l)
good "Wine root: $WINE_ROOT  ($BIN_FILES binaries)"

# ── Detect unified WoW64 vs split build ──────────────────────────────────────
# Wine 10.6+ introduced a "unified WoW64" architecture where a single wine
# binary handles both 32-bit and 64-bit processes through an internal thunking
# layer (wow64.dll / wow64cpu.dll). Builds using this architecture have NO
# separate wine64 binary, or wine64 is just a symlink back to wine.
#
# The unified layer has a known issue under the Steam Runtime pressure-vessel
# container: games with 32-bit launchers (even if the main game is 64-bit)
# fault at the WoW64 address space boundary (~0x6FFFF...) immediately at
# process init, triggering the Wine debugger before any game code runs.
# Split builds (separate wine + wine64) are unaffected.
WINE_IS_UNIFIED_WOW64=0
WINE_HAS_WINE64=0

if [ -f "${WINE_ROOT}/bin/wine64" ]; then
  if [ -L "${WINE_ROOT}/bin/wine64" ]; then
    # wine64 is a symlink — check if it points back to wine (unified)
    _target=$(readlink "${WINE_ROOT}/bin/wine64")
    if [[ "$_target" == "wine" ]] || [[ "$_target" == "./wine" ]]; then
      WINE_IS_UNIFIED_WOW64=1
    else
      WINE_HAS_WINE64=1
    fi
    unset _target
  else
    WINE_HAS_WINE64=1   # real separate wine64 binary — split build
  fi
else
  WINE_IS_UNIFIED_WOW64=1   # no wine64 at all — unified build
fi

if [ "$WINE_IS_UNIFIED_WOW64" -eq 1 ]; then
  printf "\n"
  warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  warn "  Unified WoW64 Wine build detected (no separate wine64)"
  warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  warn ""
  warn "  Wine 10.6+ unified WoW64 has a known issue under the Steam"
  warn "  Runtime: games with 32-bit launchers (even 64-bit games)"
  warn "  fault at the WoW64 address boundary immediately at launch,"
  warn "  triggering the Wine debugger before any game code runs."
  warn "  Symptom: 'Unhandled page fault at 0x00006FFFF...' in logs."
  warn ""
  warn "  RECOMMENDED: use a Wine build that ships a real wine64"
  warn "  binary (split layout), or build Wine with:"
  warn "    --enable-archs=i386,x86_64"
  warn ""
  warn "  You can continue, but affected games will crash at launch."
  warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "\n"
  read -rp "  Continue with unified WoW64 build anyway? [y/N]: " _wow64_ans
  [[ "$_wow64_ans" =~ ^[Yy]$ ]] || { info "Aborted — please use a split Wine build."; exit 0; }
  printf "\n"
else
  good "Wine build: split layout (wine + wine64)  ✓"
fi

update_progress 7 "Reading Neutron version file…" "1/9 • Layout detection"

NEUTRON_VERSION="Unknown"
if [ -f "${NEUTRON_SRC}/version" ]; then
  NEUTRON_VERSION=$(head -n1 "${NEUTRON_SRC}/version" | awk '{print $NF}')
  good "Neutron version: $NEUTRON_VERSION"
else
  warn "No version file in Neutron source — will generate one later"
fi
echo

# ============================================================================
# Step 2: Create Staging Environment & Copy Neutron Base
# ============================================================================

step 2 9 "Create Staging Environment"
update_progress 10 "Creating temporary staging directory…" "2/9 • Staging"

STAGING_DIR="${HOME}/.hybrid-staging/${TOOL_NAME}.$$"
run "mkdir -p \"$STAGING_DIR\""
good "Staging directory: $STAGING_DIR"

update_progress 14 "Copying Neutron base tree into staging (rsync)…" "2/9 • Staging"
info "This may take a moment depending on Neutron package size…"

run_rsync "rsync --exclude='user_settings.py' --progress -a -h \
     \"${NEUTRON_SRC}/\" \"${STAGING_DIR}/\""

good "Neutron base copied."

# ── Detect Neutron internal dist inside staging ────────────────────────────────
# FIX: previously both branches tested [ -d "${STAGING_DIR}" ] which is always
# true — they never checked the actual subdirectory.
if [ -d "${STAGING_DIR}/files" ]; then
  NEUTRON_DIST="${STAGING_DIR}/files"
elif [ -d "${STAGING_DIR}/dist" ]; then
  NEUTRON_DIST="${STAGING_DIR}/dist"
else
  # Neither exists yet; default to 'files' — it will be created by the overlay steps
  NEUTRON_DIST="${STAGING_DIR}/files"
  mkdir -p "$NEUTRON_DIST"
  info "No files/ or dist/ in staging yet — created files/ as default"
fi

good "Neutron dist: ${NEUTRON_DIST}"
echo

# ============================================================================
# Step 5: Wine Overlay — DLLs, .so Libraries, Binaries
# ============================================================================

step 3 9 "Wine Overlay  (DLLs · .so libs · binaries)"
update_progress 22 "Preparing Wine architecture directories…" "3/9 • Wine overlay"
# Architecture Directories
ARCH_DIRS=(
  "${NEUTRON_DIST}/lib/wine/x86_64-windows"
  "${NEUTRON_DIST}/lib/wine/x86_64-unix"
  "${NEUTRON_DIST}/lib/wine/i386-windows"
  "${NEUTRON_DIST}/lib/wine/i386-unix"
)
for d in "${ARCH_DIRS[@]}"; do mkdir -p "$d"; done

# Create lib64 directories and symlink lib contents
create_lib64_symlinks() {
  local base_dir="$1"
  local lib_dir="${base_dir}/lib"
  local lib64_dir="${base_dir}/lib64"

  if [ ! -d "$lib_dir" ]; then
    info "Skipping lib64 creation: $lib_dir does not exist"
    return
  fi

  info "Creating lib64 directory and symlinking: $lib64_dir"
  mkdir -p "$lib64_dir"

  # Symlink all contents from lib to lib64
  find "$lib_dir" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) | while read -r item; do
    local basename=$(basename "$item")
    local target="${lib64_dir}/${basename}"

    # Skip if symlink already exists and points to correct location
    if [ -L "$target" ] && [ "$(readlink "$target")" = "../lib/${basename}" ]; then
      continue
    fi

    # Create relative symlink
    ln -sf "../lib/${basename}" "$target"
    info "  Linked: lib64/${basename} -> ../lib/${basename}"
  done
}

# Apply lib64 symlinks at Neutron distribution root
# This creates NEUTRON_DIST/lib64 with symlinks to NEUTRON_DIST/lib
create_lib64_symlinks "$NEUTRON_DIST"

# Overlay Function
overlay_wine_dir() {
  local src="$1"
  local dst="$2"

  if [ ! -d "$src" ]; then return; fi

  info "Overlay: $src → $dst"

  # 1. Unix (.so) - Copy All
  if [[ "$dst" == *"unix"* ]]; then
    find "$src" -maxdepth 1 -type f -name "*.so" | while read -r file; do
      run "cp -f \"$file\" \"$dst/\""
    done
    return
  fi

  # 2. Windows (.dll) - Selective Copy
  find "$src" -maxdepth 1 -type f -iname "*.dll" | while read -r file; do
    filename=$(basename "$file")

    # BLACKLIST: Keep Neutron versions of these
    if [[ "$filename" == "vrclient"* ]] || \
       [[ "$filename" == "openvr"* ]] || \
       [[ "$filename" == "lsteamclient"* ]] || \
       [[ "$filename" == "steamclient"* ]] || \
       [[ "$filename" == "steam.exe" ]]; then
       continue
    fi

    # CRITICAL: Force copy winevulkan and vulkan-1
    # This fixes "No adapters found" / DXVK init failure
    run "cp -f \"$file\" \"$dst/\""
  done

  # Copy Executables
  find "$src" -maxdepth 1 -type f -iname "*.exe" | while read -r file; do
      run "cp -f \"$file\" \"$dst/\""
  done
}

update_progress 25 "Overlaying Wine DLLs and .so modules over Neutron…" "3/9 • Wine overlay"
# Execute Overlay
if [ -d "${WINE_ROOT}/lib/wine/x86_64-windows" ]; then
    # Unified Layout
    overlay_wine_dir "${WINE_ROOT}/lib/wine/x86_64-windows" "${NEUTRON_DIST}/lib/wine/x86_64-windows"
    overlay_wine_dir "${WINE_ROOT}/lib/wine/x86_64-unix"    "${NEUTRON_DIST}/lib/wine/x86_64-unix"
    overlay_wine_dir "${WINE_ROOT}/lib/wine/i386-windows"   "${NEUTRON_DIST}/lib/wine/i386-windows"
    overlay_wine_dir "${WINE_ROOT}/lib/wine/i386-unix"      "${NEUTRON_DIST}/lib/wine/i386-unix"
elif [ -d "${WINE_ROOT}/lib64/wine" ]; then
    # Split Layout
    overlay_wine_dir "${WINE_ROOT}/lib64/wine" "${NEUTRON_DIST}/lib/wine/x86_64-windows"
    overlay_wine_dir "${WINE_ROOT}/lib64/wine" "${NEUTRON_DIST}/lib/wine/x86_64-unix"
    if [ -d "${WINE_ROOT}/lib/wine" ]; then
        overlay_wine_dir "${WINE_ROOT}/lib/wine" "${NEUTRON_DIST}/lib/wine/i386-windows"
        overlay_wine_dir "${WINE_ROOT}/lib/wine" "${NEUTRON_DIST}/lib/wine/i386-unix"
    fi
else
    # Minimal Layout
    if [ -d "${WINE_ROOT}/lib/wine" ]; then
        overlay_wine_dir "${WINE_ROOT}/lib/wine" "${NEUTRON_DIST}/lib/wine/x86_64-windows"
        overlay_wine_dir "${WINE_ROOT}/lib/wine" "${NEUTRON_DIST}/lib/wine/x86_64-unix"
    fi
fi

# Resources
if [ -d "${WINE_ROOT}/share/wine" ]; then
    mkdir -p "${NEUTRON_DIST}/share/wine"
    run_rsync "rsync --progress --copy-links -a -h \"${WINE_ROOT}/share/wine/\"* \"${NEUTRON_DIST}/share/wine/\""
fi

update_progress 29 "Installing Wine binaries into Neutron dist…" "3/9 • Wine overlay"
# ── 5.1: Install Binaries (Unified 64-bit Loader) ────────────────────────────
info "Installing Wine binaries (unified 64-bit loader)…"
mkdir -p "${NEUTRON_DIST}/bin"
# rm -f "${NEUTRON_DIST}/bin/wine" "${NEUTRON_DIST}/bin/wineserver" "${NEUTRON_DIST}/bin/wine64"

# Install Main Binaries
run "cp -rf \"${WINE_ROOT}/bin/\"* \"${NEUTRON_DIST}/bin/\""

# Link wine -> wine64 (Unified Loader)
#if [ ! -f "${NEUTRON_DIST}/bin/wine" ] && [ -f "${NEUTRON_DIST}/bin/wine64" ]; then
    #ln -sf wine64 "${NEUTRON_DIST}/bin/wine"
#fi

# FIX: GStreamer Cleanup (Prevents "Wrong ELF Class" loop)
# We remove Neutron's GStreamer libs if they conflict with Custom Wine's layout
# This forces Wine to use its internal GStreamer support or disable it gracefully.
rm -rf "${NEUTRON_DIST}/lib/gstreamer-1.0"
rm -rf "${NEUTRON_DIST}/lib64/gstreamer-1.0"

update_progress 31 "Restoring Neutron DXVK bridges and Steam DLLs…" "3/9 • Wine overlay"
# ── 5.2: Restore Bridges (DXVK + Steam DLLs) ─────────────────────────────────

NEUTRON_INTERNAL=""
for d in files dist proton_dist neutron_dist; do
  if [ -d "${NEUTRON_SRC}/$d" ]; then NEUTRON_INTERNAL="${NEUTRON_SRC}/$d"; break; fi
done

if [ -n "$NEUTRON_INTERNAL" ]; then
    # Restore DXVK (BUT do not overwrite winevulkan.dll)
    if [ -d "${NEUTRON_INTERNAL}/lib/wine/dxvk" ]; then
        info "Restoring DXVK..."
        if [ -d "${NEUTRON_INTERNAL}/lib/wine/dxvk/x64" ]; then
             cp -n "${NEUTRON_INTERNAL}/lib/wine/dxvk/x64/"* "${NEUTRON_DIST}/lib/wine/x86_64-windows/" 2>/dev/null || true
        fi
        if [ -d "${NEUTRON_INTERNAL}/lib/wine/dxvk/x32" ]; then
             cp -n "${NEUTRON_INTERNAL}/lib/wine/dxvk/x32/"* "${NEUTRON_DIST}/lib/wine/i386-windows/" 2>/dev/null || true
        fi
    fi

    # Restore Steam DLLs
    find "${NEUTRON_INTERNAL}/lib/wine" -type f \( -name "lsteamclient*" -o -name "steam.exe" -o -name "vrclient*" -o -name "openvr_api*" \) | while read -r src_file; do
        rel_path="${src_file#${NEUTRON_INTERNAL}/lib/wine/}"
        dest_file="${NEUTRON_DIST}/lib/wine/${rel_path}"
        mkdir -p "$(dirname "$dest_file")"
        cp -f "$src_file" "$dest_file"
    done
fi

update_progress 33 "Building bin-wow64 compatibility symlinks…" "3/9 • Wine overlay"
# ── 5.3: bin-wow64 fallback ───────────────────────────────────────────────────
BIN_WOW64="${NEUTRON_DIST}/bin-wow64"
BIN_REAL="${NEUTRON_DIST}/bin"

if [ ! -d "$BIN_REAL" ]; then
  error "Expected bin directory not found: $BIN_REAL"
fi

info "Creating bin-wow64 fallback directory..."
mkdir -p "$BIN_WOW64"

# FIX: use a temp file to count across the subshell boundary
# (find | while runs in a subshell — variables set inside do not persist)
_BIN_COUNT_FILE=$(mktemp)
echo 0 > "$_BIN_COUNT_FILE"
set +e
while IFS= read -r binfile; do
  binname=$(basename "$binfile")
  ln -sf "../bin/$binname" "${BIN_WOW64}/$binname" 2>/dev/null
  echo $(($(cat "$_BIN_COUNT_FILE") + 1)) > "$_BIN_COUNT_FILE"
done < <(find "$BIN_REAL" -maxdepth 1 -type f -perm -111)
set -e
BIN_COUNT=$(cat "$_BIN_COUNT_FILE"); rm -f "$_BIN_COUNT_FILE"

good "bin-wow64 fallback created with $BIN_COUNT symlinks"

update_progress 37 "Copying Wine lib (32-bit) and lib64 (64-bit) shared libraries…" "3/9 • Wine overlay"
# ── 5.4: Copy lib and lib64 libraries ────────────────────────────────────────

# Copy lib directory (32-bit + Wine libraries)
if [ -d "${WINE_ROOT}/lib" ]; then
    info "Copying lib directory..."
    mkdir -p "${NEUTRON_DIST}/lib"

    # Copy .so files from lib root
    find "${WINE_ROOT}/lib" -maxdepth 1 -type f -name "*.so*" 2>/dev/null | while read -r lib; do
        cp -f "$lib" "${NEUTRON_DIST}/lib/" 2>/dev/null || true
    done

    # Copy lib/wine if it exists
    if [ -d "${WINE_ROOT}/lib/wine" ]; then
        mkdir -p "${NEUTRON_DIST}/lib/wine"
        run_rsync "rsync --progress -a -h \"${WINE_ROOT}/lib/wine/\" \"${NEUTRON_DIST}/lib/wine/\""
    fi

    LIB_COUNT=$(find "${NEUTRON_DIST}/lib" -name "*.so*" -type f 2>/dev/null | wc -l)
    info "✓ Copied lib ($LIB_COUNT files)"
fi

# Copy lib64 directory (64-bit system libraries)
if [ -d "${WINE_ROOT}/lib64" ]; then
    info "Copying lib64 directory..."
    mkdir -p "${NEUTRON_DIST}/lib64"

    # Copy .so files from lib64 root
    find "${WINE_ROOT}/lib64" -maxdepth 1 -type f -name "*.so*" 2>/dev/null | while read -r lib; do
        cp -f "$lib" "${NEUTRON_DIST}/lib64/" 2>/dev/null || true
    done

    # Copy lib64/wine if it exists
    if [ -d "${WINE_ROOT}/lib64/wine" ]; then
        mkdir -p "${NEUTRON_DIST}/lib64/wine"
        run_rsync "rsync --progress -a -h \"${WINE_ROOT}/lib64/wine/\" \"${NEUTRON_DIST}/lib64/wine/\""
    fi

    LIB64_COUNT=$(find "${NEUTRON_DIST}/lib64" -name "*.so*" -type f 2>/dev/null | wc -l)
    info "✓ Copied lib64 ($LIB64_COUNT files)"
fi

# Set permissions
chmod 755 "${NEUTRON_DIST}/lib"/*.so* 2>/dev/null || true
chmod 755 "${NEUTRON_DIST}/lib64"/*.so* 2>/dev/null || true

echo

update_progress 40 "Verifying WoW64 unified binary (32+64-bit support)…" "3/9 • Wine overlay"
# ── 5.5: WoW64 Verification ───────────────────────────────────────────────────

# For unified WoW64 builds (like Lutris Wine-GE), there's no separate bin-wow64
# The main wine binary handles both 32-bit and 64-bit Windows applications

info "Detected unified WoW64 build (no separate bin-wow64 needed)"

# Check if wine binary is the WoW64 loader
if [ -f "${NEUTRON_DIST}/bin/wine" ]; then
    WINE_FILE_TYPE=$(file "${NEUTRON_DIST}/bin/wine")

    if [[ "$WINE_FILE_TYPE" == *"ELF 64-bit"* ]]; then
        info "✓ Wine binary is 64-bit WoW64 loader"
        info "  This wine binary handles both 32-bit and 64-bit Windows apps"
    else
        warn "Wine binary is not 64-bit - WoW64 support may be limited"
    fi
else
    error "Wine binary not found!"
fi

# Verify wineserver (single consolidated check)
if [ -f "${NEUTRON_DIST}/bin/wineserver" ]; then
    WINESERVER_VER=$("${NEUTRON_DIST}/bin/wineserver" --version 2>&1 | head -1)
    good "Wineserver: $WINESERVER_VER"
else
    warn "Wineserver not found — prefix initialisation may fail"
fi

# Cleanup bin-wow64 stale wine64 entries
rm -rf "${NEUTRON_DIST}/bin-wow64/wine64"
rm -rf "${NEUTRON_DIST}/bin-wow64/wine64-preloader"

good "WoW64 configuration complete (unified build)"
echo

# Check 64-bit ntdll.so — search fallback sources and actually install it
NTDLL_64_TARGET="${NEUTRON_DIST}/lib/wine/x86_64-unix/ntdll.so"

if [ ! -f "$NTDLL_64_TARGET" ]; then
  warn "64-bit ntdll.so missing — searching fallback sources…"
  for _ntdll_src in \
    "${WINE_ROOT}/lib/wine/x86_64-unix/ntdll.so" \
    "${WINE_ROOT}/lib64/wine/x86_64-unix/ntdll.so" \
    "${WINE_ROOT}/lib64/ntdll.so"; do
    if [ -f "$_ntdll_src" ] && file "$_ntdll_src" | grep -q "ELF 64-bit"; then
      mkdir -p "$(dirname "$NTDLL_64_TARGET")"
      cp "$_ntdll_src" "$NTDLL_64_TARGET"
      good "Installed ntdll.so from: $_ntdll_src"
      break
    fi
  done
  [ ! -f "$NTDLL_64_TARGET" ] && warn "ntdll.so still missing — Wine may not function correctly"
fi
echo

update_progress 47 "Installing Wine preloader binaries (64-bit + 32-bit)…" "3/9 • Wine overlay"
# ── 5.6: Wine Preloaders ──────────────────────────────────────────────────────

# 64-bit preloader
PRELOADER_SOURCES=(
  "${WINE_ROOT}/bin/wine64-preloader"
  "${WINE_ROOT}/lib/wine/x86_64-unix/wine-preloader"
  "${WINE_ROOT}/lib64/wine/x86_64-unix/wine-preloader"
)

for src in "${PRELOADER_SOURCES[@]}"; do
  if [ -f "$src" ]; then
    cp "$src" "${NEUTRON_DIST}/bin/wine64-preloader"
    chmod +x "${NEUTRON_DIST}/bin/wine64-preloader"
    info "✓ Installed 64-bit preloader"
    break
  fi
done

# 32-bit preloader
PRELOADER32_SOURCES=(
  "${WINE_ROOT}/bin/wine-preloader"
  "${WINE_ROOT}/lib/wine/i386-unix/wine-preloader"
)

for src in "${PRELOADER32_SOURCES[@]}"; do
  if [ -f "$src" ]; then
    cp "$src" "${NEUTRON_DIST}/bin/wine-preloader"
    chmod +x "${NEUTRON_DIST}/bin/wine-preloader"
    info "✓ Installed 32-bit preloader"
    break
  fi
done

# Copy all preloader-related files from Wine's unix directories
info "Copying additional Wine preloader components..."

for wine_unix_dir in \
  "${WINE_ROOT}/lib/wine/x86_64-unix" \
  "${WINE_ROOT}/lib64/wine/x86_64-unix" \
  "${WINE_ROOT}/lib/wine/i386-unix"; do

  if [ -d "$wine_unix_dir" ]; then
    find "$wine_unix_dir" -name "*preload*" -o -name "wine64" -o -name "wine" | while read -r preload_file; do
      if [ -f "$preload_file" ]; then
        basename_file=$(basename "$preload_file")

        # Determine target directory based on source architecture
        if [[ "$wine_unix_dir" == *"x86_64"* ]]; then
          target_dir="${NEUTRON_DIST}/lib/wine/x86_64-unix"
        else
          target_dir="${NEUTRON_DIST}/lib/wine/i386-unix"
        fi

        mkdir -p "$target_dir"
        cp "$preload_file" "$target_dir/$basename_file"
        chmod +x "$target_dir/$basename_file" 2>/dev/null || true
        info "  Copied: $basename_file to $target_dir"
      fi
    done
  fi
done

info "✓ Preloader installation complete"

update_progress 55 "Checking Wine fonts directory — restoring fallback if empty…" "3/9 • Wine overlay"
# ── 5.7: Fonts Fallback ───────────────────────────────────────────────────────

mkdir -p "${NEUTRON_DIST}/share/wine/fonts"

if [ ! "$(ls -A "${NEUTRON_DIST}/share/wine/fonts" 2>/dev/null)" ]; then
  warn "Fonts directory is empty – searching for fallback sources..."

  FONT_SOURCES=(
    "${WINE_ROOT}/share/fonts"
    "${WINE_ROOT}/share/wine/fonts"
    "${NEUTRON_SRC}/files/share/wine/fonts"
    "${NEUTRON_SRC}/dist/share/wine/fonts"
    "/usr/share/wine/fonts"
  )

  for src in "${FONT_SOURCES[@]}"; do
    if [ -d "$src" ] && [ "$(ls -A "$src" 2>/dev/null)" ]; then
      info "Found fonts in: $src"
      run_rsync "rsync --progress -a -h \"$src/\" \"${NEUTRON_DIST}/share/wine/fonts/\""
      good "Fonts restored"
      break
    fi
  done
fi

update_progress 60 "Materialising default_pfx symlinks into real files…" "3/9 • Wine overlay"
# ── 5.8: Fix default_pfx Symlinks ────────────────────────────────────────────
DEFAULT_PFX="${NEUTRON_DIST}/share/default_pfx"

if [ -d "$DEFAULT_PFX" ]; then
  info "Converting symlinks in default_pfx to real files..."

  find "$DEFAULT_PFX" -type l | while read -r symlink; do
    target=$(readlink -f "$symlink")
    if [ -f "$target" ]; then
      rm "$symlink"
      cp "$target" "$symlink"
    fi
  done

  good "default_pfx symlinks repaired"
else
  info "No default_pfx found – skipping"
fi

# ============================================================================
# Step 4: Python Support & protonfixes
# ============================================================================

step 4 9 "Python Support & protonfixes"
update_progress 65 "Copying Neutron Python launcher and helper modules…" "4/9 • Python / protonfixes"

info "Copying Neutron Python infrastructure..."
# Use cp (not cp -v) — verbose output goes to stdout which corrupts the GUI pipe
find "${NEUTRON_SRC}" -maxdepth 1 -name "*.py" -type f -exec cp {} "${STAGING_DIR}/" \; 2>/dev/null || true

CRITICAL_PY_FILES=("neutron" "user_settings.sample.py" "filelock.py")
for pyfile in "${CRITICAL_PY_FILES[@]}"; do
  if [ -f "${NEUTRON_SRC}/$pyfile" ]; then
    cp "${NEUTRON_SRC}/$pyfile" "${STAGING_DIR}/"
    good "Copied $pyfile"
  else
    warn "Missing: $pyfile (may cause issues)"
  fi
done

if [ -d "${NEUTRON_SRC}/protonfixes" ]; then
  cp -r "${NEUTRON_SRC}/protonfixes" "${STAGING_DIR}/"
  good "Copied protonfixes"
fi

# ============================================================================
# Step 5: umu-protonfixes Integration  (optional)
# (directory was already located / confirmed during pre-flight above)
# ============================================================================

step 5 9 "protonfixes Integration  (optional)"
update_progress 72 "Processing protonfixes…" "5/9 • protonfixes"

if [ "$PROTONFIXES_FOUND" -eq 1 ]; then
  update_progress 74 "Installing protonfixes from: ${PROTONFIXES_SRC}…" "5/9 • protonfixes"
  info "protonfixes source: $PROTONFIXES_SRC"

  mkdir -p "${NEUTRON_DIST}/bin"

  # ── Detect layout and find the actual protonfixes module ─────────────────────
  # Supported layouts:
  #   A) PROTONFIXES_SRC is itself the module  (has gamefixes/ or __init__.py)
  #   B) PROTONFIXES_SRC/protonfixes/          (checkout root with subdir)
  #   C) umu-protonfixes repo with build/      (built artefacts + optional module)

  _pf_module=""
  if [ -d "${PROTONFIXES_SRC}/gamefixes" ] || [ -f "${PROTONFIXES_SRC}/__init__.py" ]; then
    _pf_module="$PROTONFIXES_SRC"                        # Layout A — dir is the module
  elif [ -d "${PROTONFIXES_SRC}/protonfixes" ]; then
    _pf_module="${PROTONFIXES_SRC}/protonfixes"           # Layout B — subdir
  elif [ -d "${PROTONFIXES_SRC}/umu-protonfixes" ]; then
    _pf_module="${PROTONFIXES_SRC}/umu-protonfixes"
  elif [ -d "${PROTONFIXES_SRC}/src/protonfixes" ]; then
    _pf_module="${PROTONFIXES_SRC}/src/protonfixes"
  fi

  # Install the protonfixes Python module
  if [ -n "$_pf_module" ]; then
    rm -rf "${STAGING_DIR}/protonfixes"
    cp -r "$_pf_module" "${STAGING_DIR}/protonfixes"
    good "Installed protonfixes module from: ${_pf_module}"
  else
    warn "Could not locate protonfixes module inside $PROTONFIXES_SRC — skipping module copy"
  fi

  # ── umu-protonfixes built artefacts (unzip, cabextract, libmspack) ───────────
  # These are only present when the source is a compiled umu-protonfixes repo.
  # Silently skip each one if not found — they're not required for basic operation.
  if [ -d "${PROTONFIXES_SRC}/build" ]; then
    info "umu-protonfixes build dir detected — installing bundled tools…"

    for _upath in \
      "${PROTONFIXES_SRC}/build/unzip/unzip" \
      "${PROTONFIXES_SRC}/unzip/unzip" \
      "${PROTONFIXES_SRC}/build/bin/unzip"; do
      if [ -x "$_upath" ]; then
        install -Dm755 "$_upath" "${NEUTRON_DIST}/bin/unzip"
        good "Installed bundled unzip"
        break
      fi
    done

    for _cpath in \
      "${PROTONFIXES_SRC}/build/libmspack/cabextract/cabextract" \
      "${PROTONFIXES_SRC}/libmspack/cabextract/cabextract"; do
      if [ -x "$_cpath" ]; then
        install -Dm755 "$_cpath" "${NEUTRON_DIST}/bin/cabextract"
        good "Installed bundled cabextract"
        break
      fi
    done

    for _lpath in \
      "${PROTONFIXES_SRC}/build/libmspack/libmspack/.libs/libmspack.so.0" \
      "${PROTONFIXES_SRC}/libmspack/libmspack/.libs/libmspack.so.0"; do
      if [ -f "$_lpath" ]; then
        install -Dm755 "$_lpath" "${NEUTRON_DIST}/lib/libmspack.so.0"
        ln -sf libmspack.so.0 "${NEUTRON_DIST}/lib/libmspack.so"
        install -Dm755 "$_lpath" "${NEUTRON_DIST}/lib64/libmspack.so.0"
        ln -sf libmspack.so.0 "${NEUTRON_DIST}/lib64/libmspack.so"
        good "Installed bundled libmspack"
        break
      fi
    done
  fi

else
  info "Skipping protonfixes — none found or provided"
fi

# ============================================================================
# Step 8: Generate Steam Manifests & Version File
# ============================================================================

step 6 9 "Generate Steam Manifests & Version File"
update_progress 80 "Writing compatibilitytool.vdf, toolmanifest.vdf, version…" "6/9 • Steam manifests"

# Preserve original Proton version format
if [ -f "${NEUTRON_SRC}/version" ]; then
  cp "${NEUTRON_SRC}/version" "${STAGING_DIR}/version"
  good "Preserved original Proton version file"
else
  TIMESTAMP=$(date +%s)
  echo "$TIMESTAMP $TOOL_NAME" > "${STAGING_DIR}/version"
  info "Generated version string: $TIMESTAMP $TOOL_NAME"
fi

cat > "${STAGING_DIR}/compatibilitytool.vdf" <<VDF
"compatibilitytools"
{
  "compat_tools"
  {
    "$TOOL_NAME"
    {
      "install_path" "."
      "display_name" "$TOOL_NAME"
      "from_oslist" "windows"
      "to_oslist" "linux"
    }
  }
}
VDF

cat > "${STAGING_DIR}/toolmanifest.vdf" <<VDF
"manifest"
{
  "manifest_version" "2"
  "commandline" "/neutron waitforexitandrun"
  "use_sessions" "1"
}
VDF

touch "${NEUTRON_DIST}/dist_lock"
good "Steam manifests written"

# ============================================================================
# Step 7: Deploy
# (Install destination was already resolved during pre-flight — no pickers here)
# ============================================================================

step 7 9 "Deploy"
if [ "$INSTALL_IS_STEAM" -eq 1 ]; then
  update_progress 84 "Deploying hybrid tool into Steam compatibilitytools.d…" "7/9 • Deploy"
else
  update_progress 84 "Deploying hybrid tool to custom directory…" "7/9 • Deploy"
fi

if [ -d "$FINAL_PATH" ]; then
  info "Removing previous installation: $FINAL_PATH"
  run "rm -rf \"$FINAL_PATH\""
fi

run "cp -a \"$STAGING_DIR\" \"$FINAL_PATH\""

# Fix ownership if running as root / sudo
if [ -n "${SUDO_USER:-}" ]; then
  info "Fixing ownership for: $SUDO_USER"
  run "chown -R $SUDO_USER:$(id -gn "$SUDO_USER") \"$FINAL_PATH\""
fi

good "Deployed: $FINAL_PATH"

# ── Write install receipt (enables --uninstall and build auditing) ────────────
RECEIPT_FILE="${FINAL_PATH}/.mythix-install"
cat > "$RECEIPT_FILE" <<RECEIPT
# Mythix Hybrid Installer — install receipt
# Generated by wine-neutron_mythix-unified.sh v${VERSION}
installer_version="${VERSION}"
install_date="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
tool_name="${TOOL_NAME}"
install_path="${FINAL_PATH}"
install_mode="${INSTALL_MODE}"
wine_src="${WINE_SRC}"
proton_src="${NEUTRON_SRC}"
proton_version="${NEUTRON_VERSION}"
protonfixes_src="${PROTONFIXES_SRC:-none}"
wine_unified_wow64="${WINE_IS_UNIFIED_WOW64}"
RECEIPT
good "Install receipt written: $RECEIPT_FILE"

# ============================================================================
# Step 8: Write Proton Launch Wrapper
# ============================================================================

step 8 9 "Write Launch Wrapper"
update_progress 91 "Writing Proton launch wrapper (host-library-priority mode)…" "8/9 • Wrapper"

# Detect actual dist subdirectory name
DIST_SUBDIR="files"
if [ -d "${FINAL_PATH}/dist" ]; then DIST_SUBDIR="dist"; fi

# Copy and rename the Proton Python launcher
if [ -f "${STAGING_DIR}/neutron" ]; then
  cp "${STAGING_DIR}/neutron" "${FINAL_PATH}/neutron.py"
  chmod +x "${FINAL_PATH}/neutron.py"
fi

# Write the wrapper script
cat <<'EOF' > "${FINAL_PATH}/neutron"
#!/usr/bin/env bash
# =============================================================================
# Hybrid Wine/Proton Launcher  —  mythix edition
# Modes:
#   ./neutron run  <exe> [args…]   – Standalone / direct Wine launch
#   ./neutron <steam-verb> [args…] – Neutron/Steam integration (Mode B)
# =============================================================================
#
# NOTE: We deliberately do NOT use "set -euo pipefail" here.
# Wine subprocesses, DRM launchers, self-restarting executables, and crash
# reporters routinely exit with non-zero codes that are perfectly normal.
# A strict exit-on-error shell would kill the wrapper on those events and make
# it look like the game "won't launch" when it actually just needs a moment.

# =============================================================================
# 1. Resolve the real location of this script (symlink-safe)
# =============================================================================
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
tool_root="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"

# =============================================================================
# 2. Locate the internal dist directory  (files/  or  dist/)
# =============================================================================
if   [ -d "${tool_root}/dist"  ]; then dist_dir="${tool_root}/dist"
elif [ -d "${tool_root}/files" ]; then dist_dir="${tool_root}/files"
else
  echo "ERROR: Cannot find dist/ or files/ inside ${tool_root}" >&2
  exit 1
fi

# =============================================================================
# 3. Choose the Wine binary
#    Prefer wine64 (unified WoW64 loader) but fall back to wine.
# =============================================================================
if [ -x "${dist_dir}/bin/wine64" ]; then
  WINE_BIN="${dist_dir}/bin/wine64"
  WINE_BIN32="${dist_dir}/bin/wine"     # may or may not exist in WoW64 builds
else
  WINE_BIN="${dist_dir}/bin/wine"
  WINE_BIN32="${dist_dir}/bin/wine"
fi
WINESERVER_BIN="${dist_dir}/bin/wineserver"

export WINELOADER="${WINE_BIN}"
export WINESERVER="${WINESERVER_BIN}"
export WINEDLLPATH="${dist_dir}/lib/wine/x86_64-windows:${dist_dir}/lib/wine/i386-windows"

# Add both bin/ and bin-wow64/ to PATH so child processes can find wine, wineserver etc.
if [ -d "${dist_dir}/bin-wow64" ]; then
  export PATH="${dist_dir}/bin:${dist_dir}/bin-wow64:${PATH}"
else
  export PATH="${dist_dir}/bin:${PATH}"
fi

# Register preloaders if present
[ -f "${dist_dir}/bin/wine64-preloader" ] && export WINE_PRELOADER="${dist_dir}/bin/wine64-preloader"
[ -f "${dist_dir}/bin/wine-preloader"   ] && export WINE_PRELOADER32="${dist_dir}/bin/wine-preloader"

# =============================================================================
# MODE A: STANDALONE / DIRECT WINE LAUNCH
# Usage:  ./neutron run /path/to/game.exe [args…]
#
# Tuneable env vars (set these BEFORE calling ./neutron run):
#
#   WINEPREFIX    – exact prefix path to use.
#                   If NOT set, the shared default prefix is used:
#                   ~/.wine-neutron-pfx
#                   To isolate a game, use MYTHIX_PREFIX instead.
#
#   WINEARCH      – win64 (default) or win32
#   PROTON_LOG    – set to "1" to write a full Wine debug log to /tmp/
#   DXVK_HUD      – "1" for the DXVK performance overlay
#   WINE_USE_START – set to "1" to launch via "wine start /wait" instead of
#                   directly execing wine.  Helps with games that have a
#                   launcher exe that re-spawns itself (e.g. GTA IV).
# =============================================================================
if [ "$#" -ge 1 ] && [ "$1" = "run" ]; then
  shift   # drop "run"; "$@" is now just the exe + its args

  # ── Determine the exe name for logging and prefix derivation ──────────────
  _exe_path="${1:-}"
  if [ -n "$_exe_path" ]; then
    _exe_basename="$(basename "${_exe_path%.*}" | tr ' ' '_' | tr -cd '[:alnum:]_-')"
  else
    _exe_basename="default"
  fi

  # ── PREFIX RESOLUTION ─────────────────────────────────────────────────────
  # Rules (checked in order):
  #   1. If MYTHIX_PREFIX is set → use it exactly  (explicit per-run override)
  #   2. If WINEPREFIX is set in the environment AND it doesn't look like it
  #      came from a global default (~/.wine) → honour it with a warning
  #   3. Otherwise → use the single shared prefix ~/.wine-proton/default
  #
  # A single shared prefix avoids creating a new prefix directory for every
  # executable launched, which wastes disk space. To isolate a specific game,
  # set MYTHIX_PREFIX=/path/to/prefix before running.
  if [ -n "${MYTHIX_PREFIX:-}" ]; then
    _computed_prefix="$MYTHIX_PREFIX"
    _prefix_source="MYTHIX_PREFIX override"
  elif [ -n "${LOONI_PREFIX:-}" ]; then
    # Backward-compatible fallback for setups predating the mythix rebrand.
    _computed_prefix="$LOONI_PREFIX"
    _prefix_source="LOONI_PREFIX override (legacy)"
  elif [ -n "${WINEPREFIX:-}" ] && [ "$WINEPREFIX" != "$HOME/.wine" ]; then
    _computed_prefix="$WINEPREFIX"
    _prefix_source="WINEPREFIX env (inherited — consider using MYTHIX_PREFIX instead)"
  else
    _computed_prefix="${HOME}/.wine-neutron-pfx"
    _prefix_source="auto (shared default)"
  fi
  export WINEPREFIX="$_computed_prefix"
  export WINEARCH="${WINEARCH:-win64}"
  mkdir -p "$WINEPREFIX"

  # ── WINELOADERNOEXEC must be OFF in standalone mode ───────────────────────
  # This Proton/Steam flag disables the preloader exec-trick Wine uses to set
  # up the 32/64-bit process address space.  It must be unset for standalone
  # launch; leaving it on silently breaks the majority of real games.
  unset WINELOADERNOEXEC

  # ── Host-library priority ─────────────────────────────────────────────────
  # Host X11/GL/Vulkan drivers come first so the system GPU stack is used
  # instead of Proton's bundled copies.  Fixes "Failed to get adapters" and
  # xrandr errors on most desktop setups.
  _HOST_32="/usr/lib/i386-linux-gnu:/usr/lib32:/lib/i386-linux-gnu:/usr/lib/i386-linux-gnu/mesa"
  _HOST_64="/usr/lib/x86_64-linux-gnu:/usr/lib64:/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu/mesa"
  export LD_LIBRARY_PATH="\
${_HOST_64}:\
${_HOST_32}:\
${dist_dir}/lib64:\
${dist_dir}/lib:\
${dist_dir}/lib/wine/x86_64-unix:\
${dist_dir}/lib/wine/i386-unix:\
${LD_LIBRARY_PATH:-}"

  # ── GStreamer ─────────────────────────────────────────────────────────────
  # Don't blanket-disable GStreamer — that breaks cutscenes and audio.
  # Only steer away from Proton's own plugins if they're present; fall back
  # to host plugins for everything else.
  unset GST_PLUGIN_SYSTEM_PATH_1_0
  if [ -d "${dist_dir}/lib/gstreamer-1.0" ]; then
    export GST_PLUGIN_PATH_1_0="${dist_dir}/lib/gstreamer-1.0${GST_PLUGIN_PATH_1_0:+:${GST_PLUGIN_PATH_1_0}}"
  fi

  # ── DLL overrides ─────────────────────────────────────────────────────────
  # d3d12 is intentionally absent — most games needing DX12 require
  # Proton's vkd3d-proton; forcing native breaks them.
  # To opt in:  export WINEDLLOVERRIDES="d3d12=n,b"  before running.
  #
  # Any overrides already in the env (from MYTHIX_PREFIX workflows etc.)
  # are preserved and appended after ours.
  _base_overrides="d3d11=n,b;d3d10core=n,b;d3d9=n,b;dxgi=n,b;steamclient=n,b"
  if [ -n "${WINEDLLOVERRIDES:-}" ]; then
    export WINEDLLOVERRIDES="${_base_overrides};${WINEDLLOVERRIDES}"
  else
    export WINEDLLOVERRIDES="$_base_overrides"
  fi
  unset _base_overrides

  # ── Vulkan ICD auto-detection ─────────────────────────────────────────────
  # Only run if not already set.  Guard the glob — don't export an empty
  # string (that would override a correct system value with nothing).
  if [ -z "${VK_ICD_FILENAMES:-}" ]; then
    _vk_icd=""
    for _icd in /usr/share/vulkan/icd.d/*.json /etc/vulkan/icd.d/*.json; do
      [ -f "$_icd" ] || continue
      _vk_icd="${_vk_icd:+${_vk_icd}:}${_icd}"
    done
    [ -n "$_vk_icd" ] && export VK_ICD_FILENAMES="$_vk_icd"
    unset _vk_icd _icd
  fi

  # ── Steam compat stubs ────────────────────────────────────────────────────
  export SteamGameId="${SteamGameId:-0}"
  export SteamAppId="${SteamAppId:-0}"
  export STEAM_COMPAT_DATA_PATH="${WINEPREFIX}"

  # ── Misc Wine improvements ────────────────────────────────────────────────
  export WINE_LARGE_ADDRESS_AWARE=1
  export WINEDEBUG="${WINEDEBUG:--all}"
  export DISPLAY="${DISPLAY:-:0}"

  # ── PROTON_LOG helper ─────────────────────────────────────────────────────
  # PROTON_LOG=1 → full Wine debug log at /tmp/neutron_<ExeName>.log
  if [ "${PROTON_LOG:-0}" = "1" ]; then
    _logfile="/tmp/neutron_${_exe_basename}.log"
    export WINEDEBUG="+all"
    export WINEDEBUGFILE="$_logfile"
    echo ":: [Hybrid-Proton] Logging to: ${_logfile}" >&2
  fi

  # ── Print launch info ─────────────────────────────────────────────────────
  echo ":: [Hybrid-Proton] Standalone Mode" >&2
  echo "   Prefix  : ${WINEPREFIX}  (${_prefix_source})" >&2
  echo "   Arch    : ${WINEARCH}" >&2
  echo "   Binary  : ${WINE_BIN}" >&2
  echo "   Exe     : ${_exe_path:-<none>}" >&2
  echo "   Libs    : HOST → Proton" >&2

  # ── Initialise the Wine prefix on first run ───────────────────────────────
  # system.reg missing = prefix has never been booted.
  # wineboot --init lays down the registry skeleton, DLL stubs, and fonts
  # that most games expect to already exist when they first run.
  if [ ! -f "${WINEPREFIX}/system.reg" ]; then
    echo ":: [Hybrid-Proton] First run — initialising prefix…" >&2
    WINEPREFIX="${WINEPREFIX}" WINEARCH="${WINEARCH}" \
      "${WINE_BIN}" wineboot --init 2>/dev/null || true
    # Wait for wineserver to finish processing the boot sequence
    WINEPREFIX="${WINEPREFIX}" "${WINESERVER_BIN}" -w 2>/dev/null || true
    echo ":: [Hybrid-Proton] Prefix ready." >&2
  fi

  # ── Kill only THIS prefix's wineserver before launch ─────────────────────
  # Scoped to WINEPREFIX so we don't disturb other running Wine sessions.
  WINEPREFIX="${WINEPREFIX}" "${WINESERVER_BIN}" -k 2>/dev/null || true
  sleep 0.3

  # ── Launch ────────────────────────────────────────────────────────────────
  # WINE_USE_START=1 → use "wine start /wait" instead of exec'ing wine directly.
  #
  # When to use this:
  #   Games whose top-level .exe is actually a *launcher* that spawns the real
  #   game process as a child (GTA IV's GTAIV.exe → LaunchGTAIV.exe is the
  #   classic example).  Without /wait, Wine returns as soon as the launcher
  #   exits, orphaning all child processes.  With "start /wait", Wine stays
  #   alive until the last child finishes.
  #
  # The DXVK init block repeating 6+ times in your GTA IV log was caused by
  # exactly this — multiple orphaned child Wine processes each reinitialising
  # DXVK independently because no parent was holding the wineserver alive.
  #
  # Set WINE_USE_START=1 in your shell before launching GTA IV (or any other
  # launcher-wrapped game).  It's off by default because most games don't need
  # it and "start /wait" adds a tiny layer of indirection.
  if [ "${WINE_USE_START:-0}" = "1" ]; then
    echo "   Mode    : wine start /wait  (launcher wrapper mode)" >&2
    exec "${WINE_BIN}" start /wait /unix "$@"
  else
    exec "${WINE_BIN}" "$@"
  fi
fi

# =============================================================================
# MODE B: PROTON / STEAM INTEGRATION
# Called by Steam as:  ./neutron waitforexitandrun %command%
# =============================================================================

# In Steam mode WINELOADERNOEXEC is expected and correct — leave it alone.
export WINELOADERNOEXEC=1

if command -v python3 >/dev/null 2>&1; then PYTHON="python3"; else PYTHON="python"; fi

export PYTHONPATH="${tool_root}:${tool_root}/protonfixes:${PYTHONPATH:-}"
export STEAM_RUNTIME=1
export PRESSURE_VESSEL=1
export PROTON_DISABLE_VR=1
export PROTON_NO_VR=1
export PROTON_CRASH_REPORT_DISABLE=1
export WINEDLLOVERRIDES="beclient=n,b;beclient_x64=n,b;${WINEDLLOVERRIDES:-}"

# In Steam mode Proton libraries come first; the Steam Runtime supplies the rest.
export LD_LIBRARY_PATH="${dist_dir}/lib64:${dist_dir}/lib:${LD_LIBRARY_PATH:-}"

export STEAM_COMPAT_CLIENT_INSTALL_PATH="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-${HOME}/.steam/steam}"
export STEAM_COMPAT_DATA_PATH="${STEAM_COMPAT_DATA_PATH:-${HOME}/.steam/steam/steamapps/compatdata/271590}"

exec "$PYTHON" "${tool_root}/neutron.py" "$@"
EOF

chmod +x "${FINAL_PATH}/neutron"
good "Proton launch wrapper written"

# ============================================================================
# Step 9: Verify Installation
# ============================================================================

step 9 9 "Verify Installation"
update_progress 95 "Checking critical files: proton launcher, VDF manifests, Wine binary…" "9/9 • Verify"

VERIFY_FAILED=0

[ ! -x "${FINAL_PATH}/neutron" ]                  && { warn "neutron launcher is not executable!"; VERIFY_FAILED=1; }
[ ! -f "${FINAL_PATH}/compatibilitytool.vdf" ]   && { warn "compatibilitytool.vdf is missing!"; VERIFY_FAILED=1; }
[ ! -f "${FINAL_PATH}/toolmanifest.vdf" ]         && { warn "toolmanifest.vdf is missing!";      VERIFY_FAILED=1; }
[ ! -f "${FINAL_PATH}/version" ]                  && { warn "version file is missing!";           VERIFY_FAILED=1; }
[ ! -f "${FINAL_PATH}/.mythix-install" ]           && { warn "install receipt is missing!";        VERIFY_FAILED=1; }

# Check Wine binary inside the dist subdir
DIST_CHECK=""
[ -d "${FINAL_PATH}/files" ] && DIST_CHECK="${FINAL_PATH}/files"
[ -d "${FINAL_PATH}/dist"  ] && DIST_CHECK="${FINAL_PATH}/dist"

if [ -n "$DIST_CHECK" ]; then
  [ ! -f "${DIST_CHECK}/bin/wine"   ] && { warn "Wine binary missing at ${DIST_CHECK}/bin/wine"; VERIFY_FAILED=1; }
  [ ! -d "${DIST_CHECK}/lib/wine"   ] && { warn "lib/wine directory missing";                    VERIFY_FAILED=1; }
fi

# Fix permissions: executable bits for scripts/binaries, read for everything else
# (no world-writable; no -v flag that would flood stdout/pipe)
chmod -R u+rwX,go+rX "${FINAL_PATH}" 2>/dev/null || true
find "${FINAL_PATH}" -type f \( -name "*.so*" -o -name "*.so" \) -exec chmod +x {} + 2>/dev/null || true
find "${FINAL_PATH}/files/bin" "${FINAL_PATH}/dist/bin" -type f -exec chmod +x {} + 2>/dev/null || true

update_progress 99 "Finalising…" "9/9 • Verify"

if [ "$VERIFY_FAILED" -eq 1 ]; then
  warn "Verification found issues — tool may not work correctly"
else
  good "All critical files verified ✓"
fi

# ── Debug dump (--debug flag) ─────────────────────────────────────────────────
if [ "$DEBUG" -eq 1 ]; then
  msg "Debug: Proton lib/wine layout"
  find "${NEUTRON_DIST}/lib/wine" -type f | sort
  echo
fi

# ============================================================================
# Finalize
# ============================================================================

printf "\n${C_GREEN}${C_BOLD}"
cat <<'DONE'
  ╔══════════════════════════════════════════════════════════════╗
  ║              ✅  Hybrid Installer  —  Complete!              ║
  ╚══════════════════════════════════════════════════════════════╝
DONE
printf "${C_RESET}\n"

printf "  ${C_BOLD}%-20s${C_RESET} %s\n"  "Tool name:"      "$TOOL_NAME"
printf "  ${C_BOLD}%-20s${C_RESET} %s\n"  "Installed to:"   "$FINAL_PATH"
printf "  ${C_BOLD}%-20s${C_RESET} %s\n"  "Proton version:" "$NEUTRON_VERSION"
printf "  ${C_BOLD}%-20s${C_RESET} %s\n"  "Install mode:"   "$INSTALL_MODE"
if [ "$WINE_IS_UNIFIED_WOW64" -eq 1 ]; then
  printf "  ${C_BOLD}%-20s${C_RESET} ${C_YELLOW}%s${C_RESET}\n"  "Wine WoW64:"  "unified (⚠ 32-bit launcher games may crash)"
else
  printf "  ${C_BOLD}%-20s${C_RESET} ${C_GREEN}%s${C_RESET}\n"   "Wine WoW64:"  "split (wine + wine64)  ✓"
fi
printf "  ${C_BOLD}%-20s${C_RESET} %s\n"  "Receipt:"        "${FINAL_PATH}/.mythix-install"
echo

if [ "$INSTALL_IS_STEAM" -eq 1 ]; then
  printf "${C_YELLOW}${C_BOLD}  Next steps  (Steam)${C_RESET}\n\n"
  printf "  ${C_BOLD}1.${C_RESET} Fully quit Steam:\n"
  printf "       ${C_DIM}killall -9 steam steamwebhelper && sleep 5${C_RESET}\n\n"
  printf "  ${C_BOLD}2.${C_RESET} Restart Steam and wait for it to fully load\n\n"
  printf "  ${C_BOLD}3.${C_RESET} Enable the tool for a game:\n"
  printf "       Properties → Compatibility → Force use of: ${C_CYAN}%s${C_RESET}\n\n" "$TOOL_NAME"
  printf "  ${C_BOLD}4.${C_RESET} Launch the game\n\n"
  printf "  ${C_DIM}To uninstall:  $0 --uninstall --name %s${C_RESET}\n" "$TOOL_NAME"
else
  printf "${C_YELLOW}${C_BOLD}  Next steps  (Standalone / Custom)${C_RESET}\n\n"
  printf "  ${C_BOLD}1.${C_RESET} Launch a game directly:\n"
  printf "       ${C_DIM}%s/neutron run /path/to/game.exe${C_RESET}\n\n" "$FINAL_PATH"
  printf "  ${C_BOLD}2.${C_RESET} Launcher-wrapped game (e.g. GTA IV):\n"
  printf "       ${C_DIM}WINE_USE_START=1 %s/neutron run /path/to/launcher.exe${C_RESET}\n\n" "$FINAL_PATH"
  printf "  ${C_BOLD}3.${C_RESET} Use with Lutris / Heroic / Bottles:\n"
  printf "       Set the Wine path to: ${C_CYAN}%s${C_RESET}\n\n" "$FINAL_PATH"
  printf "  ${C_BOLD}4.${C_RESET} Register with Steam later:\n"
  printf "       ${C_DIM}$0 --wine-src \"%s\" --proton-src \"%s\" --name \"%s\" --install-mode steam${C_RESET}\n\n" \
    "$WINE_SRC" "$NEUTRON_SRC" "$TOOL_NAME"
  printf "  ${C_DIM}To uninstall:  $0 --uninstall --name %s --install-dir \"%s\"${C_RESET}\n" \
    "$TOOL_NAME" "$INSTALL_DIR"
fi
echo

update_progress 100 "Complete!"
finish_progress

printf "  \e[2mPress Enter to return to the menu…\e[0m"
read -r _pause 2>/dev/null || true
