# ══════════════════════════════════════════════════════════════════════════════
#  Source catalogues
# ══════════════════════════════════════════════════════════════════════════════

# ── Wine source (required, pick one) ─────────────────────────────────────────
declare -A WINE_SOURCE_URL=(
    [mainline]="https://gitlab.winehq.org/wine/wine.git"
    [experimental]="https://gitlab.winehq.org/wine/wine.git"
    [staging]="https://gitlab.winehq.org/wine/wine.git"
    [proton-wine]="https://github.com/ValveSoftware/wine.git"
    [proton-wine-experimental]="https://github.com/ValveSoftware/wine.git"
    [ge-proton]="https://github.com/ValveSoftware/wine.git"
    [kron4ek-tkg]="https://github.com/Kron4ek/wine-tkg.git"
    [mythix-wine]="https://github.com/ValveSoftware/wine.git"
)
declare -A WINE_SOURCE_BRANCH=(
    [mainline]=""              # version picker selects the tag (wine-X.Y)
    [experimental]="master"   # WineHQ bleeding edge
    [staging]=""               # version picker queries wine-staging tags; clone at matching mainline tag
    [proton-wine]=""              # version picker selects the branch (proton_X.Y)
    [proton-wine-experimental]="bleeding-edge"
    [ge-proton]=""                # set by GE release picker → matching proton_X.Y branch
    [kron4ek-tkg]=""              # default branch tracks latest Wine + staging + TKG + ntsync
    [mythix-wine]=""              # set by MYTHIX_WINE_BASE (default: proton_10.0)
)
declare -A WINE_SOURCE_DESC=(
    [mainline]="WineHQ mainline       — official stable releases (version picker)"
    [experimental]="WineHQ experimental   — bleeding-edge master branch"
    [staging]="WineHQ + Staging      — mainline + community patches (version picker)"
    [proton-wine]="Valve proton-wine     — stable branches (version picker)"
    [proton-wine-experimental]="Valve proton-wine exp  — bleeding-edge (no version picker)"
    [ge-proton]="GE-Proton (GloriousEggroll) — proton-wine + GE gaming patches (version picker)"
    [kron4ek-tkg]="Kron4ek wine-tkg      — Wine source tree with Staging + TKG + ntsync patches"
    [mythix-wine]="Mythix Wine           — Valve proton-wine + TkG + Staging + GE (the works)"
)
declare -A WINE_SOURCE_HAS_VERSIONS=(
    [mainline]="true"
    [staging]="true"          # queries wine-staging repo for tags, then clones matching mainline
    [proton-wine]="true"
    [ge-proton]="true"        # queries GE release tags (GE-Proton9-20, etc.)
    [kron4ek-tkg]="true"
)
declare -A WINE_SOURCE_VERSION_REF_TYPE=(
    [mainline]="tags"         # wine-X.Y tags
    [staging]="tags"          # staging version picker queries wine-staging repo separately
    [proton-wine]="heads"     # branches, not tags
    [ge-proton]="tags"        # GE release tags
    [kron4ek-tkg]="tags"      # standard wine-X.Y tags
)
# Sources that need wine-staging patches applied after clone
declare -A WINE_SOURCE_NEEDS_STAGING=(
    [staging]="true"
)
# GE-Proton repo URL (separate from Wine source — used to fetch patches)
GE_PROTON_REPO="https://github.com/GloriousEggroll/proton-ge-custom.git"
# Kron4ek wine-tkg repo URL (used by mythix-wine to fetch TkG patches)
KRON4EK_TKG_REPO="https://github.com/Kron4ek/wine-tkg.git"
WINE_SOURCE_KEYS=( mainline experimental staging proton-wine proton-wine-experimental ge-proton kron4ek-tkg mythix-wine )

# ── DXVK source ──────────────────────────────────────────────────────────────
declare -A DXVK_SOURCE_URL=(
    [dxvk]="https://github.com/doitsujin/dxvk.git"
    [dxvk-async]="https://github.com/Sporif/dxvk-async.git"
    [dxvk-release]=""       # download pre-built binaries from GitHub releases
    [none]=""
)
declare -A DXVK_SOURCE_DESC=(
    [dxvk]="DXVK         — D3D9/10/11 → Vulkan (doitsujin/dxvk)"
    [dxvk-async]="DXVK async   — DXVK + async pipeline compilation"
    [dxvk-release]="DXVK release — pre-built DLLs from GitHub releases (fastest)"
    [none]="None         — skip DXVK (falls back to WineD3D for D3D9/10/11)"
)

# ── VKD3D-Proton source ───────────────────────────────────────────────────────
declare -A VKD3D_SOURCE_URL=(
    [vkd3d-proton]="https://github.com/HansKristian-Work/vkd3d-proton.git"
    [vkd3d-proton-release]=""   # download pre-built binaries from GitHub releases
    [none]=""
)
declare -A VKD3D_SOURCE_DESC=(
    [vkd3d-proton]="VKD3D-Proton         — D3D12 → Vulkan (HansKristian-Work)"
    [vkd3d-proton-release]="VKD3D-Proton release — pre-built DLLs from GitHub releases (fastest)"
    [none]="None                 — skip VKD3D-Proton (D3D12 games will not work)"
)

# ══════════════════════════════════════════════════════════════════════════════
#  Defaults  —  all overridable by flags
# ══════════════════════════════════════════════════════════════════════════════
DEST_ROOT="${_DATA_DIR}/buildz"
SRC_ROOT="${_DATA_DIR}/src"

WINE_SOURCE_KEY=""
WINE_SOURCE_BRANCH_ARG=""

DXVK_SOURCE_KEY="dxvk-release"         # default: download pre-built from GitHub
DXVK_BRANCH_ARG=""
VKD3D_SOURCE_KEY="vkd3d-proton-release" # default: download pre-built from GitHub
VKD3D_BRANCH_ARG=""

BUILD_NAME=""
MYTHIX_WINE_BASE="${MYTHIX_WINE_BASE:-proton_10.0}"  # proton_10.0 | bleeding-edge
JOBS="${JOBS:-$(nproc)}"
SKIP_32BIT=false
NO_PULL=false
RESUME=false
SKIP_WINE_BUILD=false      # set by --dxvk-only / --vkd3d-only
SKIP_DXVK=false           # set by --vkd3d-only
REINSTALL_COMPONENTS=false # set by --reinstall-components
SNIPER_MODE=false          # DEPRECATED — use STEAM_RUNTIME instead
STEAM_RUNTIME=""           # none | soldier | sniper | slr4 ("" = ask or profile default)

# Steam Runtime appid lookup (from Valve's toolmanifest files)
declare -A STEAM_RUNTIME_APPID=(
    [none]=""
    [soldier]="1391110"
    [sniper]="1628350"
    [slr4]="4183110"
)
declare -A STEAM_RUNTIME_LABEL=(
    [none]="Standard host mode (no container)"
    [soldier]="Steam Linux Runtime 2.0 — Soldier (Proton 5–7 era)"
    [sniper]="Steam Linux Runtime 3.0 — Sniper (Proton 8+)"
    [slr4]="Steam Linux Runtime 4.0 — Heavy (default for Proton 11+)"
)
CONTAINER_BUILD=""         # "" = ask interactively; "true" = container; "false" = native
DRY_RUN=0
CUSTOM_CFG="${_CFG_DIR}/neutron-customization.cfg"
BUILD_CORE="${_LIB_DIR}/neutron-build-core.sh"
PACKAGER="${_LIB_DIR}/neutron-package.sh"
DXVK_BUILDER="${_LIB_DIR}/neutron-dxvk-build.sh"
VKD3D_BUILDER="${_LIB_DIR}/neutron-vkd3d-build.sh"
PATCHER="${_LIB_DIR}/neutron-patcher.sh"
PATCHES_DIR="${_LIB_DIR}/patches"
PATCH_GROUPS=""            # space-separated group names, "all", "none", or "" (interactive)

# ── Build profiles (pinned, reproducible Mythix Wine recipes) ─────────────────
PROFILES_DIR="${_LIB_DIR}/profiles"
DEFAULT_PROFILE="mythix-11.19"  # used when no --profile and no --source given
PROFILE_NAME=""            # --profile NAME|DIR  →  profiles/<name>/profile.conf
PROFILE_DIR=""             # resolved by _load_profile
NEUTRON_BUILD_MODE="${NEUTRON_BUILD_MODE:-}"  # --build-mode classic|wow64 ("" = per source)
ALLOW_PATCH_FAILURES=false # --allow-patch-failures: let profile patch layers fail (curation work)
PATCH_PIPELINE="${_LIB_DIR}/mythix-patch-pipeline.sh"
FFMPEG_BUILDER="${_LIB_DIR}/mythix-ffmpeg-build.sh"

# ── Build tuning toggles ──────────────────────────────────────────────────────
NO_CCACHE=false           # --no-ccache: disable ccache entirely
KEEP_SYMBOLS=false        # --keep-symbols: skip strip, keep debug info
BUILD_TYPE="release"      # --build-type release|debug|debugoptimized
NATIVE_MARCH=false        # --native: compile with -march=native (non-portable)
LTO=false                 # --lto: enable link-time optimisation (slow link)

