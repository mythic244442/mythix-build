# ══════════════════════════════════════════════════════════════════════════════
#  _download_dxvk_release  — install pre-built DXVK DLLs from GitHub releases
#  _download_vkd3d_release — install pre-built VKD3D-Proton DLLs from GitHub releases
#
#  Usage: _download_dxvk_release  <dest_64> <dest_32>
#         _download_vkd3d_release <dest_64> <dest_32>
# ══════════════════════════════════════════════════════════════════════════════
_download_dxvk_release() {
    local dest_64="$1" dest_32="$2"

    msg "Fetching latest DXVK release info from GitHub..."
    local release_json
    release_json=$(curl -fsSL \
        "https://api.github.com/repos/doitsujin/dxvk/releases/latest") \
        || err "Failed to fetch DXVK release info from GitHub API"

    local version tarball_url
    version=$(printf '%s' "$release_json" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")
    tarball_url=$(printf '%s' "$release_json" \
        | python3 -c "
import sys, json
rel = json.load(sys.stdin)
url = next((a['browser_download_url'] for a in rel['assets']
            if a['name'].endswith('.tar.gz')), None)
if not url: raise SystemExit('No .tar.gz asset in DXVK release')
print(url)")
    msg2 "DXVK version : ${version}"
    msg2 "Downloading  : ${tarball_url}"

    local tmpdir
    tmpdir=$(mktemp -d)
    curl -fsSL "$tarball_url" | tar -xz -C "$tmpdir" \
        || err "Failed to download/extract DXVK tarball"

    mkdir -p "$dest_64" "$dest_32"
    local c64=0 c32=0
    while IFS= read -r f; do cp "$f" "$dest_64/"; c64=$(( c64+1 )); done \
        < <(find "$tmpdir" -path '*/x64/*.dll' 2>/dev/null | sort)
    while IFS= read -r f; do cp "$f" "$dest_32/"; c32=$(( c32+1 )); done \
        < <(find "$tmpdir" -path '*/x32/*.dll' 2>/dev/null | sort)
    rm -rf "$tmpdir"

    [ "$c64" -gt 0 ] || err "No x64 DLLs found in DXVK release tarball"
    ok "DXVK ${version} installed: ${c64} x64 DLLs, ${c32} x32 DLLs"
}

_download_vkd3d_release() {
    local dest_64="$1" dest_32="$2"

    msg "Fetching latest VKD3D-Proton release info from GitHub..."
    local release_json
    release_json=$(curl -fsSL \
        "https://api.github.com/repos/HansKristian-Work/vkd3d-proton/releases/latest") \
        || err "Failed to fetch VKD3D-Proton release info from GitHub API"

    local version tarball_url
    version=$(printf '%s' "$release_json" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")
    tarball_url=$(printf '%s' "$release_json" \
        | python3 -c "
import sys, json
rel = json.load(sys.stdin)
url = next((a['browser_download_url'] for a in rel['assets']
            if a['name'].endswith('.tar.zst')), None)
if not url: raise SystemExit('No .tar.zst asset in VKD3D-Proton release')
print(url)")
    msg2 "VKD3D-Proton version : ${version}"
    msg2 "Downloading          : ${tarball_url}"

    local tmpdir
    tmpdir=$(mktemp -d)
    curl -fsSL "$tarball_url" | tar -I zstd -x -C "$tmpdir" \
        || err "Failed to download/extract VKD3D-Proton tarball"

    mkdir -p "$dest_64" "$dest_32"
    local c64=0 c32=0
    while IFS= read -r f; do cp "$f" "$dest_64/"; c64=$(( c64+1 )); done \
        < <(find "$tmpdir" -path '*/x64/*.dll' 2>/dev/null | sort)
    while IFS= read -r f; do cp "$f" "$dest_32/"; c32=$(( c32+1 )); done \
        < <(find "$tmpdir" \( -path '*/x86/*.dll' -o -path '*/x32/*.dll' \) 2>/dev/null | sort)
    rm -rf "$tmpdir"

    [ "$c64" -gt 0 ] || err "No x64 DLLs found in VKD3D-Proton release tarball"
    ok "VKD3D-Proton ${version} installed: ${c64} x64 DLLs, ${c32} x86 DLLs"
}

# ── Fetch DXVK ────────────────────────────────────────────────────────────────
if [ "${DXVK_SOURCE_KEY}" != "none" ] && [ "${DXVK_SOURCE_KEY}" != "dxvk-release" ]; then
    section "DXVK source  "
    DXVK_SOURCE_DIR="${SRC_ROOT}/dxvk-${DXVK_SOURCE_KEY}"
    _dxvk_branch="${DXVK_BRANCH_ARG:-}"
    msg2 "Source key : ${DXVK_SOURCE_KEY}"
    msg2 "Source dir : ${DXVK_SOURCE_DIR}"
    msg2 "URL        : ${DXVK_SOURCE_URL[$DXVK_SOURCE_KEY]}"
    fetch_source \
        "${DXVK_SOURCE_URL[$DXVK_SOURCE_KEY]}" \
        "$_dxvk_branch" \
        "$DXVK_SOURCE_DIR" \
        "true"
    ok "DXVK source fetched"
    export DXVK_SOURCE_DIR DXVK_SOURCE_KEY
fi

# ── Fetch VKD3D-Proton ────────────────────────────────────────────────────────
if [ "${VKD3D_SOURCE_KEY}" != "none" ] && [ "${VKD3D_SOURCE_KEY}" != "vkd3d-proton-release" ]; then
    section "VKD3D-Proton source  "
    VKD3D_SOURCE_DIR="${SRC_ROOT}/vkd3d-proton"
    _vkd3d_branch="${VKD3D_BRANCH_ARG:-}"
    msg2 "Source key : ${VKD3D_SOURCE_KEY}"
    msg2 "Source dir : ${VKD3D_SOURCE_DIR}"
    msg2 "URL        : ${VKD3D_SOURCE_URL[$VKD3D_SOURCE_KEY]}"
    fetch_source \
        "${VKD3D_SOURCE_URL[$VKD3D_SOURCE_KEY]}" \
        "$_vkd3d_branch" \
        "$VKD3D_SOURCE_DIR" \
        "true"
    ok "VKD3D-Proton source fetched"
    export VKD3D_SOURCE_DIR VKD3D_SOURCE_KEY
fi

# ── Start build timer ─────────────────────────────────────────────────────────
_BUILD_START=$(date +%s)

