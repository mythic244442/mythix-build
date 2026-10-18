# ══════════════════════════════════════════════════════════════════════════════
#  Dependency check
# ══════════════════════════════════════════════════════════════════════════════
check_deps() {
    section "Dependency check"
    local -a missing=()
    local -a tools=(
        git make autoconf automake pkg-config
        flex bison
        gcc g++
        i686-linux-gnu-gcc
        x86_64-w64-mingw32-gcc
        i686-w64-mingw32-gcc
        meson ninja
    )
    for t in "${tools[@]}"; do
        if command -v "$t" >/dev/null 2>&1; then
            ok "$t"
        else
            warn "MISSING: $t"
            missing+=("$t")
        fi
    done

    # glslangValidator (needed for DXVK compilation)
    if command -v glslangValidator >/dev/null 2>&1; then
        ok "glslangValidator"
    else
        warn "glslangValidator not found (needed for DXVK compilation)"
        warn "  Install: sudo apt install glslang-tools"
    fi

    # ccache (optional but strongly recommended)
    if command -v ccache >/dev/null 2>&1; then
        ok "ccache  (rebuilds will be much faster)"
    else
        warn "ccache not found — rebuilds will not be cached"
        warn "  Install: sudo apt install ccache"
    fi

    if [ "${#missing[@]}" -gt 0 ]; then
        err "Missing required tools: ${missing[*]}
     Use the Containerfile.neutron environment or install the above.
     See the README for distro-specific install commands."
    fi
    ok "All required tools present"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Disk space preflight  (warn at < 6 GB free)
# ══════════════════════════════════════════════════════════════════════════════
check_disk_space() {
    local dir="$1"
    mkdir -p "$dir"
    local avail_kb
    avail_kb=$(df --output=avail "$dir" 2>/dev/null | tail -1 || true)
    [ -n "$avail_kb" ] || return 0
    local avail_gb=$(( avail_kb / 1024 / 1024 ))
    if [ "$avail_gb" -lt 6 ]; then
        warn "Only ~${avail_gb} GB free in ${dir}"
        warn "A full Neutron build (Wine + DXVK + VKD3D-Proton + container) needs ~5-6 GB."
        warn "Use --dest to point to a filesystem with more space."
        if ( : >/dev/tty ) 2>/dev/null; then
            printf "  ${C_B}Continue anyway? [y/N]:${C_R} "
            local ans
            read -r ans
            [[ "$ans" =~ ^[yY] ]] || exit 0
        else
            warn "Non-interactive — continuing anyway."
        fi
    else
        ok "Disk space: ~${avail_gb} GB free"
    fi
}

