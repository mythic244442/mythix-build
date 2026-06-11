#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# install-from-build.sh
# Detect completed build created by wine-builder and optionally run staged make install
# Interactive prompt available: Install / Rebuild wrapper / Skip / Show logs
#
# Usage:
#   ./install-from-build.sh
# Environment:
#   WRAPPER           path to wrapper script (caller should export this)
#   BUILD_RUN_DIR     wrapper workdir
#   TARGET_PREFIX     install prefix (optional override)
#   STAGE_DIR         staging path (optional override)
#   AUTO_CHOICE       set to install|rebuild|skip to bypass interactive prompt
#   DRY_RUN           set to 1 to only print actions

# Defaults — callers (wine-builder.sh / wine-build-core.sh) export these env vars
# to override. The paths below are fallbacks consistent with the mythix-build layout.
_DATA_DIR="${HOME}/.local/share/mythix-wine_builder"
WRAPPER="${WRAPPER:-${_DATA_DIR}/wine-build-script.sh}"
BUILD_RUN_DIR="${BUILD_RUN_DIR:-${_DATA_DIR}/buildz/build-run}"
DEST_ROOT="${DEST_ROOT:-${_DATA_DIR}/src}"
TARGET_PREFIX="${TARGET_PREFIX:-${PREFIX:-${_DATA_DIR}/buildz/install/wine-mythix-x86_x64}}"
STAGE_DIR="${STAGE_DIR:-${TARGET_PREFIX}-stage}"
DRY_RUN="${DRY_RUN:-0}"
# CRITICAL FIX: Disable aggressive auto-rebuild loop by setting AUTO_CHOICE to 'skip'
# This prevents the script from restarting the wrapper endlessly when the stage dir is missing.
AUTO_CHOICE="${AUTO_CHOICE:-skip}"
# Previous AUTO_CHOICE had logic that defaulted to 'rebuild' on error, leading to the loop.
# By forcing a default of 'skip', we exit on error condition.

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
read_env_snapshot() {
  local snap="$BUILD_RUN_DIR/env.snapshot"
  if [ -f "$snap" ]; then
    # Load snapshot variables back into the environment
    # Note: Only safe, simple assignments are loaded back
    # shellcheck disable=SC1090
    . "$snap"
    echo "Snapshot loaded from: $snap"
  fi
}

msg() { printf "==> %s\\n" "$*"; }
err() { printf "!! ERROR: %s\\n" "$*" >&2; exit 1; }
warning() { printf "WARN: %s\\n" "$*" >&2; }

# Helper to check if a directory is empty (excluding . and ..)
is_empty_dir() {
  [ -z "$(ls -A "$1" 2>/dev/null)" ]
}


# ----------------------------------------------------------------------------
# Core Logic
# ----------------------------------------------------------------------------
msg "==== Wine Installation Helper ===="
msg "Wrapper output directory: $BUILD_RUN_DIR"
msg "Final Install Target: $TARGET_PREFIX"
msg "Stage Directory: $STAGE_DIR"
echo

# 1. Check for stage directory presence (build success indicator)
if [ ! -d "$STAGE_DIR" ] || is_empty_dir "$STAGE_DIR"; then
  # The build wrapper failed to create or populate the stage directory.
  # This implies the main 'make' or 'make install' step inside build-wine-tkg.sh failed.
  echo "Error: Stage directory not found or empty at $STAGE_DIR. Cannot install."
  echo "Did the wrapper script complete successfully?"

  # --- CRITICAL CHANGE: Handling the rebuild loop ---
  if [ "$AUTO_CHOICE" = "rebuild" ]; then
    warning "Automatic rebuild requested."
    msg "Cleaning build-run directory..."
    rm -rf "$BUILD_RUN_DIR"
    msg "Restarting wrapper script: $WRAPPER"
    # Execute the wrapper script again (it will source the config file)
    exec "$WRAPPER" # Use exec to replace the current process, preventing deep stack
  elif [ "$AUTO_CHOICE" = "skip" ]; then
    # New logic: Exit gracefully so user can inspect logs manually.
    err "Build artifact missing. Exiting to allow manual diagnosis. Check $BUILD_RUN_DIR/debug.log"
  else
    # Interactive mode fallback (not used in mythix_setup_and_build.sh)
    echo "What would you like to do?"
    select choice in "Install" "Automatic rebuild" "Skip install" "Show logs"; do
      case "$choice" in
        "Install")
          # Fall through to install (but it will fail)
          break
          ;;
        "Automatic rebuild")
          msg "Cleaning build-run directory..."
          rm -rf "$BUILD_RUN_DIR"
          msg "Restarting wrapper script: $WRAPPER"
          exec "$WRAPPER"
          ;;
        "Skip install")
          msg "Skipping installation."
          exit 0
          ;;
        "Show logs")
          echo "Last 50 lines of debug.log:"
          tail -n 50 "$BUILD_RUN_DIR/debug.log" || echo "(Log not found)"
          continue
          ;;
        *)
          warning "Invalid choice, trying again."
          ;;
      esac
    done
  fi
  # If we reached here without exec, something is wrong, force exit if we're not installing
  if [ "$AUTO_CHOICE" != "install" ]; then
    err "Build failed to produce artifacts and manual action was not taken."
  fi
fi

# 2. Proceed with installation (only if stage directory exists)
msg "Stage directory found. Proceeding with installation to $TARGET_PREFIX"

# Read snapshot to get build configuration details like SKIP_32BIT
read_env_snapshot

# Clean up target directory if it exists
if [ -d "$TARGET_PREFIX" ]; then
  msg "Cleaning existing install target $TARGET_PREFIX..."
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    echo "[DRY RUN] rm -rf \"$TARGET_PREFIX\""
  else
    rm -rf "$TARGET_PREFIX"
  fi
fi
msg "Creating install target directory: $TARGET_PREFIX"
if [ "${DRY_RUN:-0}" -eq 1 ]; then
    echo "[DRY RUN] mkdir -p \"$TARGET_PREFIX\""
else
    mkdir -p "$TARGET_PREFIX"
fi


# Check for skip flags (loaded from snapshot)
if [ "${SKIP_64BIT_BUILD:-false}" = "true" ] && [ "${SKIP_32BIT:-false}" = "true" ]; then
  warning "Both 64-bit and 32-bit builds were skipped. Nothing to install."
  exit 0
elif [ "${SKIP_64BIT_BUILD:-false}" = "true" ]; then
  warning "Skipping 64-bit install (SKIP_64BIT set)"
fi

# Move staged into place
mkdir -p "$(dirname "$TARGET_PREFIX")"

# If the staging tree contains an absolute-prefix subdir (happens when callers passed absolute PREFIX
# into make install), detect and rsync the inner prefix instead of copying a nested absolute path.
# Preferred layout: STAGE_DIR contains root-relative layout (when we used PREFIX="/").
if [ -d "${STAGE_DIR}${TARGET_PREFIX}" ]; then
  echo "Detected staged inner prefix at: ${STAGE_DIR}${TARGET_PREFIX} — syncing that into ${TARGET_PREFIX}"
  echocmd="rsync -aH --delete \"${STAGE_DIR}${TARGET_PREFIX}/\" \"${TARGET_PREFIX}/\""
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    echo "[DRY RUN] $echocmd"
  else
    rsync -aH --delete "${STAGE_DIR}${TARGET_PREFIX}/" "${TARGET_PREFIX}/"
  fi
else
  echo "Syncing staged root ${STAGE_DIR} into ${TARGET_PREFIX}"
  echocmd="rsync -aH --delete \"${STAGE_DIR}/\" \"${TARGET_PREFIX}/\""
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    echo "[DRY RUN] $echocmd"
  else
    rsync -aH --delete "${STAGE_DIR}/" "$TARGET_PREFIX/"
  fi
fi

# Fix ownership/permissions (user-level install)
if [ "${DRY_RUN:-0}" -eq 0 ]; then
  msg "Fixing permissions/ownership..."
  chmod -R u+w,a+rX "$TARGET_PREFIX"
  # Since this is likely a user-level build/install, setting ownership to current user is safe
  chown -R "$(id -un)":"$(id -gn)" "$TARGET_PREFIX" || true
fi

msg "Installation complete to: $TARGET_PREFIX"
echo "You can now run Wine using: $TARGET_PREFIX/bin/wine"
echo
echo "To clean up the staging area and build directories:"
echo "  rm -rf \"$STAGE_DIR\" \"$BUILD_RUN_DIR\""
echo "  # Note: Do NOT remove the source directory: $DEST_ROOT/wine-10.20"
echo

# 3. Clean up the build/stage directories after a successful install
msg "Cleaning up successful staging directory: $STAGE_DIR"
if [ "${DRY_RUN:-0}" -eq 0 ]; then
  rm -rf "$STAGE_DIR"
fi
msg "Cleaning up successful build directory: $BUILD_RUN_DIR"
if [ "${DRY_RUN:-0}" -eq 0 ]; then
  rm -rf "$BUILD_RUN_DIR"
fi
