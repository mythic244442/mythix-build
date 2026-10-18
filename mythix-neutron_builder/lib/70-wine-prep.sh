# ══════════════════════════════════════════════════════════════════════════════
#  run_autoreconf  — regenerate configure from configure.ac
# ══════════════════════════════════════════════════════════════════════════════
run_autoreconf() {
    local src="$1"
    section "autoreconf"
    msg2 "Running autoreconf in: $src"
    run autoreconf -fvi "$src"
    ok "autoreconf complete"
}

# ══════════════════════════════════════════════════════════════════════════════
#  fix_opencl_headers
#  Wine's configure looks for /usr/include/OpenCL/opencl.h (macOS layout).
#  On Linux the header lives at /usr/include/CL/cl.h — create a symlink.
# ══════════════════════════════════════════════════════════════════════════════
fix_opencl_headers() {
    local linux_h="/usr/include/CL/cl.h"
    local compat_h="/usr/include/OpenCL/opencl.h"

    if [ -f "$compat_h" ]; then
        ok "OpenCL compat header present"
        return
    fi

    if [ ! -f "$linux_h" ]; then
        warn "OpenCL headers not found — OpenCL will be disabled in this build."
        warn "Install with: sudo apt install ocl-icd-opencl-dev"
        return
    fi

    msg2 "Creating OpenCL compat symlink (macOS path expected by configure)..."
    if [ "$DRY_RUN" -eq 0 ]; then
        if ! mkdir -p /usr/include/OpenCL 2>/dev/null; then
            if command -v sudo >/dev/null 2>&1; then
                sudo mkdir -p /usr/include/OpenCL
            else
                warn "Could not create /usr/include/OpenCL — OpenCL may be disabled"
                return
            fi
        fi
        if ! ln -sf "$linux_h" "$compat_h" 2>/dev/null; then
            if command -v sudo >/dev/null 2>&1; then
                sudo ln -sf "$linux_h" "$compat_h" || \
                    { warn "Could not create $compat_h — OpenCL may be disabled"; return; }
            else
                warn "Could not create $compat_h — OpenCL may be disabled"
                return
            fi
        fi
        ok "OpenCL compat symlink created"
    else
        dim "  [dry-run] ln -sf $linux_h $compat_h"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  _kron4ek_tkg_compat_redist  <BUILD_DIR>
#
#  Applies all compatibility patches needed to run proton-tkg's  make redist
#  against a Kron4ek wine build (which lacks several Valve-only APIs) and
#  runs the build inside the umu-sdk container.
#
#  Encodes every fix discovered during the mythix Neutron 11 build session:
#    1. Wine binary stubs  (wine64 / preloaders missing in unified builds)
#    2. Valve makedep      (Kron4ek makedep segfaults on Valve source syntax)
#    3. wine_unix_to_nt_file_name stub  (lsteamclient/vrclient)
#    4. __chkstk_ms stub   (MinGW 14 stack-probe symbol not in libgcc)
#    5. wineopenxr stubs   (Valve-only VkCreateInfoWine* types)
#    6. Stamp freeze       (prevent config.status / makedep clobber loops)
#    7. Destination dirs   (pre-create so /usr/bin/install succeeds)
#    8. install-sh fix     (noexec homefs — redirect to /usr/bin/install)
#    9. gst_plugins_rs skip (needs internet to download Rust crates)
#   10. wineopenxr skip    (Valve-only Vulkan extensions, VR not needed)
#   11. Component Makefile patching  (winecrt0 path, install-sh → /usr/bin/install)
#   12. Retry loop         (up to 5 attempts; re-freezes stamps each time)
#   13. DLL rename         (vrclient.dll → vrclient_x64.dll for Proton compat)
# ══════════════════════════════════════════════════════════════════════════════
_kron4ek_tkg_compat_redist() {
    local BUILD="$1"
    local PROTON_ROOT
    PROTON_ROOT="$(dirname "$BUILD")"
    local VALVE_SRC="/tmp/mythix-valve-wine-src"
    local VALVE_BUILD="/tmp/mythix-valve-wine-build"

    section "Kron4ek TKG compat redist"
    msg2 "BUILD dir  : $BUILD"
    msg2 "PROTON root: $PROTON_ROOT"

    # ── 1. Wine binary stubs ──────────────────────────────────────────────────
    msg2 "Step 1/13: wine binary stubs"
    local DST_X64="$BUILD/dst-wine-x86_64"
    local DST_I386="$BUILD/dst-wine-i386"
    for dir in "$DST_X64/bin" "$DST_I386/bin"; do
        [ -d "$dir" ] || continue
        [ -f "$dir/wine" ] || continue
        [ -f "$dir/wine64" ]           || { cp -f "$dir/wine" "$dir/wine64";           ok "  created wine64 in $dir"; }
        [ -f "$dir/wine64-preloader" ] || { cp -f "$dir/wine" "$dir/wine64-preloader"; ok "  created wine64-preloader"; }
        [ -f "$dir/wine-preloader" ]   || { cp -f "$dir/wine" "$dir/wine-preloader";   ok "  created wine-preloader"; }
    done
    # Touch build stamps so make doesn't try to rebuild wine
    for stamp in \
        "$BUILD/.wine-x86_64-post-build" "$BUILD/.wine-i386-post-build" \
        "$BUILD/.wine-x86_64-build"      "$BUILD/.wine-i386-build"; do
        [ -f "$stamp" ] || touch "$stamp"
    done

    # ── 2. Valve makedep ─────────────────────────────────────────────────────
    msg2 "Step 2/13: Valve makedep"
    local MAKEDEP="$BUILD/obj-wine-x86_64/tools/makedep"
    mkdir -p "$(dirname "$MAKEDEP")"
    # Check if we already have a good Valve makedep
    local needs_makedep=1
    if [ -f "$VALVE_BUILD/tools/makedep" ]; then
        needs_makedep=0
    fi
    if [ "$needs_makedep" -eq 1 ]; then
        msg2 "  Cloning Valve wine source for makedep..."
        if [ ! -d "$VALVE_SRC/.git" ]; then
            git clone --depth=1 https://github.com/ValveSoftware/wine.git "$VALVE_SRC" \
                || { warn "Could not clone Valve wine — makedep may fail"; }
        fi
        if [ -d "$VALVE_SRC" ]; then
            podman run --rm \
                -v "$VALVE_SRC":"$VALVE_SRC" \
                -v "$VALVE_BUILD":"$VALVE_BUILD" \
                ghcr.io/open-wine-components/umu-sdk:latest \
                bash -c "
                    set -e
                    cd '$VALVE_SRC'
                    python3 dlls/winevulkan/make_vulkan 2>/dev/null || true
                    perl tools/make_specfiles 2>/dev/null || true
                    perl tools/make_requests 2>/dev/null || true
                    autoreconf -fiv 2>/dev/null
                    mkdir -p '$VALVE_BUILD'
                    cd '$VALVE_BUILD'
                    '$VALVE_SRC/configure' --enable-archs=i386,x86_64 2>/dev/null
                    make -j\$(nproc) tools/makedep
                " && ok "  Valve makedep built" || warn "  Valve makedep build failed — will retry without"
        fi
    fi
    if [ -f "$VALVE_BUILD/tools/makedep" ]; then
        cp "$VALVE_BUILD/tools/makedep" "$MAKEDEP"
        chmod +x "$MAKEDEP"
        ok "  Valve makedep installed"
    else
        warn "  Valve makedep not available — configure segfaults may occur"
    fi

    # ── 3–5. Patch source files ───────────────────────────────────────────────
    msg2 "Step 3-5/13: patching source files"
    python3 - "$BUILD" "$PROTON_ROOT" << 'PYEOF'
import sys, os, subprocess
BUILD, PROTON_ROOT = sys.argv[1], sys.argv[2]

unix_stub = """\n/* mythix compat: stub wine_unix_to_nt_file_name for Kron4ek wine */\n#ifndef STATUS_NOT_IMPLEMENTED\n#define STATUS_NOT_IMPLEMENTED ((NTSTATUS)0xC0000002L)\n#endif\nstatic inline NTSTATUS wine_unix_to_nt_file_name(const char *n, void *b, unsigned int *s)\n{ (void)n; (void)b; (void)s; return STATUS_NOT_IMPLEMENTED; }\n/* mythix compat end */\n"""

chkstk_stub = """\n/* mythix compat: __chkstk_ms stub for MinGW 14 */\n#if defined(__i386__) || defined(__x86_64__)\nvoid __chkstk_ms(void) {}\nvoid ___chkstk_ms(void) {}\n#endif\n/* mythix chkstk end */\n"""

openxr_stub_h = """\
/* mythix compat: stub Valve wine Vulkan extensions for Kron4ek wine */
#ifndef LOONI_WINE_VK_STUBS_H
#define LOONI_WINE_VK_STUBS_H
#ifndef VK_STRUCTURE_TYPE_CREATE_INFO_WINE_INSTANCE_CALLBACK
#define VK_STRUCTURE_TYPE_CREATE_INFO_WINE_INSTANCE_CALLBACK ((VkStructureType)1000467000)
#endif
#ifndef VK_STRUCTURE_TYPE_CREATE_INFO_WINE_DEVICE_CALLBACK
#define VK_STRUCTURE_TYPE_CREATE_INFO_WINE_DEVICE_CALLBACK   ((VkStructureType)1000467001)
#endif
typedef struct VkCreateInfoWineInstanceCallback {
    VkStructureType sType; const void *pNext;
    UINT64 native_create_callback; void *context;
} VkCreateInfoWineInstanceCallback;
typedef struct VkCreateInfoWineDeviceCallback {
    VkStructureType sType; const void *pNext;
    UINT64 native_create_callback; void *context;
} VkCreateInfoWineDeviceCallback;
static inline void __wine_set_unix_env(const char *v, const char *val)
{ (void)v; (void)val; }
#endif /* LOONI_WINE_VK_STUBS_H */
"""

def patch_prepend(path, stub, marker):
    if not os.path.exists(path): return
    lines = open(path).readlines()
    if any(marker in l for l in lines):
        print(f'  already patched: {os.path.basename(path)}'); return
    last_inc = max((i for i,l in enumerate(lines) if l.strip().startswith('#include')), default=0)
    lines.insert(last_inc + 1, stub)
    open(path, 'w').write(''.join(lines))
    print(f'  patched: {os.path.basename(path)}')

# unix_to_nt stub — lsteamclient unixlib + vrclient json_converter
for name in ['unixlib.cpp', 'json_converter.cpp']:
    r = subprocess.run(['find', PROTON_ROOT, '-name', name], capture_output=True, text=True)
    for f in r.stdout.strip().split('\n'):
        if f.strip():
            patch_prepend(f.strip(), unix_stub, 'mythix compat: stub wine_unix')

# chkstk stub — steamclient_main + vrclient_main
r = subprocess.run(['find', PROTON_ROOT, '(', '-name', 'steamclient_main.c', '-o', '-name', 'vrclient_main.c', ')'],
                   capture_output=True, text=True)
for f in r.stdout.strip().split('\n'):
    if f.strip():
        patch_prepend(f.strip(), chkstk_stub, 'mythix compat: __chkstk')

# wineopenxr stub header + include injection
r = subprocess.run(['find', PROTON_ROOT, '-name', 'openxr_loader.c'], capture_output=True, text=True)
for f in r.stdout.strip().split('\n'):
    if not f.strip(): continue
    d = os.path.dirname(f.strip())
    open(os.path.join(d, 'mythix-wine-vk-stubs.h'), 'w').write(openxr_stub_h)
    content = open(f.strip()).read()
    if 'mythix-wine-vk-stubs.h' not in content:
        open(f.strip(), 'w').write('#include "mythix-wine-vk-stubs.h"\n' + content)
        print(f'  patched: openxr_loader.c in {d}')

print('Source patching done.')
PYEOF

    # ── 6. Stamp freeze helper (called repeatedly) ────────────────────────────
    _freeze_all_stamps() {
        local B="$1"
        local V="${2:-/tmp/mythix-valve-wine-build}"
        # makedep
        [ -f "$V/tools/makedep" ] && {
            cp "$V/tools/makedep" "$B/obj-wine-x86_64/tools/makedep" 2>/dev/null || true
            chmod +x "$B/obj-wine-x86_64/tools/makedep" 2>/dev/null || true
        }
        touch -t 203001010000 \
            "$B/obj-wine-x86_64/tools/makedep" \
            "$B/.wine-x86_64-configure"  "$B/.wine-x86_64-tools" \
            "$B/.wine-x86_64-build"      "$B/.wine-x86_64-post-build" \
            "$B/.wine-i386-configure"    "$B/.wine-i386-tools" \
            "$B/.wine-i386-build"        "$B/.wine-i386-post-build" \
            "$B/.lsteamclient-x86_64-configure" "$B/.lsteamclient-i386-configure" \
            "$B/.vrclient-x86_64-configure"     "$B/.vrclient-i386-configure" \
            "$B/.wineopenxr-x86_64-configure"   "$B/.wineopenxr-x86_64-build" \
            "$B/.wineopenxr-x86_64-dist"        "$B/.wineopenxr-x86_64-post-build" \
            "$B/.steamexe-x86_64-configure"     "$B/.steamexe-i386-configure" \
            "$B/.steamexe-x86_64-build"         "$B/.steamexe-x86_64-post-build" \
            "$B/.steamexe-i386-build"            "$B/.steamexe-i386-post-build" \
            "$B/.gst_plugins_rs-i386-configure"  "$B/.gst_plugins_rs-i386-build" \
            "$B/.gst_plugins_rs-i386-dist"       "$B/.gst_plugins_rs-i386-post-build" \
            "$B/.gst_plugins_rs-x86_64-configure" "$B/.gst_plugins_rs-x86_64-build" \
            "$B/.gst_plugins_rs-x86_64-dist"     "$B/.gst_plugins_rs-x86_64-post-build" \
            2>/dev/null || true
        find "$B/obj-wine-x86_64" "$B/obj-wine-i386" \
            -name "Makefile" 2>/dev/null | xargs touch -t 203001010000 2>/dev/null || true
    }

    msg2 "Step 6/13: freezing stamps"
    _freeze_all_stamps "$BUILD" "$VALVE_BUILD"

    # ── 7. Pre-create destination directories ─────────────────────────────────
    msg2 "Step 7/13: pre-creating destination dirs"
    mkdir -p \
        "$BUILD/dst-lsteamclient-i386/lib/wine/i386-windows" \
        "$BUILD/dst-lsteamclient-i386/lib/wine/i386-unix" \
        "$BUILD/dst-lsteamclient-x86_64/lib/wine/x86_64-windows" \
        "$BUILD/dst-lsteamclient-x86_64/lib/wine/x86_64-unix" \
        "$BUILD/dst-vrclient-i386/lib/wine/i386-windows" \
        "$BUILD/dst-vrclient-i386/lib/wine/i386-unix" \
        "$BUILD/dst-vrclient-x86_64/lib/wine/x86_64-windows" \
        "$BUILD/dst-vrclient-x86_64/lib/wine/x86_64-unix" \
        "$BUILD/dst-steamexe-x86_64/lib/wine/x86_64-windows" \
        "$BUILD/dst-steamexe-i386/lib/wine/i386-windows"

    # ── 8. install-sh fix (noexec homefs) ────────────────────────────────────
    msg2 "Step 8/13: install-sh fix"
    mkdir -p "$BUILD/src-wine/tools"
    python3 -c "
import os, stat
path = '$BUILD/src-wine/tools/install-sh'
script = '#!/bin/sh\nmode=\"\" src=\"\" dst=\"\"\nwhile [ \$# -gt 0 ]; do\n  case \"\$1\" in\n    -m) mode=\"\$2\"; shift 2;;\n    -d) shift; mkdir -p \"\$1\"; shift;;\n    -*) shift;;\n    *) if [ -z \"\$src\" ]; then src=\"\$1\"; else dst=\"\$1\"; fi; shift;;\n  esac\ndone\n[ -n \"\$src\" ] && [ -n \"\$dst\" ] && cp \"\$src\" \"\$dst\"\n[ -n \"\$mode\" ] && [ -n \"\$dst\" ] && chmod \"\$mode\" \"\$dst\"\nexit 0\n'
open(path, 'w', newline='\n').write(script)
os.chmod(path, 0o755)
print('  install-sh written')
"

    # ── 9–10. Skip gst_plugins_rs and wineopenxr (done via stamps above) ─────
    msg2 "Step 9-10/13: gst_plugins_rs and wineopenxr skipped via stamps"

    # ── 11–12. Redist build with retry loop ───────────────────────────────────
    msg2 "Step 11-12/13: running make CONTAINER=1 redist (up to 5 attempts)"
    local attempt=1
    local max_attempts=5
    local exit_code=1
    local WINECRT_W64="$BUILD/dst-wine-x86_64/lib/wine/x86_64-windows"
    local WINECRT_LIB="$BUILD/dst-wine-x86_64/lib/x86_64-linux-gnu"
    local LOG_BASE="/tmp/mythix-redist"

    _patch_component_makefiles() {
        local B="$1"
        local CRT_W64="$2"
        local CRT_LIB="$3"
        for mf in \
            "$B/obj-lsteamclient-x86_64/Makefile" \
            "$B/obj-lsteamclient-i386/Makefile" \
            "$B/obj-vrclient-x86_64/Makefile" \
            "$B/obj-vrclient-i386/Makefile" \
            "$B/obj-steamexe-x86_64/Makefile" \
            "$B/obj-steamexe-i386/Makefile"; do
            [ -f "$mf" ] || continue
            sed -i \
                "s|[^ ]*/src-wine/tools/install-sh[^ ]*|/usr/bin/install|g;
                 s|-lwinecrt0|-L${CRT_W64} -L${CRT_LIB} -lwinecrt0|g" \
                "$mf" 2>/dev/null || true
            touch -t 203001010000 "$mf" 2>/dev/null || true
        done
    }

    while [ "$attempt" -le "$max_attempts" ] && [ "$exit_code" -ne 0 ]; do
        msg2 "  redist attempt $attempt/$max_attempts..."
        _freeze_all_stamps "$BUILD" "$VALVE_BUILD"
        _patch_component_makefiles "$BUILD" "$WINECRT_W64" "$WINECRT_LIB"

        podman run --rm \
            -v "$BUILD":"$BUILD" \
            -v "$(dirname "$BUILD")":"$(dirname "$BUILD")" \
            -w "$BUILD" -e MAKEFLAGS \
            ghcr.io/open-wine-components/umu-sdk:latest \
            make -j"$(nproc)" CONTAINER=1 redist \
            > "${LOG_BASE}-${attempt}.log" 2>&1
        exit_code=$?

        if [ "$exit_code" -eq 0 ]; then
            ok "  redist succeeded on attempt $attempt"
        else
            warn "  attempt $attempt failed (exit $exit_code) — see ${LOG_BASE}-${attempt}.log"
            grep -E "error:|Error [0-9]|undefined ref|not found|No such" \
                "${LOG_BASE}-${attempt}.log" 2>/dev/null | tail -5 >&2 || true
            attempt=$((attempt + 1))
            # Touch any new stamps the failed run created
            find "$BUILD" -name ".*-build" -newer "$BUILD/.wine-x86_64-build" \
                2>/dev/null | xargs touch -t 203001010000 2>/dev/null || true
        fi
    done

    if [ "$exit_code" -ne 0 ]; then
        warn "redist failed after $max_attempts attempts"
        warn "Last log: ${LOG_BASE}-$((attempt-1)).log"
        return 1
    fi

    # ── 13. DLL rename (vrclient.dll → vrclient_x64.dll) ─────────────────────
    msg2 "Step 13/13: renaming vrclient.dll → vrclient_x64.dll"
    local VRCLIENT_W64="$BUILD/dst-vrclient-x86_64/lib/wine/x86_64-windows"
    local VRCLIENT_UNIX="$BUILD/dst-vrclient-x86_64/lib/wine/x86_64-unix"
    if [ -f "$VRCLIENT_W64/vrclient.dll" ] && [ ! -f "$VRCLIENT_W64/vrclient_x64.dll" ]; then
        cp "$VRCLIENT_W64/vrclient.dll" "$VRCLIENT_W64/vrclient_x64.dll"
        ok "  vrclient.dll → vrclient_x64.dll"
    fi
    if [ -f "$VRCLIENT_UNIX/vrclient.so" ] && [ ! -f "$VRCLIENT_UNIX/vrclient_x64.so" ]; then
        cp "$VRCLIENT_UNIX/vrclient.so" "$VRCLIENT_UNIX/vrclient_x64.so" 2>/dev/null || true
    fi

    ok "Kron4ek TKG compat redist complete"
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  _kron4ek_tkg_install_redist_to_proton  <BUILD_DIR> <PROTON_PKG_DIR>
#
#  Copies the redist output (lsteamclient, vrclient, steamexe) from the
#  proton-tkg build tree into the assembled Neutron package.
# ══════════════════════════════════════════════════════════════════════════════
_kron4ek_tkg_install_redist_to_proton() {
    local BUILD="$1"
    local PKG="$2"

    section "Installing TKG redist into Neutron package"

    local WINE_LIB="$PKG/files/lib/wine"
    mkdir -p \
        "$WINE_LIB/x86_64-windows" "$WINE_LIB/x86_64-unix" \
        "$WINE_LIB/i386-windows"   "$WINE_LIB/i386-unix"

    local copied=0
    for src_dir in \
        "$BUILD/dst-lsteamclient-x86_64/lib/wine/x86_64-windows" \
        "$BUILD/dst-vrclient-x86_64/lib/wine/x86_64-windows" \
        "$BUILD/dst-steamexe-x86_64/lib/wine/x86_64-windows"; do
        [ -d "$src_dir" ] || continue
        find "$src_dir" -name "*.dll" | while read -r f; do
            cp -f "$f" "$WINE_LIB/x86_64-windows/" && copied=$((copied+1))
        done
    done
    for src_dir in \
        "$BUILD/dst-lsteamclient-x86_64/lib/wine/x86_64-unix" \
        "$BUILD/dst-vrclient-x86_64/lib/wine/x86_64-unix"; do
        [ -d "$src_dir" ] || continue
        find "$src_dir" -name "*.so" | while read -r f; do
            cp -f "$f" "$WINE_LIB/x86_64-unix/" 2>/dev/null || true
        done
    done
    for src_dir in \
        "$BUILD/dst-lsteamclient-i386/lib/wine/i386-windows" \
        "$BUILD/dst-vrclient-i386/lib/wine/i386-windows"; do
        [ -d "$src_dir" ] || continue
        find "$src_dir" -name "*.dll" | while read -r f; do
            cp -f "$f" "$WINE_LIB/i386-windows/" && copied=$((copied+1))
        done
    done

    # Ensure vrclient_x64.dll name exists
    [ -f "$WINE_LIB/x86_64-windows/vrclient.dll" ] && \
    [ ! -f "$WINE_LIB/x86_64-windows/vrclient_x64.dll" ] && \
        cp "$WINE_LIB/x86_64-windows/vrclient.dll" \
           "$WINE_LIB/x86_64-windows/vrclient_x64.dll" && \
        ok "  vrclient.dll → vrclient_x64.dll"

    ok "Redist DLLs installed into Neutron package"
}

# ══════════════════════════════════════════════════════════════════════════════
#  pregen_headers
#  Pre-generate headers that makedep needs before configure/autoreconf runs.
#  Must be called on the source tree BEFORE run_autoreconf.
#
#  Generates three files using scripts bundled in the source tree:
#    include/wine/vulkan.h      — from dlls/winevulkan/make_vulkan  (Python)
#    dlls/ntdll/ntsyscalls.h    — from tools/make_specfiles          (Perl)
#    include/wine/server_protocol.h — from tools/make_requests       (Perl)
# ══════════════════════════════════════════════════════════════════════════════
pregen_headers() {
    local src="$1"
    section "Pre-generating headers"

    # ── wine/vulkan.h ─────────────────────────────────────────────────────────
    local vulkan_out="${src}/include/wine/vulkan.h"
    local vulkan_script="${src}/dlls/winevulkan/make_vulkan"
    if [ ! -f "$vulkan_out" ]; then
        msg2 "Generating wine/vulkan.h ..."
        if [ -f "$vulkan_script" ]; then
            if [ "$DRY_RUN" -eq 0 ]; then
                ( cd "$src" && python3 dlls/winevulkan/make_vulkan ) \
                    || err "make_vulkan failed.
     The script needs python3 and the Vulkan registry XML.
     Inside the container these should both be present.
     Check: python3 --version  and  ls ${src}/dlls/winevulkan/"
                ok "wine/vulkan.h generated"
            else
                dim "  [dry-run] python3 dlls/winevulkan/make_vulkan"
            fi
        else
            warn "make_vulkan not found at ${vulkan_script}"
            warn "wine/vulkan.h will be missing — configure will likely fail."
        fi
    else
        ok "wine/vulkan.h  (already present)"
    fi

    # ── ntsyscalls.h  (Wine 10.x+, not present in all trees) ─────────────────
    local ntsys_out="${src}/dlls/ntdll/ntsyscalls.h"
    local specfiles="${src}/tools/make_specfiles"
    if [ ! -f "$ntsys_out" ] && [ -f "$specfiles" ]; then
        msg2 "Generating ntsyscalls.h ..."
        if [ "$DRY_RUN" -eq 0 ]; then
            ( cd "$src" && perl tools/make_specfiles ) \
                || err "make_specfiles failed. Install: sudo apt install perl"
            ok "ntsyscalls.h generated"
        else
            dim "  [dry-run] perl tools/make_specfiles"
        fi
    else
        ok "ntsyscalls.h  (present or not required by this tree)"
    fi

    # ── server_protocol.h ─────────────────────────────────────────────────────
    local proto_out="${src}/include/wine/server_protocol.h"
    local make_req="${src}/tools/make_requests"
    if [ -f "$make_req" ]; then
        local proto_def="${src}/server/protocol.def"
        if [ ! -f "$proto_out" ] || [ "$make_req" -nt "$proto_out" ] || [ "$proto_def" -nt "$proto_out" ]; then
            msg2 "Generating server_protocol.h ..."
            if [ "$DRY_RUN" -eq 0 ]; then
                ( cd "$src" && perl tools/make_requests ) \
                    || err "make_requests failed. Install: sudo apt install perl"
                ok "server_protocol.h generated"
            else
                dim "  [dry-run] perl tools/make_requests"
            fi
        else
            ok "server_protocol.h  (up to date)"
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  _install_logged  — run make install with a magenta/cyan progress bar
#
#  Tracks lines matching "tools/install" to count files being installed.
#  Falls back to plain output in non-interactive or --verbose mode.
# ══════════════════════════════════════════════════════════════════════════════
_install_logged() {
    # $@ = make -C <dir> install args

    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        run make "$@" install; return
    fi

    # Count total install operations via dry-run
    local _total=0
    if [ -t 1 ] && [ "${VERBOSE_BUILD:-false}" != "true" ]; then
        printf "${C_DIM}  Counting install steps...${C_R}"
        _total=$(
            make "$@" install -n 2>/dev/null \
            | grep -c 'tools/install' || true
        )
        printf "\r\033[K"
        [ "$_total" -eq 0 ] && _total=1
    fi

    if [ -t 1 ] && [ "${VERBOSE_BUILD:-false}" != "true" ]; then
        local _cur=0 _start _make_exit
        _start=$(date +%s)

        # Print 2 reserved lines for the install HUD
        printf "\n\n"

        _draw_install() {
            local cur="$1" tot="$2" phase="$3" start="$4"
            [ "$tot" -eq 0 ] && tot=1
            local w=50 f pct bar="" i=0
            f=$(( cur * w / tot )); pct=$(( cur * 100 / tot ))
            while [ "$i" -lt "$f" ]; do bar="${bar}█"; i=$(( i+1 )); done
            while [ "$i" -lt "$w" ]; do bar="${bar}░"; i=$(( i+1 )); done
            local now e estr="0s"
            now=$(date +%s); e=$(( now - start ))
            if   [ "$e" -ge 3600 ]; then estr="$(( e/3600 ))h$(( (e%3600)/60 ))m$(( e%60 ))s"
            elif [ "$e" -ge 60   ]; then estr="$(( e/60 ))m$(( e%60 ))s"
            else                         estr="${e}s"; fi
            printf "\033[2A\033[K${C_MAG}  [%s] %3d%%${C_R}  ${C_DIM}(%d / %d)${C_R}\n" \
                "$bar" "$pct" "$cur" "$tot"
            printf "\033[K  ${C_CYN}elapsed${C_R} %-10s  ${C_CYN}installing${C_R} %s\n" \
                "$estr" "$phase"
        }

        _draw_install 0 "$_total" "starting..." "$_start"

        set +e
        make "$@" install 2>&1 | while IFS= read -r _line; do
            printf '%s\n' "$_line" >> "${BUILD_LOG:-/dev/null}"
            if printf '%s' "$_line" | grep -q 'tools/install'; then
                _cur=$(( _cur + 1 ))
                local _dest
                _dest=$(printf '%s' "$_line" | grep -oE '[^ ]+$' | tail -1)
                _dest="${_dest##*/}"
                _draw_install "$_cur" "$_total" "$_dest" "$_start"
            fi
        done
        _make_exit=${PIPESTATUS[0]}
        set -e

        _draw_install "$_total" "$_total" "complete ✓" "$_start"
        printf "\n"

        return "$_make_exit"
    else
        make "$@" install 2>&1 | tee -a "${BUILD_LOG:-/dev/null}"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  install_wine  — make install the built Wine into the files/ directory
# ══════════════════════════════════════════════════════════════════════════════
install_wine() {
    local build_run_dir="$1"
    local install_prefix="$2"

    section "Installing Wine"
    mkdir -p "$install_prefix"

    local build_unified="${build_run_dir}/wine-unified"
    local build64="${build_run_dir}/wine64"

    # The build mode decides which trees are installed — never guess from
    # whatever trees happen to exist (a stale tree from an earlier build in
    # the other mode would win otherwise).
    local mode="${NEUTRON_BUILD_MODE:-}"
    if [ -z "$mode" ]; then
        if [ -d "$build_unified" ]; then mode="wow64"; else mode="classic"; fi
    fi

    case "$mode" in
        wow64)
            [ -f "${build_unified}/Makefile" ] || err "No wow64 build tree found: ${build_unified}"
            _install_wine_wow64 "$build_run_dir" "$install_prefix"
            ;;
        classic)
            [ -f "${build64}/Makefile" ] || err "No classic 64-bit build tree found: ${build64}"
            _install_wine_classic "$build_run_dir" "$install_prefix"
            ;;
        *)
            err "Unknown build mode: ${mode}"
            ;;
    esac

    ok "Wine installed to: $install_prefix"
}

_install_wine_wow64() {
    local build_run_dir="$1" install_prefix="$2"
    local build_unified="${build_run_dir}/wine-unified"

    msg2 "make install  (unified wow64 tree)"
    _install_logged -C "$build_unified"
    ok "Unified wow64 Wine installed"
    local build_i386_unix="${build_run_dir}/wine-i386-unix"
    if [ -d "$build_i386_unix" ] && [ -f "$build_i386_unix/Makefile" ]; then
        msg2 "Installing i386-unix drivers (unix .so files only)"
        local i386_unix_dest="${install_prefix}/lib/wine/i386-unix"
        mkdir -p "$i386_unix_dest"
        # Install the wine/wine-preloader 32-bit loaders
        for f in "$build_i386_unix"/loader/wine "$build_i386_unix"/loader/wine-preloader; do
            [ -f "$f" ] && install -m 755 "$f" "$i386_unix_dest/" && \
                msg2 "  $(basename "$f")"
        done
        # Install the 64-bit compat loader as wine64 in i386-unix (Proton convention)
        if [ -f "${install_prefix}/lib/wine/x86_64-unix/wine64" ]; then
            install -m 755 "${install_prefix}/lib/wine/x86_64-unix/wine64" "$i386_unix_dest/"
            msg2 "  wine64 (from x86_64-unix)"
        fi
        if [ -f "${install_prefix}/lib/wine/x86_64-unix/wine64-preloader" ]; then
            install -m 755 "${install_prefix}/lib/wine/x86_64-unix/wine64-preloader" "$i386_unix_dest/"
            msg2 "  wine64-preloader (from x86_64-unix)"
        fi
        # Install all .so unix drivers
        local _so_count=0
        for f in "$build_i386_unix"/dlls/*/*.so; do
            [ -f "$f" ] || continue
            install -m 644 "$f" "$i386_unix_dest/"
            _so_count=$(( _so_count + 1 ))
        done
        ok "i386-unix: ${_so_count} .so drivers + loaders installed"
    fi
}

_install_wine_classic() {
    local build_run_dir="$1" install_prefix="$2"
    local build64="${build_run_dir}/wine64"
    local build32="${build_run_dir}/wine32"

    msg2 "make install  (64-bit tree — classic multilib)"
    _install_logged -C "$build64"
    ok "64-bit Wine installed"
    if [ "${SKIP_32BIT}" != "true" ]; then
        [ -f "${build32}/Makefile" ] || err "No classic 32-bit build tree found: ${build32}"
        msg2 "make install  (32-bit tree)"
        _install_logged -C "$build32"
        ok "32-bit Wine installed"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  _write_build_manifest  — record this build in buildz/builds.log
# ══════════════════════════════════════════════════════════════════════════════
_write_build_manifest() {
    local install_prefix="$1"
    local elapsed_fmt="$2"
    local manifest="${DEST_ROOT}/builds.log"
    mkdir -p "${DEST_ROOT}"
    {
        printf '%-25s  source=%-30s  profile=%-14s  mode=%-7s  elapsed=%s  date=%s\n' \
            "$(basename "$install_prefix")" \
            "${WINE_SOURCE_KEY}" \
            "${PROFILE_NAME:--}" \
            "${NEUTRON_BUILD_MODE:-?}" \
            "$elapsed_fmt" \
            "$(date '+%Y-%m-%d %H:%M:%S')"
    } >> "$manifest"
}

# ══════════════════════════════════════════════════════════════════════════════
#  print_summary
# ══════════════════════════════════════════════════════════════════════════════
print_summary() {
    local install_prefix="$1"
    local elapsed_fmt="$2"

    section "Build Summary"
    ok "Build complete in ${elapsed_fmt}"
    printf "\n"
    printf "  ${C_B}Neutron name :${C_R} %s\n" "$(basename "$install_prefix")"
    printf "  ${C_B}Install path :${C_R} %s\n" "$install_prefix"
    [ -n "${PROFILE_NAME:-}" ] && \
        printf "  ${C_B}Profile      :${C_R} %s  (%s pipeline)\n" "$PROFILE_NAME" "${PROFILE_PIPELINE:-?}"
    printf "  ${C_B}Build mode   :${C_R} %s\n" "${NEUTRON_BUILD_MODE:-?}"

    local wine_bin="${install_prefix}/files/bin/wine"
    if [ -x "$wine_bin" ]; then
        local wine_ver
        wine_ver="$("$wine_bin" --version 2>/dev/null || printf 'unknown')"
        printf "  ${C_B}Wine version :${C_R} %s\n" "$wine_ver"
    fi

    # Component status — check actual DLL presence, not just source key
    printf "\n  ${C_B}Component status:${C_R}\n"
    if [ "$WINE_SOURCE_KEY" = "ge-proton" ]; then
        printf "    ${C_GRN}✓${C_R}  GE-Proton     — proton-wine + GloriousEggroll patches\n"
    else
        printf "    ${C_GRN}✓${C_R}  proton-wine   — built and installed\n"
    fi
    if [ "${DXVK_SOURCE_KEY}" = "none" ]; then
        printf "    ${C_DIM}-${C_R}  DXVK          — skipped (--dxvk none)\n"
    elif [ -n "$(find "${install_prefix}/files/lib/wine/dxvk" -name '*.dll' 2>/dev/null | head -1)" ]; then
        printf "    ${C_GRN}✓${C_R}  DXVK          — installed (${DXVK_SOURCE_KEY})\n"
    else
        printf "    ${C_YLW}◌${C_R}  DXVK          — will compile from source\n"
    fi
    if [ "${VKD3D_SOURCE_KEY}" = "none" ]; then
        printf "    ${C_DIM}-${C_R}  VKD3D-Proton  — skipped (--vkd3d none)\n"
    elif [ -n "$(find "${install_prefix}/files/lib/wine/vkd3d-proton" -name '*.dll' 2>/dev/null | head -1)" ]; then
        printf "    ${C_GRN}✓${C_R}  VKD3D-Proton  — installed (${VKD3D_SOURCE_KEY})\n"
    else
        printf "    ${C_YLW}◌${C_R}  VKD3D-Proton  — will compile from source\n"
    fi
    if [ "${SNIPER_MODE}" = "true" ]; then
        printf "    ${C_GRN}✓${C_R}  Sniper mode   — Steam Runtime 3.0 container isolation enabled\n"
    else
        printf "    ${C_DIM}-${C_R}  Sniper mode   — disabled (standard host mode)\n"
    fi
    if [ -s "${BUILD_RUN_DIR:-/dev/null}/neutron-patch.manifest" ]; then
        local _pcount _pgroups
        _pcount="$(grep -c 'result=applied' "${BUILD_RUN_DIR}/neutron-patch.manifest" || true)"
        _pgroups="$(cut -d= -f1 "${BUILD_RUN_DIR}/neutron-patch.manifest" | sort -u | paste -sd, -)"
        printf "    ${C_GRN}✓${C_R}  Patches       — %s applied (%s)\n" "${_pcount:-0}" "$_pgroups"
    elif [ -n "${PATCH_GROUPS:-}" ] && [ "$PATCH_GROUPS" != "none" ]; then
        printf "    ${C_GRN}✓${C_R}  Patches       — groups: ${PATCH_GROUPS}\n"
    fi

    printf "\n  ${C_B}To use with Steam:${C_R}\n"
    printf "    cp -r %s\n" "$install_prefix"
    printf "       ~/.steam/steam/compatibilitytools.d/\n"
    printf "    Then restart Steam and enable in game Properties → Compatibility.\n"
    printf "\n"
}

