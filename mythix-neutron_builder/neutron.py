#!/usr/bin/env python3
# _____________________________________________________________________________
# |-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-***_Neutron_***-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|
# |//////////////////////////////////#########\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\|
# |___________________________________________________________________________|
# |-|-|-|-|-|-|-|-|-|-|-|-|-|-***_Python_launcher_***-|-|-|-|-|-|-|-|-|-|-|-|-|
# |//////////////////////////////#################\\\\\\\\\\\\\\\\\\\\\\\\\\\\|
# |___________________________________________________________________________|
#
# Speaks the standard Steam compat-tool verb interface:
#
#     run | waitforexitandrun | runinprefix | getcompatpath | getnativepath
#
# plus helper verbs:
#
#     createprefix | destroyprefix | makedefaultpfx | stop | diag
#
# Incorporates engine improvements adapted (re-implemented, not copied) from
# Valve Proton 11 — see mythix-build NOTICE for attribution:
#   - default prefix template (files/share/default_pfx): boot Wine once, then
#     clone new prefixes from it via symlinks + reflink copies
#   - prefix version file + upgrade_pfx: logged upgrades, downgrade recovery
#   - reflink (copy_file_range) DLL copies — fast, space-saving prefix setup
#   - config-info hashing — re-overlay only when the build or inputs change
#   - tracked-files manifest + `destroyprefix` for clean uninstalls
#   - file-locking so concurrent Steam launches don't race the prefix
#   - wine-builtin-DLL detection — overlays don't clobber user-native DLLs
#   - per-prefix MachineGuid regeneration when cloning the template
#   - NVIDIA nvngx/DLSS DLL discovery + NVIDIA_WINE_DLL_DIR
#   - OpenVR openvrpaths.vrpath rewriting into the prefix
#   (Neutron's own) foreign-tool sweep: DLL symlinks a Proton/GE run leaves
#   in system32/syswow64, plus its vrclient when this build has none, are
#   quarantined to <compatdata>/foreign-quarantine every launch
#   - game / Steam-library DOS drives (s: / t:)
#   - WoW64 mode toggle, user_settings.py overrides, an extensible
#     compat_config framework, and NEUTRON_LOG logging + health warnings
#
# Bundled DXVK / VKD3D-Proton DLLs under files/lib/wine are installed into
# prefixes by the tracked runtime overlay.  `wined3d` disables DXVK injection;
# VKD3D-Proton remains available for D3D12.
#
# Per-build curation: BUILD_PROFILES (keyed by the version-file tag, or
# NEUTRON_PROFILE) records what each Wine build needs — like Valve shipping a
# proton script per Proton version. Bundled DXVK/VKD3D-Proton DLLs are PE-
# validated before overlay; `diag` reports their health and the active profile.
#
# Control knobs are NEUTRON_* (the proton bundle reads PROTON_* via rebrand).

import array
import collections
import errno
import fcntl
import filecmp
import fnmatch
import json
import os
import re
import resource
import shutil
import stat
import subprocess
import sys
import traceback
import uuid


def debug(stage, **kwargs):
    if os.getenv("NEUTRON_DEBUG", "0") != "1":
        return

    print(f"[NEUTRON] {stage}")

    for k, v in kwargs.items():
        print(f"    {k}: {v}")


from ctypes import (CDLL, POINTER, Structure, addressof, c_char_p, c_int,
                    c_void_p, cast)

# ── Logging ─────────────────────────────────────────────────────────────────
def log(msg):
    print(f"neutron: {msg}", file=sys.stderr)


def die(msg):
    print(f"neutron: ERROR: {msg}", file=sys.stderr)
    # GUI error reporting
    try:
        if shutil.which("zenity"):
            subprocess.run(["zenity", "--error", "--text", msg])
        elif shutil.which("kdialog"):
            subprocess.run(["kdialog", "--error", "--msgbox", msg])
    except Exception:
        pass
    sys.exit(1)


# ── Prefix schema version (brand-neutral so both bundles share prefixes) ─────
# Format: <tag>-<MAJ.MIN>-<revision>, brand-neutral so both bundles share
# prefixes. upgrade_pfx() parses it; bump REV to force a DLL re-overlay,
# bump MAJ.MIN for schema changes. rev 2: DXVK/VKD3D no longer bundled.
# Downgrade detection only applies within the same <tag> — prefixes from a
# different scheme (e.g. old "tkg-neutron-11.11") upgrade non-destructively.
#
# The live value is adopted from the bundle's version file (Proton format:
# "<build timestamp> <version>", last token wins) via load_prefix_version()
# so mythix-build stamps it at package time and the script never drifts.
# This constant is only the fallback for missing/unparseable version files.
FALLBACK_PREFIX_VERSION = "mythix-neutron-0.0"
CURRENT_PREFIX_VERSION = FALLBACK_PREFIX_VERSION
PREFIX_VERSION_SOURCE = "fallback"

# Accepts "<tag>-MAJ.MIN[-REV]" and the builder's git-describe form
# "<tag>-MAJ.MIN.r<REV>.g<hash>" (e.g. Mythix-Neutron-10.17.r0.gf686957b).
_PREFIX_VERSION_RE = re.compile(
    r"^\s*(.*?)-?(\d+)\.(\d+)(?:-(\d+)|\.r(\d+))?(?:\.g[0-9a-f]+)?\s*$")


def parse_prefix_version(ver):
    """-> (tag, major, minor, revision) or None when unparseable."""
    if not ver:
        return None
    m = _PREFIX_VERSION_RE.match(ver)
    if not m:
        return None
    return (m.group(1), int(m.group(2)), int(m.group(3)),
            int(m.group(4) or m.group(5) or 0))


def load_prefix_version(version_file):
    """Adopt the prefix schema version from the bundle's version file, like
    Proton reads its own. Missing file -> keep the fallback (dev checkouts);
    unparseable content -> warn and keep the fallback."""
    global CURRENT_PREFIX_VERSION, PREFIX_VERSION_SOURCE
    try:
        with open(version_file) as f:
            tokens = f.readline().split()
    except OSError:
        return
    if tokens and parse_prefix_version(tokens[-1]):
        CURRENT_PREFIX_VERSION = tokens[-1]
        PREFIX_VERSION_SOURCE = "version file"
    else:
        log(f"warning: unparseable version file ({version_file}); "
            f"using fallback prefix schema {CURRENT_PREFIX_VERSION}")


def load_build_info(path):
    """KEY=VALUE facts the builder writes next to the version file
    (BUILD_MODE, PROFILE, WAYLAND, ...). Missing file -> {}."""
    info = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                info[key.strip()] = value.strip()
    except OSError:
        pass
    return info


# ── Build profiles — per-Wine-build curation, like Valve's per-version proton ─
# Selected from the version tag (case-insensitive prefix match); NEUTRON_PROFILE
# overrides. Keep facts about a build here rather than scattering if/elses.
BUILD_PROFILES = {
    # Mythix Neutron 10.x: Valve bleeding-edge proton-wine + staging/TkG/GE,
    # classic multilib (has wine64), esync/fsync only (no ntsync yet).
    "mythix-neutron-10": dict(
        description="Mythix Neutron 10.x (proton-wine bleeding-edge base)",
        wine_tree="proton",
        ntsync=False,               # build targets e/fsync; never opt into ntsync
        d3d_override="n",           # DXVK/VKD3D native-only, exactly like Proton
        proton_env=True,            # proton-wine reads PROTON_* + WINE_* knobs
        env_defaults={
            "WINE_LARGE_ADDRESS_AWARE": "1",
            "WINE_GST_REGISTRY_DIR": "",   # filled per-prefix in init_session
        },
    ),
    # Mythix Neutron 11.x: Valve bleeding-edge + GE (incl. GE's Wayland work)
    # + TkG + Mythix patches. 11.11 is a classic multilib build, 11.19+ the
    # WoW64 (Proton) layout; build-info BUILD_MODE says which. Valve's tree
    # carries ntsync alongside esync/fsync; the launcher still checks the
    # build + kernel.
    "mythix-neutron-11": dict(
        description="Mythix Neutron 11.x (Valve bleeding-edge + GE + TkG)",
        wine_tree="proton",
        ntsync=True,
        d3d_override="n",
        proton_env=True,
        env_defaults={
            "WINE_LARGE_ADDRESS_AWARE": "1",
            "WINE_GST_REGISTRY_DIR": "",   # filled per-prefix in init_session
        },
    ),
    # Anything else (upstream / tkg / kron4ek style unified builds)
    "generic": dict(
        description="generic Wine build",
        wine_tree="upstream",
        ntsync=True,
        d3d_override="n,b",
        proton_env=False,
        env_defaults={},
    ),
}
ACTIVE_PROFILE = "generic"


def select_build_profile(version_string):
    """Pick the profile whose key prefixes the version tag (longest wins)."""
    global ACTIVE_PROFILE
    forced = os.environ.get("NEUTRON_PROFILE")
    if forced in BUILD_PROFILES:
        ACTIVE_PROFILE = forced
        return
    parsed = parse_prefix_version(version_string)
    if parsed:
        ident = f"{parsed[0]}-{parsed[1]}.{parsed[2]}".lower()
    else:
        ident = (version_string or "").lower()
    best = ""
    for key in BUILD_PROFILES:
        if key == "generic" or len(key) <= len(best):
            continue
        if ident == key or (ident.startswith(key)
                            and ident[len(key)] in ".-"):
            best = key
    ACTIVE_PROFILE = best or "generic"


def profile():
    return BUILD_PROFILES[ACTIVE_PROFILE]


# Symlink-target directories that mark a prefix DLL as a Wine builtin.
# lib64 variants are legacy-only: current builds ship a unified files/lib,
# but old prefixes/templates may still contain lib64-targeted links.
WINE_BUILTIN_LINK_DIRS = (
    "/lib/wine/i386-windows", "/lib/wine/x86_64-windows",
    "/lib/wine/i386-unix", "/lib/wine/x86_64-unix",
    "/lib/wine",
    "/lib64/wine/x86_64-windows", "/lib64/wine/x86_64-unix",
    "/lib64/wine",
)

# ── ext4 casefold ioctl constants ───────────────────────────────────────────
EXT2_IOC_GETFLAGS = 0x80086601
EXT2_IOC_SETFLAGS = 0x40086602
EXT4_CASEFOLD_FL = 0x40000000

# ── DLLs physically copied into the prefix (overridable via NEUTRON_DLL_COPY) ─
DEFAULT_BUILTIN_DLL_PATTERNS = [
    # DirectX redist
    "d3dcompiler_*.dll", "d3dcsx*.dll", "d3dx*.dll", "dx8vb.dll",
    "x3daudio*.dll", "xactengine*.dll", "xapofx*.dll", "xaudio*.dll",
    "xinput*.dll",
    # VC runtime redist
    "atl1*.dll", "atl.dll", "concrt*.dll", "msvcp1*.dll", "msvcrt*.dll",
    "msvcp7*.dll", "msvcp6*.dll", "msvcp_win.dll", "msvcr1*.dll",
    "msvcr7*.dll", "vcamp1*.dll", "vcomp1*.dll", "vccorlib1*.dll",
    "vcruntime1*.dll", "ucrtbase.dll",
    # comctl32 ships in two flavours; keep a real copy
    "comctl32.dll",
    # some games balk at an ntdll symlink
    "ntdll.dll",
    # some games require the official Vulkan loader
    "vulkan-1.dll",
]


# ── Small environment / path helpers ────────────────────────────────────────
def prepend_to_env(env, var, value, sep):
    env[var] = value if var not in env or not env[var] else value + sep + env[var]


def append_to_env(env, var, value, sep):
    env[var] = value if var not in env or not env[var] else env[var] + sep + value


def nonzero(s):
    return len(s) > 0 and s != "0"


def in_container():
    """True when running inside a pressure-vessel container (SteamLinuxRuntime)."""
    return (os.environ.get("PRESSURE_VESSEL_RUNTIME") is not None
            or os.path.isfile("/.flatpak-info"))


def find_slr():
    """Find a Steam Linux Runtime installation for container self-wrapping.
    Returns (slr_dir, label) or (None, None)."""
    steam_common = None
    for base in (os.path.expanduser("~/.steam/debian-installation"),
                 os.path.expanduser("~/.steam/steam"),
                 os.path.expanduser("~/.local/share/Steam")):
        candidate = os.path.join(base, "steamapps", "common")
        if os.path.isdir(candidate):
            steam_common = candidate
            break
    if not steam_common:
        return None, None

    preference = os.environ.get("NEUTRON_CONTAINER", "auto")
    if preference == "none":
        return None, None

    candidates = []
    if preference in ("auto", "slr4", "4"):
        d = os.path.join(steam_common, "SteamLinuxRuntime_4")
        if os.path.isfile(os.path.join(d, "run")):
            candidates.append((d, "SLR 4.0"))
    if preference in ("auto", "sniper", "3"):
        d = os.path.join(steam_common, "SteamLinuxRuntime_sniper")
        if os.path.isfile(os.path.join(d, "run")):
            candidates.append((d, "Sniper (SLR 3.0)"))
    if preference in ("auto", "soldier", "2"):
        d = os.path.join(steam_common, "SteamLinuxRuntime_soldier")
        if os.path.isfile(os.path.join(d, "run")):
            candidates.append((d, "Soldier (SLR 2.0)"))

    if preference not in ("auto", "none") and not candidates:
        for name, label in (("SteamLinuxRuntime_4", "SLR 4.0"),
                            ("SteamLinuxRuntime_sniper", "Sniper (SLR 3.0)")):
            d = os.path.join(steam_common, name)
            if os.path.isfile(os.path.join(d, "run")):
                candidates.append((d, label))
                break

    return candidates[0] if candidates else (None, None)


def container_self_wrap():
    """Re-exec neutron inside a pressure-vessel container. Called once from
    main() when we detect we're outside a container. Uses the SLR 'run'
    script which handles all the pressure-vessel setup."""
    if os.environ.get("NEUTRON_NO_CONTAINER") == "1":
        return False

    slr_dir, label = find_slr()
    if not slr_dir:
        return False

    run_script = os.path.join(slr_dir, "run")
    log(f"self-wrapping through {label} container ({slr_dir})")

    script_path = os.path.realpath(__file__)
    cmd = [run_script, "--", sys.executable, script_path] + sys.argv[1:]
    os.execv(run_script, cmd)


def steam_client_running():
    """True when the Linux Steam client is up: its pid file names a live
    `steam` process. Inside a container that hides host PIDs this is False,
    which keeps launches on the direct path."""
    home = os.environ.get("HOME", "")
    for pid_file in (os.path.join(home, ".steam", "steam.pid"),
                     os.path.join(home, ".steampid")):
        try:
            with open(pid_file) as f:
                pid = int(f.read().strip() or "0")
            with open(f"/proc/{pid}/comm") as f:
                comm = f.read().strip()
        except (OSError, ValueError):
            continue
        if pid > 0 and comm.startswith("steam"):
            return True
    return False


def file_exists(path, *, follow_symlinks):
    # os.path.exists() is False on broken symlinks; lexists() is True.
    return os.path.exists(path) if follow_symlinks else os.path.lexists(path)


def mtime_str(*fragments):
    try:
        return str(os.path.getmtime(os.path.join(*fragments)))
    except OSError:
        return "0"


def dir_sig(d):
    """Signature of a directory's contents = newest file mtime within it.
    Unlike the directory's own mtime, this changes when a DLL is overwritten
    in place, so dropping in an updated Wine build triggers a re-overlay."""
    try:
        latest = 0.0
        with os.scandir(d) as it:
            for entry in it:
                try:
                    latest = max(latest, entry.stat().st_mtime)
                except OSError:
                    pass
        return str(latest)
    except OSError:
        return "0"


def makedirs(path):
    try:
        # replace a broken symlink with a real directory
        if os.path.islink(path) and not file_exists(path, follow_symlinks=True):
            os.remove(path)
        os.makedirs(path, exist_ok=True)
    except OSError:
        pass


# ── Reflink-capable copy (CoW on btrfs/XFS, graceful fallback elsewhere) ─────
def _copy_data(src, dst):
    try:
        with open(src, "rb") as s, open(dst, "wb") as d:
            remaining = os.fstat(s.fileno()).st_size
            while remaining > 0:
                copied = os.copy_file_range(s.fileno(), d.fileno(), remaining)
                if copied == 0:
                    break
                remaining -= copied
    except (AttributeError, OSError) as e:
        # EXDEV (cross-fs), ENOSYS/EOPNOTSUPP (unsupported), or no copy_file_range
        if isinstance(e, OSError) and e.errno not in (
                errno.EXDEV, errno.ENOSYS, errno.EOPNOTSUPP, errno.EINVAL):
            raise
        shutil.copyfile(src, dst)


def try_copy(src, dst, *, prefix=None, track_file=None, optional=False):
    """Copy src→dst (reflink when possible), recording new files in track_file.
    A relative dst is resolved against prefix; tracking is stored relative to
    prefix when given, else as the absolute path."""
    try:
        if prefix is not None and not os.path.isabs(dst):
            dst = os.path.join(prefix, dst)
        if os.path.isdir(dst):
            dst = os.path.join(dst, os.path.basename(src))

        is_new = not file_exists(dst, follow_symlinks=False)
        if not is_new:
            os.remove(dst)
        elif track_file is not None:
            rel = os.path.relpath(dst, prefix) if prefix is not None else dst
            track_file.write(rel + "\n")

        _copy_data(src, dst)
        try:
            shutil.copystat(src, dst)
        except OSError:
            pass
        try:  # ensure the copy is writable so future overlays can replace it
            os.chmod(dst, os.lstat(dst).st_mode | stat.S_IWUSR | stat.S_IWGRP)
        except OSError:
            pass
    except FileNotFoundError:
        if not optional:
            raise
    except PermissionError as e:
        if e.errno != errno.EPERM:
            raise
        log(f'permission error copying to "{dst}": {e.strerror}')


# ── Detect Wine's own builtin/placeholder DLLs so overlays don't clobber ─────
# user-installed native DLLs (reads the PE tag Wine stamps at offset 0x40).
def file_is_wine_builtin_dll(path):
    if os.path.islink(path):
        target = os.readlink(path)
        if os.path.dirname(target).endswith(WINE_BUILTIN_LINK_DIRS):
            return True
    if not file_exists(path, follow_symlinks=True):
        return False
    try:
        with open(path, "rb") as f:
            f.seek(0x40)
            tag = f.read(20)
        return tag.startswith((b"Wine placeholder DLL", b"Wine builtin DLL"))
    except OSError:
        return False


# ── PE header probe: catches corrupt/mismatched bundled DLLs before they're
#    overlaid into a prefix (a bad d3d11/dxgi kills every DX game at launch) ──
PE_MACHINE = {0x14c: "x86", 0x8664: "x64", 0xaa64: "arm64"}


def pe_info(path):
    """-> dict(ok, machine, size, error) for a PE file."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if f.read(2) != b"MZ":
                return dict(ok=False, machine=None, size=size,
                            error="not a PE file (no MZ header)")
            f.seek(0x3c)
            e_lfanew = int.from_bytes(f.read(4), "little")
            if e_lfanew <= 0 or e_lfanew + 6 > size:
                return dict(ok=False, machine=None, size=size,
                            error="truncated (bad e_lfanew)")
            f.seek(e_lfanew)
            if f.read(4) != b"PE\0\0":
                return dict(ok=False, machine=None, size=size,
                            error="missing PE signature")
            coff = f.read(20)
            machine = int.from_bytes(coff[0:2], "little")
            nsections = int.from_bytes(coff[2:4], "little")
            opt_size = int.from_bytes(coff[16:18], "little")
            # body truncation: every section's raw data must fit in the file
            f.seek(e_lfanew + 24 + opt_size)
            end = 0
            for _ in range(nsections):
                sec = f.read(40)
                if len(sec) < 40:
                    return dict(ok=False, machine=None, size=size,
                                error="truncated (section table)")
                raw_size = int.from_bytes(sec[16:20], "little")
                raw_ptr = int.from_bytes(sec[20:24], "little")
                end = max(end, raw_ptr + raw_size)
            if end > size:
                return dict(ok=False, machine=None, size=size,
                            error=f"truncated ({size} of {end} bytes)")
        return dict(ok=True, machine=PE_MACHINE.get(machine, hex(machine)),
                    size=size, error=None)
    except OSError as e:
        return dict(ok=False, machine=None, size=0, error=str(e))


def check_translation_dll(path, expect_machine):
    """None when the DLL is sane for its directory, else a reason string."""
    info = pe_info(path)
    if not info["ok"]:
        return info["error"]
    if info["machine"] != expect_machine:
        return f"wrong architecture ({info['machine']}, expected {expect_machine})"
    if info["size"] < 65536:
        return f"implausibly small ({info['size']} bytes)"
    if file_is_wine_builtin_dll(path):
        return "is a Wine builtin/placeholder, not a translation DLL"
    return None


# ── Minimal advisory file lock (no third-party dependency) ───────────────────
class FileLock:
    def __init__(self, path):
        self.path = path
        self._fd = None

    def __enter__(self):
        makedirs(os.path.dirname(self.path))
        self._fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(self._fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        try:
            fcntl.flock(self._fd, fcntl.LOCK_UN)
        finally:
            os.close(self._fd)
            self._fd = None


# ── Locate the NVIDIA driver's bundled Wine DLLs (nvngx for DLSS, etc.) ──────
# Mirrors the steam-runtime-tools discovery method: dlinfo() on the loaded
# libGLX_nvidia, then ./nvidia/wine relative to it.
def find_nvidia_wine_dll_dir():
    try:
        libdl = CDLL("libdl.so.2")
        libglx = CDLL("libGLX_nvidia.so.0")
    except OSError:
        return None

    RTLD_DI_LINKMAP = 2

    class _LinkMap(Structure):
        _fields_ = [("l_addr", c_void_p), ("l_name", c_char_p),
                    ("l_ld", c_void_p)]

    dlinfo = libdl.dlinfo
    dlinfo.argtypes = (c_void_p, c_int, c_void_p)
    dlinfo.restype = c_int

    info_ptr = POINTER(_LinkMap)()
    if dlinfo(libglx._handle, RTLD_DI_LINKMAP, addressof(info_ptr)) != 0:
        return None
    info = cast(info_ptr, POINTER(_LinkMap)).contents
    if not info.l_name:
        return None
    try:
        lib_path = os.fsdecode(info.l_name)
    except UnicodeDecodeError:
        return None

    nvidia_wine = os.path.join(os.path.dirname(os.path.realpath(lib_path)),
                               "nvidia", "wine")
    if file_exists(os.path.join(nvidia_wine, "nvngx.dll"), follow_symlinks=True):
        return nvidia_wine
    return None


# ── Bundled translation layers ───────────────────────────────────────────────
# The one place that says which DLLs each layer ships and where. The overlay,
# the wined3d restore, the DLL overrides, config_info and diag all read it;
# they used to keep their own copies of these lists, which is how a missing
# comma once glued "dxgi.dll" onto its neighbour in just one of them.
TranslationLayer = collections.namedtuple(
    "TranslationLayer", "name dir subdirs dlls wined3d_off")

TRANSLATION_LAYERS = (
    # older DXVK drops use x64/x32, newer ones Wine's arch dir names
    TranslationLayer(
        name="DXVK", dir="dxvk",
        subdirs={"x64": ("x64", "x86_64-windows"), "x86": ("x32", "i386-windows")},
        dlls=("d3d8", "d3d9", "d3d10core", "d3d11", "dxgi", "openvr_api_dxvk"),
        wined3d_off=True),
    # VKD3D-Proton owns the D3D12 pair independently of DXVK/WineD3D
    TranslationLayer(
        name="VKD3D-Proton", dir="vkd3d-proton",
        subdirs={"x64": ("x86_64-windows",), "x86": ("i386-windows",)},
        dlls=("d3d12", "d3d12core"),
        wined3d_off=False),
)

# Where each arch's DLLs land in a prefix (WoW64 layout)
PREFIX_ARCH_DIRS = (("x64", "drive_c/windows/system32"),
                    ("x86", "drive_c/windows/syswow64"))


# ── The Neutron distribution (Wine build + helpers) ─────────────
class Neutron:
    """Resolves paths into the bundled `files/` tree and installs DLLs."""

    def __init__(self, neutron_dir):
        self.dir = neutron_dir
        self.files_dir = os.path.join(neutron_dir, "files")
        self.bin_dir = os.path.join(self.files_dir, "bin")
        self.lib_dir = os.path.join(self.files_dir, "lib")
        self.share_dir = os.path.join(self.files_dir, "share")

        # Wine binaries
        self.wine = os.path.join(self.bin_dir, "wine")
        self.wine64 = os.path.join(self.bin_dir, "wine64")
        self.wineserver = os.path.join(self.bin_dir, "wineserver")
        self.wineboot = os.path.join(self.bin_dir, "wineboot")

        # Builtin PE DLL directories (Wine's own PE-format DLLs)
        self.pe_system32 = os.path.join(self.lib_dir, "wine", "x86_64-windows")
        self.pe_syswow64 = os.path.join(self.lib_dir, "wine", "i386-windows")

        # Bundled Direct3D translation layers.  These live alongside Wine but
        # are native Windows DLLs that must be overlaid into each prefix.
        self.dxvk_dir = os.path.join(self.lib_dir, "wine", "dxvk")
        self.vkd3d_dir = os.path.join(self.lib_dir, "wine", "vkd3d-proton")

        # Prefix template cloned into every new compatdata prefix
        self.default_pfx_dir = os.path.join(self.share_dir, "default_pfx")

        self.version_file = os.path.join(neutron_dir, "version")
        self.unix_dir = os.path.join(self.lib_dir, "wine", "x86_64-unix")
        # Facts from the builder (build mode, profile, Wayland default, ...)
        self.build_info = load_build_info(os.path.join(neutron_dir, "build-info"))
        self.dxvk_conf = os.path.join(self.files_dir, "dxvk.conf")
        self.wine_inf = os.path.join(self.share_dir, "wine", "wine.inf")

        # Serializes template creation across concurrent launches
        self.dist_lock = FileLock(os.path.join(neutron_dir, "dist.lock"))

    # — what this build's xinput understands (read from the DLL itself, so a
    #   hand-swapped xinput is reported as what it is) —
    def xinput_features(self):
        if getattr(self, "_xinput_features", None) is None:
            data = b""
            try:
                with open(os.path.join(self.pe_system32, "xinput1_3.dll"), "rb") as f:
                    data = f.read()
            except OSError:
                pass
            self._xinput_features = {
                "sony_auto": b"PROTON_SONY_AUTO_XINPUT" in data,   # GE Sony stack
                "glyphs": b"MYTHIX_DS4_GLYPHS" in data,            # Mythix native mode
            }
        return self._xinput_features

    # — tool version (first line of the bundle's version file) —
    def tool_version(self):
        try:
            with open(self.version_file) as f:
                return f.readline().strip() or "(empty)"
        except OSError:
            return "(unknown)"

    # — binary resolution —
    def has_wine(self):
        return os.path.isfile(self.wine)

    def runner(self):
        """Prefer wine64 when present, else wine."""
        has_wine64 = os.path.isfile(self.wine64)
        debug(
            "Runner resolution",
            wine=self.wine,
            wine64=self.wine64 if has_wine64 else None,
            wineserver=self.wineserver,
            unified_wine_build=not has_wine64,
            wine64_absent_reason=("unified Wine build" if not has_wine64 else None),
        )
        return self.wine64 if has_wine64 else self.wine

    def loader(self):
        return self.wine64 if os.path.isfile(self.wine64) else self.wine

    # — default prefix template (files/share/default_pfx) —
    _DEFAULT_PFX_STAMP = ".mythix-neutron-template"

    def _default_prefix_valid(self, path=None, require_stamp=True):
        """A usable template has complete registry/drive state and, for newly
        generated templates, an identity stamp written only after wineboot."""
        path = path or self.default_pfx_dir
        required = ("system.reg", "user.reg", "userdef.reg", "drive_c",
                    "dosdevices")
        if not all(os.path.exists(os.path.join(path, entry))
                   for entry in required):
            return False
        if require_stamp:
            stamp = os.path.join(path, self._DEFAULT_PFX_STAMP)
            try:
                with open(stamp, "r") as f:
                    return f.readline().strip() == CURRENT_PREFIX_VERSION
            except OSError:
                return False
        return True

    def layer_dir(self, layer, arch):
        """A translation layer's bundled DLL dir for "x64"/"x86", or None."""
        for sub in layer.subdirs[arch]:
            d = os.path.join(self.lib_dir, "wine", layer.dir, sub)
            if os.path.isdir(d):
                return d
        return None

    def layer_dlls(self, layer, arch):
        """(name, path) of each manifest DLL this build ships for arch."""
        d = self.layer_dir(layer, arch)
        if not d:
            return []
        return [(dll, os.path.join(d, dll + ".dll")) for dll in layer.dlls
                if os.path.isfile(os.path.join(d, dll + ".dll"))]

    def has_vrclient(self):
        """True when this build ships its own vrclient (PE and unix halves).
        Without it, any vrclient in a prefix came from another compat tool and
        crashes against our Wine; NEUTRON_FORCE_VR=1 trusts it anyway."""
        if os.environ.get("NEUTRON_FORCE_VR") == "1":
            return True
        return os.path.isfile(os.path.join(self.pe_system32, "vrclient_x64.dll")) \
            and os.path.isfile(os.path.join(self.unix_dir, "vrclient.so"))

    def missing_default_prefix(self):
        """True when no structurally complete template exists."""
        # Accept a shipped legacy template without the new completion stamp;
        # the next regeneration will convert it to the stronger format.
        return not self._default_prefix_valid(require_stamp=False)

    def default_prefix_stale(self):
        """True when the template predates this launcher/build state."""
        if self.missing_default_prefix():
            return False
        # A legacy shipped template is usable but should be regenerated once so
        # future launches have positive proof that Neutron created it.
        if not self._default_prefix_valid():
            return True
        reg_mtime = mtime_str(self.default_pfx_dir, "system.reg")
        build_sigs = (mtime_str(self.wine_inf),
                      dir_sig(self.pe_system32), dir_sig(self.pe_syswow64))
        try:
            return float(reg_mtime) < max(float(s) for s in build_sigs)
        except ValueError:
            return False

    # Template diet: wineboot leaves a full copy of every builtin in the
    # template, and every clone duplicated them (~500 MB per prefix on ext4).
    # Byte-identical builtins become relative symlinks into lib/wine, as in
    # Proton's template; _pfx_copy re-points them when cloning and the
    # overlay already treats lib/wine links as builtins.
    _BUILTINS_LINKED = ".builtins-linked"

    def _link_template_builtins(self, pfx):
        linked = 0
        for sub, lib in (("system32", self.pe_system32),
                         ("syswow64", self.pe_syswow64)):
            root = os.path.join(pfx, "drive_c", "windows", sub)
            for dirpath, _, files in os.walk(root):
                for name in files:
                    path = os.path.join(dirpath, name)
                    src = os.path.join(lib, name)
                    if os.path.islink(path) or not os.path.isfile(src):
                        continue
                    try:
                        if not filecmp.cmp(path, src, shallow=False):
                            continue
                        # atomic swap: a concurrent clone never sees a gap
                        tmp = path + ".link-tmp"
                        os.symlink(os.path.relpath(src, dirpath), tmp)
                        os.replace(tmp, path)
                        linked += 1
                    except OSError:
                        pass
        with open(os.path.join(pfx, self._BUILTINS_LINKED), "w") as f:
            f.write(f"{linked}\n")
        return linked

    def make_default_prefix(self, base_env, force=False):
        """Create the clone template transactionally with Mythix Wine.
        A failed wineboot never replaces an existing known-good template."""
        with self.dist_lock:
            stale = self.default_prefix_stale()
            if not force and not stale and not self.missing_default_prefix():
                # a template from before the diet slims down once, in place
                if not os.path.exists(os.path.join(self.default_pfx_dir,
                                                   self._BUILTINS_LINKED)):
                    log("linking default prefix template builtins...")
                    n = self._link_template_builtins(self.default_pfx_dir)
                    log(f"linked {n} template builtins into lib/wine")
                return
            if force or stale:
                log("regenerating default prefix template"
                    + ("" if force else " (wine build changed)") + "...")

            parent = os.path.dirname(self.default_pfx_dir)
            makedirs(parent)
            temp = self.default_pfx_dir + f".new-{os.getpid()}-{uuid.uuid4().hex}"
            backup = self.default_pfx_dir + ".previous"
            shutil.rmtree(temp, ignore_errors=True)
            try:
                # Strip vars that can interfere with wineboot during
                # prefix template creation.
                env = dict(base_env)
                for key in (
                    "WINEDLLPATH", "WINEDLLOVERRIDES", "WINEARCH",
                    "LD_PRELOAD", "DXVK_CONFIG_FILE", "DXVK_LOG_LEVEL",
                    "DXVK_STATE_CACHE", "DXVK_HDR", "DXVK_ASYNC",
                    "DXVK_ENABLE_NVAPI", "VKD3D_CONFIG", "VKD3D_DEBUG",
                ):
                    env.pop(key, None)
                env["WINEPREFIX"] = temp
                env["WINE"] = self.wine
                env["WINE64"] = self.loader()
                env["WINELOADER"] = self.loader()
                env["WINEBOOT"] = self.wineboot
                env["WINESERVER"] = self.wineserver
                env["PATH"] = self.bin_dir + ":" + os.environ.get("PATH", "")
                # Our libs first, then whatever we inherited: inside a Steam
                # Linux Runtime container that's pressure-vessel's paths plus
                # host libraries the launcher bridged in (Mythix Launcher's
                # MYTHIX_RUNTIME_LIBRARY_PATH) — without them wineboot can't
                # load ntdll.so there and template creation dies.
                env["LD_LIBRARY_PATH"] = ":".join(
                    p for p in (self.lib_dir, os.environ.get("LD_LIBRARY_PATH", "")) if p)
                env["WINEDEBUG"] = "-all"
                makedirs(temp)
                log(f"creating default prefix template ({temp})")
                boot = subprocess.run([self.wineboot, "--init"], env=env,
                                      stdout=subprocess.DEVNULL,
                                      stderr=subprocess.PIPE, text=True)
                wait = subprocess.run([self.wineserver, "-w"], env=env,
                                      stdout=subprocess.DEVNULL,
                                      stderr=subprocess.PIPE, text=True)
                if boot.returncode != 0 or wait.returncode != 0 or \
                        not self._default_prefix_valid(temp, require_stamp=False):
                    detail = (boot.stderr or wait.stderr or "").strip()
                    die("Mythix Wine failed to create a complete default prefix"
                        + (f": {detail[-1200:]}" if detail else ""))
                self._link_template_builtins(temp)
                with open(os.path.join(temp, self._DEFAULT_PFX_STAMP), "w") as f:
                    f.write(CURRENT_PREFIX_VERSION + "\n")

                shutil.rmtree(backup, ignore_errors=True)
                if os.path.exists(self.default_pfx_dir):
                    os.rename(self.default_pfx_dir, backup)
                try:
                    os.rename(temp, self.default_pfx_dir)
                except Exception:
                    if os.path.exists(backup) and \
                            not os.path.exists(self.default_pfx_dir):
                        os.rename(backup, self.default_pfx_dir)
                    raise
                shutil.rmtree(backup, ignore_errors=True)
                log("default prefix template ready (Mythix Wine).")
            finally:
                shutil.rmtree(temp, ignore_errors=True)


# ── system.reg MachineGuid helpers ────────────────────────────────────────────
# Every prefix cloned from the template would otherwise share one MachineGuid,
# which some launchers/DRM key machine identity to. Read it before wiping a
# prefix (so a rebuild keeps its identity) and rewrite it after cloning.
_CRYPTO_SECTION = "[Software\\\\Microsoft\\\\Cryptography]"
_MACHINE_GUID_RE = re.compile(r'^"MachineGuid"=(.*)$')


def get_replace_machine_guid(reg_file, replace=None):
    """Return the current MachineGuid value (with its quotes). When `replace`
    is given, rewrite the file with that value. Returns None on any failure."""
    try:
        with open(reg_file, "r") as f:
            lines = f.readlines()
    except OSError:
        return None
    value = None
    in_section = False
    for i, line in enumerate(lines):
        if line.startswith("["):
            in_section = line.startswith(_CRYPTO_SECTION)
            continue
        if not in_section:
            continue
        m = _MACHINE_GUID_RE.match(line.rstrip("\n"))
        if m:
            value = m.group(1)
            if replace is not None:
                lines[i] = f'"MachineGuid"={replace}\n'
                try:
                    with open(reg_file, "w") as f:
                        f.writelines(lines)
                except OSError:
                    return None
            break
    return value


# ── The Steam compatdata directory and its Wine prefix ───────────────────────
class CompatData:
    """Owns the prefix: first-time setup, versioned DLL overlays with a tracked-
    files manifest, drives/VR, and teardown."""

    # Brand-neutral so both bundles share it and prefixes stay interchangeable
    PROTON_MARKER = ".mythix-proton-path"

    # Deprecated builtins that should be cleaned out on upgrade if still builtin
    STALE_BUILTINS = [
        "drive_c/windows/system32/amd_ags_x64.dll",
        "drive_c/windows/syswow64/amd_ags_x64.dll",
        "drive_c/windows/system32/libvkd3d-1.dll",
        "drive_c/windows/syswow64/libvkd3d-1.dll",
        "drive_c/windows/system32/libvkd3d-shader-1.dll",
        "drive_c/windows/syswow64/libvkd3d-shader-1.dll",
    ]

    # Where another compat tool's leftovers are looked for each launch
    FOREIGN_SCAN_DIRS = ("drive_c/windows/system32", "drive_c/windows/syswow64")
    VR_FILES = (
        "drive_c/windows/system32/vrclient_x64.dll",
        "drive_c/windows/syswow64/vrclient.dll",
        "drive_c/vrclient/bin/vrclient_x64.dll",
        "drive_c/vrclient/bin/vrclient.dll",
        "drive_c/users/steamuser/AppData/Local/openvr/openvrpaths.vrpath",
    )

    def __init__(self):
        self.compat_data = os.environ.get("STEAM_COMPAT_DATA_PATH", "")
        if not self.compat_data:
            self.compat_data = os.path.expanduser("~/.wine-neutron-pfx")
            os.environ["STEAM_COMPAT_DATA_PATH"] = self.compat_data
            log(f"STEAM_COMPAT_DATA_PATH not set, defaulting to safe standalone prefix: {self.compat_data}")
        self.prefix = os.path.join(self.compat_data, "pfx")
        self.steam_root = os.environ.get("STEAM_COMPAT_CLIENT_INSTALL_PATH", "")
        self.version_file = os.path.join(self.compat_data, "version")
        self.config_info_file = os.path.join(self.compat_data, "config_info")
        self.tracked_files_file = os.path.join(self.compat_data, "tracked_files")
        # Which translation DLLs Neutron itself placed (rel, size, mtime), so a
        # re-overlay only replaces our own copies and never a user's install.
        self.translation_files_file = os.path.join(self.compat_data,
                                                   "translation_files")
        # Written (fsynced) only after the template clone fully completes, so
        # a half-copied prefix from a crash/power-loss is detected and redone.
        self.creation_sync_guard = os.path.join(self.prefix,
                                                "creation_sync_guard")
        self.lock = FileLock(os.path.join(self.compat_data, "pfx.lock"))
        # Other tools' files pulled out of the prefix, kept at their prefix-
        # relative paths so a move back restores them exactly.
        self.quarantine_dir = os.path.join(self.compat_data, "foreign-quarantine")
        self.old_machine_guid = None

    # — casefold —
    @staticmethod
    def _set_casefold(dir_path):
        try:
            dr = os.open(dir_path, os.O_RDONLY)
        except OSError:
            return
        try:
            dat = array.array('I', [0])
            if fcntl.ioctl(dr, EXT2_IOC_GETFLAGS, dat, True) >= 0:
                dat[0] = dat[0] | EXT4_CASEFOLD_FL
                fcntl.ioctl(dr, EXT2_IOC_SETFLAGS, dat, False)
        except (OSError, IOError):
            pass
        os.close(dr)

    # — Steam client DLLs (tracked) —
    def _install_steam_dlls(self, track_file=None):
        if not self.steam_root:
            return
        steam_dir = "drive_c/Program Files (x86)/Steam/"
        makedirs(os.path.join(self.prefix, steam_dir))
        legacy = os.path.join(self.steam_root, "legacycompat")
        # steamclient{,64}.dll are not part of the overlay: see
        # _ensure_steamclient_dlls (steam.exe launches only).
        copies = [
            ("GameOverlayRenderer64.dll", "GameOverlayRenderer64.dll"),
            ("GameOverlayRenderer.dll", "GameOverlayRenderer.dll"),
            ("SteamService.exe", "steam.exe"),
            ("Steam.dll", "Steam.dll"),
        ]
        for src_name, dst_name in copies:
            src = os.path.join(legacy, src_name)
            if os.path.isfile(src):
                try_copy(src, steam_dir + dst_name, prefix=self.prefix,
                         track_file=track_file)

    # — Steam's own steamclient{,64}.dll, for steam.exe launches —
    def _ensure_steamclient_dlls(self):
        """Valve's ntdll trampolines Steam's steamclient{,64}.dll into
        lsteamclient, so they only work with an lsteamclient built for this
        exact Wine (STEAM_BRIDGE=ge builds). With a mismatched one they crash
        (the old Cyberpunk 2077 access violation). Installed per launch, only
        when the launch goes through steam.exe, and refreshed after Steam
        updates them."""
        if not self.steam_root:
            return
        steam_dir = "drive_c/Program Files (x86)/Steam/"
        legacy = os.path.join(self.steam_root, "legacycompat")
        makedirs(os.path.join(self.prefix, steam_dir))
        with open(self.tracked_files_file, "a") as tf:
            for name in ("steamclient.dll", "steamclient64.dll"):
                src = os.path.join(legacy, name)
                dst = os.path.join(self.prefix, steam_dir, name)
                try:
                    s = os.stat(src)
                except OSError:
                    continue
                try:
                    d = os.stat(dst)
                    if d.st_size == s.st_size and int(d.st_mtime) == int(s.st_mtime):
                        continue
                except OSError:
                    pass
                try_copy(src, steam_dir + name, prefix=self.prefix,
                         track_file=tf)

    # — bundled Direct3D translation layers (tracked) —
    def _read_translation_manifest(self):
        ours = {}
        try:
            with open(self.translation_files_file) as f:
                for line in f:
                    parts = line.rstrip("\n").split("\t")
                    if len(parts) == 3:
                        ours[parts[0]] = (int(parts[1]), int(parts[2]))
        except (OSError, ValueError):
            pass
        return ours

    def _is_our_translation_dll(self, rel, ours):
        """True when the file at rel is byte-for-byte the copy Neutron placed
        (size+mtime recorded at install; try_copy preserves the source mtime).
        A user-replaced DLL differs and is preserved."""
        if rel not in ours:
            return False
        try:
            st = os.stat(os.path.join(self.prefix, rel))
        except OSError:
            return False
        return (st.st_size, int(st.st_mtime)) == ours[rel]

    def _install_translation_dlls(self, session, track_file=None):
        n = session.neutron
        installed = []
        ours = self._read_translation_manifest()

        def install(src, dst_dir, dll):
            rel = dst_dir + "/" + dll
            dst = os.path.join(self.prefix, rel)
            expect = "x64" if dst_dir.endswith("system32") else "x86"
            problem = check_translation_dll(src, expect)
            if problem:
                log(f"WARNING: skipping bundled {os.path.relpath(src, n.dir)}: "
                    f"{problem} — prefix keeps its current {dll}")
                return
            # Replace Wine builtins and our own earlier copies; anything else
            # is a user-installed native DLL (winetricks, manual) — keep it.
            if file_exists(dst, follow_symlinks=False) and \
                    not file_is_wine_builtin_dll(dst) and \
                    not self._is_our_translation_dll(rel, ours):
                log(f"preserving user-native graphics DLL: {rel}")
                return
            makedirs(os.path.join(self.prefix, dst_dir))
            try_copy(src, rel, prefix=self.prefix, track_file=track_file)
            try:
                st = os.stat(dst)
                ours[rel] = (st.st_size, int(st.st_mtime))
            except OSError:
                pass
            installed.append(dll)

        # WineD3D is an explicit request to use Wine's OpenGL Direct3D path,
        # so a layer marked wined3d_off (DXVK) isn't placed where it would
        # override it — and the Wine builtins go back over copies Neutron
        # itself installed earlier (user-installed natives are left alone).
        wined3d = "wined3d" in session.compat_config
        for layer in TRANSLATION_LAYERS:
            for arch, dst_dir in PREFIX_ARCH_DIRS:
                if not (wined3d and layer.wined3d_off):
                    for dll, src in n.layer_dlls(layer, arch):
                        install(src, dst_dir, dll + ".dll")
                    continue
                for dll in layer.dlls:
                    rel = f"{dst_dir}/{dll}.dll"
                    dst = os.path.join(self.prefix, rel)
                    builtin = os.path.join(n.default_pfx_dir, rel)
                    if self._is_our_translation_dll(rel, ours) and \
                            file_exists(builtin, follow_symlinks=True):
                        log(f"restoring Wine builtin {rel} (wined3d)")
                        os.remove(dst)
                        self._pfx_copy(builtin, dst)
                        ours.pop(rel, None)

        try:
            with open(self.translation_files_file, "w") as f:
                for rel, (size, mtime) in sorted(ours.items()):
                    f.write(f"{rel}\t{size}\t{mtime}\n")
        except OSError:
            pass
        if installed:
            log("installed bundled DXVK/VKD3D-Proton runtime DLLs")

    # — optional VR client DLLs for SteamVR/OpenVR (tracked) —
    def _install_vr_dlls(self, neutron, track_file=None):
        vrclient_dir = "drive_c/vrclient/bin"
        pairs = [
            (os.path.join(neutron.pe_system32, "vrclient_x64.dll"), vrclient_dir),
            (os.path.join(neutron.pe_syswow64, "vrclient.dll"), vrclient_dir),
        ]
        installed = False
        for src, dst in pairs:
            if file_exists(src, follow_symlinks=True):
                makedirs(os.path.join(self.prefix, dst))
                try_copy(src, dst, prefix=self.prefix, track_file=track_file,
                         optional=True)
                installed = True
        return installed

    # — .update-timestamp (suppresses Wine's own prefix re-init) —
    def _write_timestamp(self, neutron):
        ts_file = os.path.join(self.prefix, ".update-timestamp")
        try:
            mtime = int(os.stat(neutron.wine_inf).st_mtime)
            with open(ts_file, "w") as f:
                f.write(str(mtime))
        except OSError:
            pass

    # — config-info: the inputs whose change forces a DLL re-overlay —
    def _compute_config_info(self, session):
        n = session.neutron
        cc = session.compat_config
        return "\n".join((
            CURRENT_PREFIX_VERSION,
            n.lib_dir,
            n.default_pfx_dir,
            mtime_str(n.default_pfx_dir, "system.reg"),
            # flips once when the template diet lands, so existing prefixes
            # re-overlay and trade their builtin copies for links too
            mtime_str(n.default_pfx_dir, n._BUILTINS_LINKED),
            dir_sig(n.pe_system32), dir_sig(n.pe_syswow64),
            *(dir_sig(n.layer_dir(layer, arch) or "")
              for layer in TRANSLATION_LAYERS for arch, _ in PREFIX_ARCH_DIRS),
            # steamclient mtime tracking removed (DLLs no longer copied)
            session.builtin_dll_copy,
            str("wined3d" in cc),
            str(session.use_nvapi),
            str(session.use_wow64),
            str(bool(session.nvidia_wine_dll_dir)),
        ))

    # — remove stale builtins that we no longer ship —
    def _clean_stale_builtins(self):
        for rel in self.STALE_BUILTINS:
            path = os.path.join(self.prefix, rel)
            if file_exists(path, follow_symlinks=False) and \
                    file_is_wine_builtin_dll(path):
                log(f"removing stale builtin {rel}")
                try:
                    os.remove(path)
                except OSError:
                    pass

    # — another compat tool's leftovers (Proton, GE, an older Neutron) —
    # Proton symlinks its DLLs into any prefix it runs in, pointing into ITS
    # lib/wine. Names our template covers get replaced by the next overlay,
    # but the rest (vrclient, protontts, winegstreamer, icu...) survive it, and
    # Wine then loads that tool's PE against our ntdll without its unix half.
    # Move them out (reversibly) every launch; True = overlay should re-run so
    # anything we pulled that we do ship gets our own copy back.
    def _quarantine(self, rel):
        src = os.path.join(self.prefix, rel)
        dst = os.path.join(self.quarantine_dir, rel)
        makedirs(os.path.dirname(dst))
        try:
            if file_exists(dst, follow_symlinks=False):
                os.remove(dst)
            shutil.move(src, dst)
            return True
        except OSError as e:
            log(f"warning: could not quarantine {rel}: {e.strerror}")
            return False

    def _sweep_foreign_files(self, neutron):
        own = os.path.realpath(neutron.dir) + os.sep
        moved = []
        for d in self.FOREIGN_SCAN_DIRS:
            try:
                with os.scandir(os.path.join(self.prefix, d)) as it:
                    links = [e for e in it if e.is_symlink()]
            except OSError:
                continue
            for e in links:
                try:
                    target = os.readlink(e.path)
                except OSError:
                    continue
                if "/lib/wine/" not in target and "/lib64/wine/" not in target:
                    continue
                if os.path.realpath(e.path).startswith(own):
                    continue
                if self._quarantine(d + "/" + e.name):
                    moved.append(e.name)
        if not neutron.has_vrclient():
            for rel in self.VR_FILES:
                if file_exists(os.path.join(self.prefix, rel),
                               follow_symlinks=False) and self._quarantine(rel):
                    moved.append(os.path.basename(rel))
        if moved:
            names = sorted(set(moved))
            shown = ", ".join(names[:12]) + (" ..." if len(names) > 12 else "")
            log(f"quarantined {len(moved)} file(s) another compat tool left "
                f"in this prefix ({shown}) -> {self.quarantine_dir}")
        return bool(moved)

    # — copy one template entry into the prefix (symlink or reflink copy) —
    def _pfx_copy(self, src, dst, dll_copy=False):
        if os.path.islink(src):
            contents = os.readlink(src)
            if os.path.dirname(contents).endswith(WINE_BUILTIN_LINK_DIRS):
                # wine builtin DLL — re-point as an absolute symlink so the
                # link stays valid outside the template directory
                contents = os.path.normpath(
                    os.path.join(os.path.dirname(src), contents))
            if dll_copy:
                try_copy(src, dst)
            else:
                os.symlink(contents, dst)
        else:
            try_copy(src, dst)

    # — clone the default_pfx template into a fresh prefix (tracked) —
    def copy_pfx(self, neutron):
        template = neutron.default_pfx_dir
        with open(self.tracked_files_file, "w") as tracked_files:
            for src_dir, dirs, files in os.walk(template):
                rel_dir = os.path.relpath(src_dir, template)
                rel_dir = "" if rel_dir == "." else rel_dir + "/"
                dst_dir = os.path.join(self.prefix, rel_dir)
                if not file_exists(dst_dir, follow_symlinks=True):
                    makedirs(dst_dir)
                    tracked_files.write(rel_dir + "\n")
                for dir_ in dirs:  # symlinked dirs walk() won't descend into
                    src_file = os.path.join(src_dir, dir_)
                    dst_file = os.path.join(dst_dir, dir_)
                    if os.path.islink(src_file) and \
                            not file_exists(dst_file, follow_symlinks=True):
                        self._pfx_copy(src_file, dst_file)
                        tracked_files.write(rel_dir + dir_ + "\n")
                for file_ in files:
                    src_file = os.path.join(src_dir, file_)
                    dst_file = os.path.join(dst_dir, file_)
                    if not file_exists(dst_file, follow_symlinks=True):
                        self._pfx_copy(src_file, dst_file)
                        tracked_files.write(rel_dir + file_ + "\n")

        # each cloned prefix gets its own machine identity
        guid = self.old_machine_guid or f'"{uuid.uuid4()}"'
        get_replace_machine_guid(
            os.path.join(self.prefix, "system.reg"), replace=guid)

        self._write_timestamp(neutron)

    # — refresh builtin DLLs from the template (never clobber user-native) —
    def update_builtin_libs(self, neutron, dll_copy_patterns):
        template = neutron.default_pfx_dir
        prev_tracked = set()
        try:
            with open(self.tracked_files_file, "r") as tf:
                prev_tracked = {line.strip() for line in tf}
        except OSError:
            pass
        with open(self.tracked_files_file, "a") as tracked_files:
            for src_dir, _, files in os.walk(template):
                rel_dir = os.path.relpath(src_dir, template)
                rel_dir = "" if rel_dir == "." else rel_dir + "/"
                dst_dir = os.path.join(self.prefix, rel_dir)
                if not file_exists(dst_dir, follow_symlinks=True):
                    makedirs(dst_dir)
                    tracked_files.write(rel_dir + "\n")
                for file_ in files:
                    src_file = os.path.join(src_dir, file_)
                    dst_file = os.path.join(dst_dir, file_)
                    if not file_is_wine_builtin_dll(src_file):
                        continue  # only builtins are ours to manage
                    if file_is_wine_builtin_dll(dst_file):
                        os.unlink(dst_file)
                    elif file_exists(dst_file, follow_symlinks=False):
                        continue  # user-native DLL — leave it alone
                    dll_copy = any(fnmatch.fnmatch(file_.lower(), p)
                                   for p in dll_copy_patterns)
                    self._pfx_copy(src_file, dst_file, dll_copy)
                    tracked_name = rel_dir + file_
                    if tracked_name not in prev_tracked:
                        tracked_files.write(tracked_name + "\n")

    # — versioned Neutron prefix initialization / upgrades —
    def upgrade_pfx(self, old_ver):
        if old_ver == CURRENT_PREFIX_VERSION:
            return

        if old_ver is None:
            log(f"Initializing Neutron prefix "
                f"({CURRENT_PREFIX_VERSION}) ({self.compat_data})")
            return  # fresh prefix, nothing to migrate

        log(f"Neutron: upgrading prefix from {old_ver} to "
            f"{CURRENT_PREFIX_VERSION} ({self.compat_data})")

        old = parse_prefix_version(old_ver)
        new = parse_prefix_version(CURRENT_PREFIX_VERSION)
        if old is None or new is None:
            log("Prefix has an invalid version?! You may want to back up "
                "user files and delete this prefix.")
            # let the upgrade happen anyway and hope for the best
            return

        # Downgrade (prefix schema is newer than ours): strip everything we
        # installed and re-clone; keep the prefix's machine identity. Only
        # comparable within one tag — cross-scheme moves are plain upgrades.
        if old[0] == new[0] and (new[1], new[2]) < (old[1], old[2]):
            # Proton wipes tracked files (registry included) here. That also
            # destroys per-prefix state (launcher logins, winetricks), so
            # Neutron only does it on request; the default is a plain
            # re-overlay, which the version mismatch triggers anyway.
            if os.environ.get("NEUTRON_DOWNGRADE_REBUILD") == "1":
                log("Removing newer prefix")
                self.old_machine_guid = get_replace_machine_guid(
                    os.path.join(self.prefix, "system.reg"))
                self.remove_tracked_files()
                if file_exists(self.creation_sync_guard,
                               follow_symlinks=False):
                    os.remove(self.creation_sync_guard)
            else:
                log("prefix was created by a newer Neutron; keeping it and "
                    "re-overlaying (NEUTRON_DOWNGRADE_REBUILD=1 or "
                    "`destroyprefix` forces a clean rebuild)")

    # — steam / VR / NVIDIA extras appended to the manifest —
    def _overlay_extras(self, session, track_file):
        log("installing bundled graphics runtime DLLs...")
        self._install_translation_dlls(session, track_file)
        log("installing Steam client DLLs...")
        self._install_steam_dlls(track_file)
        self._install_vr_dlls(session.neutron, track_file)

        # NVIDIA driver DLLs (nvngx/DLSS) discovered on the host
        if session.nvidia_wine_dll_dir:
            log("installing NVIDIA nvngx DLLs...")
            for dll in ("_nvngx.dll", "nvngx.dll"):
                src = os.path.join(session.nvidia_wine_dll_dir, dll)
                if file_exists(src, follow_symlinks=True):
                    try_copy(src, "drive_c/windows/system32", prefix=self.prefix,
                             track_file=track_file, optional=True)

    # — full prefix setup: version upgrade + template clone + overlay —
    def setup_prefix(self, session):
        if not self.prefix:
            return
        n, env = session.neutron, session.env
        with self.lock:
            # read the prefix's stamped version (None = never created)
            old_ver = None
            if file_exists(self.version_file, follow_symlinks=True):
                try:
                    with open(self.version_file, "r") as f:
                        old_ver = f.readline().strip()
                except OSError:
                    pass

            self.upgrade_pfx(old_ver)

            # the template is both the clone source and the builtin overlay
            # source, so make sure it exists (and is fresh) before either
            n.make_default_prefix(env)

            guard_ok = file_exists(self.creation_sync_guard,
                                   follow_symlinks=False)
            has_reg = os.path.isfile(os.path.join(self.prefix, "system.reg"))
            has_drive_c = os.path.isdir(os.path.join(self.prefix, "drive_c"))
            has_dosdevices = os.path.isdir(os.path.join(self.prefix, "dosdevices"))
            complete_prefix = has_reg and has_drive_c and has_dosdevices
            first_init = not guard_ok and not complete_prefix

            if first_init:
                # Never merge a half-created prefix with a fresh template. It
                # can contain registry/files from an interrupted initializer.
                if os.path.isdir(self.prefix):
                    for entry in os.listdir(self.prefix):
                        path = os.path.join(self.prefix, entry)
                        if os.path.isdir(path) and not os.path.islink(path):
                            shutil.rmtree(path, ignore_errors=True)
                        else:
                            try:
                                os.unlink(path)
                            except OSError:
                                pass
                else:
                    makedirs(self.prefix)
                log("creating prefix from default template...")
                drive_c = os.path.join(self.prefix, "drive_c")
                makedirs(drive_c)
                self._set_casefold(drive_c)
                self.copy_pfx(n)
                os.sync()
                with open(self.creation_sync_guard, "w"):
                    pass
                os.sync()
            elif not guard_ok:
                # Prefix predates the sync guard (legacy Neutron/wineboot
                # era) — adopt it as fully created.
                with open(self.creation_sync_guard, "w"):
                    pass

            # dosdevices (idempotent; also fixes migrated prefixes)
            dosdevices = os.path.join(self.prefix, "dosdevices")
            makedirs(dosdevices)
            for link_name, target in (("c:", "../drive_c"), ("z:", "/")):
                link = os.path.join(dosdevices, link_name)
                if not file_exists(link, follow_symlinks=False):
                    os.symlink(target, link)

            # before the overlay decision, so whatever we pull out that we
            # ship gets our own copy back on this same launch
            swept = not first_init and self._sweep_foreign_files(n)

            # versioned DLL overlay — only when something relevant changed
            config_info = self._compute_config_info(session)
            old_config = ""
            if os.path.isfile(self.config_info_file):
                try:
                    old_config = open(self.config_info_file).read()
                except OSError:
                    pass

            if first_init or swept or old_ver != CURRENT_PREFIX_VERSION \
                    or old_config != config_info:
                log("updating prefix runtime DLLs...")
                if not first_init:
                    self._clean_stale_builtins()
                self.update_builtin_libs(n, session.builtin_dll_copy_list)
                with open(self.tracked_files_file, "a") as tf:
                    self._overlay_extras(session, tf)
                with open(self.config_info_file, "w") as f:
                    f.write(config_info)
            else:
                log("prefix DLLs up to date")

            # stamp the version every run, like Proton (after upgrade_pfx)
            with open(self.version_file, "w") as f:
                f.write(CURRENT_PREFIX_VERSION + "\n")

            # cheap per-launch wiring
            if session.use_steam_shim and session.steam_bridge:
                self._ensure_steamclient_dlls()
            self._setup_drives(session)
            self._setup_openvr(session)
            self._write_timestamp(n)
            if first_init:
                log("prefix ready.")

    # — game-library (s:) and Steam (t:) DOS drives —
    def _setup_dir_drive(self, session, option, drive, dest):
        link = os.path.join(self.prefix, "dosdevices", drive)
        if option in session.compat_config and dest:
            if file_exists(link, follow_symlinks=False):
                if not os.path.islink(link) or os.readlink(link) != dest:
                    os.remove(link)
                    os.symlink(dest, link)
            else:
                os.symlink(dest, link)
        elif file_exists(link, follow_symlinks=False):
            os.remove(link)

    def _setup_drives(self, session):
        env = session.env
        game_lib = None
        inst = env.get("STEAM_COMPAT_INSTALL_PATH", "")
        libs = env.get("STEAM_COMPAT_LIBRARY_PATHS", "")
        if inst and libs:
            for p in libs.split(":"):
                if p and p in inst:
                    game_lib = p
                    break
        self._setup_dir_drive(session, "gamedrive", "s:", game_lib)
        self._setup_dir_drive(session, "steamdrive", "t:",
                              self.steam_root or None)

    # — OpenVR: rewrite openvrpaths.vrpath into the prefix, capture runtime —
    def _setup_openvr(self, session):
        env = session.env
        # No vrclient of our own: a vrpath would only lead DXVK's openvr
        # bridge to one (the sweep keeps other tools' copies out)
        if not session.neutron.has_vrclient():
            return
        if "VR_PATHREG_OVERRIDE" in env:
            src = env["VR_PATHREG_OVERRIDE"]
        elif "XDG_CONFIG_HOME" in env:
            src = os.path.join(env["XDG_CONFIG_HOME"],
                               "openvr/openvrpaths.vrpath")
        elif "HOME" in env:
            src = os.path.join(env["HOME"],
                               ".config/openvr/openvrpaths.vrpath")
        else:
            return
        if not file_exists(src, follow_symlinks=True):
            return
        try:
            with open(src) as f:
                contents = json.load(f)
        except (OSError, ValueError):
            return
        if not isinstance(contents.get("runtime"), list):
            contents["runtime"] = []

        if "VR_OVERRIDE" in env:
            env["PROTON_VR_RUNTIME"] = env["VR_OVERRIDE"]
        elif contents["runtime"]:
            env["PROTON_VR_RUNTIME"] = contents["runtime"][0]

        contents["runtime"] = ["C:\\vrclient\\", "C:\\vrclient"]
        dst_dir = os.path.join(self.prefix,
                               "drive_c/users/steamuser/AppData/Local/openvr")
        makedirs(dst_dir)
        try:
            with open(os.path.join(dst_dir, "openvrpaths.vrpath"), "w") as f:
                json.dump(contents, f, indent=3)
        except OSError:
            pass

    # — runtime base-Proton lib paths (read back from the marker) —
    def proton_lib_paths(self):
        empty = ([], [], "")
        if not self.prefix:
            return empty
        # Check both modern and legacy markers
        marker = os.path.join(self.prefix, self.PROTON_MARKER)
        if not os.path.isfile(marker):
            marker = os.path.join(self.prefix, ".neutron-proton-path")
        if not os.path.isfile(marker):
            return empty
        try:
            base_proton_dir = open(marker).read().strip()
        except OSError:
            return empty
        
        # Base Proton may be old enough to still ship lib64; probe both.
        unix_paths = []
        dll_paths = []
        for lib_name in ("lib", "lib64"):
            base = os.path.join(base_proton_dir, "files", lib_name, "wine")
            for arch, bucket in (("x86_64-unix", unix_paths),
                                 ("i386-unix", unix_paths),
                                 ("x86_64-windows", dll_paths),
                                 ("i386-windows", dll_paths)):
                p = os.path.join(base, arch)
                if os.path.isdir(p) and p not in bucket:
                    bucket.append(p)

        return unix_paths, dll_paths, base_proton_dir

    # — standalone overlay: runtime DLLs + version stamp, no clone phase —
    # Used by createprefix (base-Proton-assisted) where the prefix already
    # exists; setup_prefix embeds the same steps for the normal launch path.
    def overlay(self, session, base_proton_dir=None):
        n = session.neutron
        with self.lock:
            n.make_default_prefix(session.env)
            self._clean_stale_builtins()
            self.update_builtin_libs(n, session.builtin_dll_copy_list)
            with open(self.tracked_files_file, "a") as tf:
                self._overlay_extras(session, tf)
            with open(self.config_info_file, "w") as f:
                f.write(self._compute_config_info(session))
            with open(self.version_file, "w") as f:
                f.write(CURRENT_PREFIX_VERSION + "\n")

            if base_proton_dir:
                marker = os.path.join(self.prefix, self.PROTON_MARKER)
                try:
                    with open(marker, "w") as f:
                        f.write(base_proton_dir)
                    log("saved base Proton path marker for runtime lib "
                        "injection")
                except OSError as e:
                    log(f"warning: could not write marker: {e}")

            self._write_timestamp(n)

    # — base-Proton-assisted prefix creation —
    def create_with_proton(self, session, base_proton_path):
        base_proton_dir = os.path.realpath(base_proton_path)
        base_proton_script = os.path.join(base_proton_dir, "proton")

        if not os.path.isfile(base_proton_script):
            die(f"base Proton script not found: {base_proton_script}")
        if not self.compat_data:
            die("STEAM_COMPAT_DATA_PATH must be set")
        if not self.prefix:
            die("Cannot determine WINEPREFIX from STEAM_COMPAT_DATA_PATH")

        system_reg = os.path.join(self.prefix, "system.reg")
        if os.path.isfile(system_reg):
            log("prefix already initialized, skipping base Proton phase")
            log("applying Neutron overlay only...")
            self.overlay(session)
            log("createprefix done.")
            return

        base_proton_env = os.environ.copy()
        for pvar in ("PYTHONHOME", "PYTHONPATH", "PYTHONDONTWRITEBYTECODE"):
            base_proton_env.pop(pvar, None)
        base_proton_env["STEAM_COMPAT_DATA_PATH"] = self.compat_data
        base_proton_env["WINEPREFIX"] = self.prefix
        base_proton_env.setdefault("WINEDEBUG", "-all")
        base_proton_env.setdefault("STEAM_COMPAT_CLIENT_INSTALL_PATH",
                                   os.path.expanduser("~/.steam/steam"))
        for key in ("SteamAppId", "SteamGameId", "STEAM_COMPAT_APP_ID",
                    "STEAM_COMPAT_INSTALL_PATH", "STEAM_COMPAT_TOOL_PATHS",
                    "STEAM_COMPAT_MOUNTS"):
            if key in os.environ:
                base_proton_env[key] = os.environ[key]

        log(f"createprefix — using base Proton at {base_proton_dir}")
        log("phase 1 — base Proton prefix creation...")
        result = subprocess.run(
            [base_proton_script, "waitforexitandrun",
             "c:\\windows\\system32\\cmd.exe", "/c", "exit"],
            env=base_proton_env, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE)
        if result.returncode != 0:
            stderr_text = result.stderr.decode("utf-8", errors="replace")
            log(f"base Proton stderr:\n{stderr_text}")
            die(f"base Proton prefix creation failed (exit {result.returncode})")

        base_proton_wineserver = os.path.join(
            base_proton_dir, "files", "bin", "wineserver")
        if os.path.isfile(base_proton_wineserver):
            log("killing base Proton wineserver...")
            subprocess.run([base_proton_wineserver, "-k"],
                           env=base_proton_env, timeout=15)

        log("phase 2 — Neutron overlay...")
        self.overlay(session, base_proton_dir=base_proton_dir)
        log("createprefix done — prefix is ready for Neutron.")

    # — destroyprefix: remove exactly what we installed —
    def remove_tracked_files(self):
        if not self.tracked_files_file or \
                not file_exists(self.tracked_files_file, follow_symlinks=True):
            log("prefix has no tracked_files manifest")
            return
        dirs = []
        with open(self.tracked_files_file) as tf:
            for line in tf:
                path = os.path.join(self.prefix, line.strip())
                if file_exists(path, follow_symlinks=False):
                    if os.path.isfile(path) or os.path.islink(path):
                        os.remove(path)
                    else:
                        dirs.append(path)
        for d in sorted(dirs, key=len, reverse=True):
            try:
                os.rmdir(d)
            except OSError:
                pass
        for f in (self.tracked_files_file, self.version_file,
                  self.config_info_file, self.creation_sync_guard,
                  self.translation_files_file):
            try:
                os.remove(f)
            except OSError:
                pass
        log("removed tracked files; prefix DLLs will be reinstalled next run")

# ── Runtime environment construction and process execution ───────────────────
class Session:
    """Builds the launch environment and runs commands inside it."""

    OPENXR_RUNTIMES = [
        "/usr/share/openxr/1/openxr_monado.json",
        "/etc/openxr/1/active_runtime.json",
    ]

    def __init__(self, neutron, compatdata):
        self.neutron = neutron
        self.compatdata = compatdata
        self.env = os.environ.copy()
        self.gamemode_wrap = False
        self.log_file = None

        # compat_config framework (per-launch options, like Proton)
        self.compat_config = set()
        self.cmdlineappend = []
        for source in (os.environ.get("STEAM_COMPAT_CONFIG", ""),
                       os.environ.get("NEUTRON_CONFIG", "")):
            for token in source.split(","):
                token = token.strip()
                if not token:
                    continue
                if token.startswith("cmdlineappend:"):
                    self.cmdlineappend.append(token[len("cmdlineappend:"):])
                else:
                    self.compat_config.add(token)
        self.compat_config.add("gamedrive")          # map s: by default
        if "noforcelgadd" not in self.compat_config:  # large-address-aware on
            self.compat_config.add("forcelgadd")

        # builtin DLL copy list (overridable, Proton-style)
        self.builtin_dll_copy = os.environ.get(
            "NEUTRON_DLL_COPY", ",".join(DEFAULT_BUILTIN_DLL_PATTERNS))
        self.builtin_dll_copy_list = [p for p in self.builtin_dll_copy.split(",")
                                      if p]

        # capability flags consumed by config-info + overlay
        self.use_nvapi = "disablenvapi" not in self.compat_config
        self.use_wow64 = (os.environ.get("NEUTRON_USE_WOW64", "0") == "1")
        self.nvidia_wine_dll_dir = find_nvidia_wine_dll_dir()
        self.use_wayland, self.wayland_reason = self._decide_wayland()
        # lsteamclient + steam.exe built with this Wine → Proton's Steam model
        self.steam_bridge = self.neutron.build_info.get("STEAM_BRIDGE") == "ge"
        self.use_steam_shim, self.steam_shim_reason = self._decide_steam_shim()
        self.sony_mode = "build default"   # set by _apply_sony_input_env

    # — Proton's steam.exe helper: per-launch decision —
    def _decide_steam_shim(self):
        """-> (use, reason). steam.exe registers the Steam client for the game
        (lsteamclient's steamclient_init_registry). That only makes sense for a
        real Steam app while the Steam client is up, so launches with a
        launcher-made id (e.g. the Mythix Launcher's hex ids for non-Steam
        games) or without Steam go straight to the game.
        NEUTRON_USE_STEAM_SHIM=1 forces it, =0 disables it."""
        knob = os.environ.get("NEUTRON_USE_STEAM_SHIM", "auto")
        if knob == "0":
            return False, "off (NEUTRON_USE_STEAM_SHIM=0)"
        if knob == "1":
            return True, "forced (NEUTRON_USE_STEAM_SHIM=1)"
        if not self.steam_bridge:
            return False, "build has no Steam bridge"
        appid = self.env.get("SteamGameId") or self.env.get("SteamAppId") or ""
        if not (appid.isascii() and appid.isdigit() and int(appid) > 0):
            return False, f"no Steam app id ({appid or 'unset'}): direct launch"
        if not steam_client_running():
            return False, "Steam client not running: direct launch"
        return True, f"Steam app {appid}"

    # — DualShock 4 / DualSense —
    def _apply_sony_input_env(self):
        """Builds whose xinput carries GE's Sony stack: by default a Sony pad is
        also an XInput controller (PROTON_SONY_AUTO_XINPUT=1, GE-Proton's own
        default) that steps aside when a game reads it natively or Steam Input
        owns it. MYTHIX_DS4_GLYPHS=1 is native PlayStation mode: the pad stays
        out of XInputGetState, so PlayStation-aware games read it over HID
        (PS glyphs), while XInputSetState still rumbles it."""
        env = self.env
        feats = self.neutron.xinput_features()
        native = env.get("MYTHIX_DS4_GLYPHS", "")[:1] == "1"
        if not feats["sony_auto"]:
            self.sony_mode = ("native PlayStation (MYTHIX_DS4_GLYPHS=1)"
                              if native and feats["glyphs"] else "build default")
            return
        if "PROTON_SONY_AUTO_XINPUT" in env:
            self.sony_mode = ("PROTON_SONY_AUTO_XINPUT="
                              f"{env['PROTON_SONY_AUTO_XINPUT']} (set by you)")
        elif native:
            self.sony_mode = ("native PlayStation (MYTHIX_DS4_GLYPHS=1): "
                              "input + glyphs over HID, rumble via XInput")
            if not feats["glyphs"]:
                self.sony_mode += " (this xinput lacks the Mythix patch)"
        else:
            env["PROTON_SONY_AUTO_XINPUT"] = "1"
            self.sony_mode = ("XInput fallback (PROTON_SONY_AUTO_XINPUT=1), "
                              "native takeover")

    # — native Wayland driver (winewayland) selection —
    def _decide_wayland(self):
        """-> (use_wayland, reason). Opt-in per build (build-info WAYLAND=1),
        per launch (NEUTRON_WAYLAND=1, compat_config `wayland`, or GE's
        PROTON_ENABLE_WAYLAND / PROTON_USE_WAYLAND); NEUTRON_WAYLAND=0 or
        `nowayland` forces X11. Needs a Wayland session (WAYLAND_DISPLAY)."""
        env = self.env
        knob = env.get("NEUTRON_WAYLAND", "")
        if knob == "0" or "nowayland" in self.compat_config:
            return False, "forced off (NEUTRON_WAYLAND=0 / nowayland) — X11 driver"
        if knob == "1":
            why = "NEUTRON_WAYLAND=1"
        elif "wayland" in self.compat_config:
            why = "compat_config wayland"
        elif (nonzero(env.get("PROTON_ENABLE_WAYLAND", ""))
              or nonzero(env.get("PROTON_USE_WAYLAND", ""))):
            why = "PROTON_ENABLE_WAYLAND"
        elif self.neutron.build_info.get("WAYLAND") == "1":
            why = "build default (Wayland-first build)"
        else:
            return False, "off for this build (NEUTRON_WAYLAND=1 enables)"
        if not env.get("WAYLAND_DISPLAY"):
            return False, f"wanted ({why}) but no Wayland session (WAYLAND_DISPLAY unset)"
        return True, why

    @staticmethod
    def _primary_monitor():
        """Primary output name as XWayland reports it (GE does the same)."""
        xrandr = shutil.which("xrandr")
        if not xrandr:
            return None
        try:
            out = subprocess.run([xrandr], capture_output=True, text=True,
                                 timeout=3, check=True).stdout
        except (OSError, subprocess.SubprocessError):
            return None
        for line in out.splitlines():
            m = re.match(r"^(\S+)\s+connected\s+primary\b", line)
            if m:
                return m.group(1)
        return None

    def _apply_wayland_env(self):
        """Mirror GE-Proton's winewayland launch environment."""
        env = self.env
        if not self.use_wayland:
            if self.wayland_reason.startswith("forced off"):
                # Wayland-first builds would still pick winewayland on their own
                env.setdefault("WINE_GRAPHICS_DRIVER", "x11")
            return
        env.setdefault("WINE_GRAPHICS_DRIVER", "wayland")
        env.setdefault("WINE_USE_EGL", "1")                 # OpenGL on winewayland
        env.setdefault("WINE_DISABLE_FULLSCREEN_HACK", "1") # FSHack is X11-only
        env.setdefault("WINE_MOVE_HACK", "1")
        env.setdefault("PROTON_USE_XALIA", "0")             # can't position toplevels
        monitor = (env.get("NEUTRON_WAYLAND_MONITOR")
                   or env.get("PROTON_WAYLAND_MONITOR"))
        if monitor:
            env["WAYLANDDRV_PRIMARY_MONITOR"] = monitor
        elif "WAYLANDDRV_PRIMARY_MONITOR" not in env:
            monitor = self._primary_monitor()
            if monitor:
                env["WAYLANDDRV_PRIMARY_MONITOR"] = monitor

    # — sync primitive detection —
    @staticmethod
    def _binary_has(binary_path, search_string):
        try:
            with open(binary_path, "rb") as f:
                return search_string.encode() in f.read()
        except OSError:
            return False

    def _detect_sync(self):
        server = self.neutron.wineserver
        build_ntsync = self._binary_has(server, "ntsync")
        has_fsync = self._binary_has(server, "fsync")
        has_esync = self._binary_has(server, "esync")

        # ntsync (Linux 6.14+ /dev/ntsync) is the fastest sync primitive and is
        # preferred whenever both the Wine build and the running kernel support
        # it. NEUTRON_NTSYNC: auto (build + /dev/ntsync), 1 (force), 0 (off).
        ntsync_mode = os.environ.get("NEUTRON_NTSYNC", "auto")
        if ntsync_mode == "0":
            use_ntsync = False
        elif ntsync_mode == "1":
            use_ntsync = build_ntsync
        else:
            # build profile decides whether ntsync is even on the table
            use_ntsync = (profile()["ntsync"] and build_ntsync
                          and os.path.exists("/dev/ntsync"))

        if use_ntsync:
            self.env.setdefault("WINENTSYNC", "1")
            self.env.setdefault("NEUTRON_NTSYNC", "1")

        if has_fsync:
            self.env.setdefault("WINEFSYNC", "1")
        if has_esync:
            self.env.setdefault("WINEESYNC", "1")

    # — user_settings.py overrides (Proton-idiomatic) —
    def _load_user_settings(self):
        settings_file = os.path.join(self.neutron.dir, "user_settings.py")
        if not file_exists(settings_file, follow_symlinks=True):
            return
        try:
            sys.path.insert(0, self.neutron.dir)
            import user_settings  # noqa: E401  (optional user file)
            for key, value in user_settings.user_settings.items():
                self.env.setdefault(key, value)
        except Exception as e:  # malformed user file shouldn't be fatal
            log(f"warning: error in user_settings.py: {e}")
        finally:
            if self.neutron.dir in sys.path:
                sys.path.remove(self.neutron.dir)

    # — quick host health warnings (fd limit, max_map_count) —
    @staticmethod
    def _check_system_limits():
        try:
            _, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
            if hard < 524288:
                log(f"warning: low file-descriptor limit ({hard}); "
                    "some games may crash")
        except (OSError, ValueError):
            pass
        try:
            with open("/proc/sys/vm/max_map_count") as f:
                if int(f.read()) < 1048576:
                    log("warning: low vm.max_map_count; some games may fail "
                        "to launch")
        except (OSError, ValueError):
            pass

    # — NEUTRON_LOG logging to a file with a header —
    def _setup_logging(self):
        base = self.env.get("NEUTRON_LOG_DIR") or self.env.get("HOME", "/tmp")
        appid = os.environ.get("SteamGameId", "")
        name = f"steam-{appid}.log" if appid else "neutron.log"
        path = os.path.join(base, name)
        try:
            makedirs(base)
            self.log_file = open(path, "w")
        except OSError:
            self.log_file = None
            return
        f = self.log_file
        f.write("====================== neutron log ======================\n")
        f.write(f"Neutron: {self.neutron.tool_version()}\n")
        try:
            u = os.uname()
            f.write(f"Kernel: {u.sysname} {u.release} {u.machine}\n")
        except OSError:
            pass
        f.write(f"Command: {sys.argv[2:] + self.cmdlineappend}\n")
        f.write(f"compat_config: {sorted(self.compat_config)}\n")
        f.write(f"WINEDLLOVERRIDES: {self.env.get('WINEDLLOVERRIDES')}\n")
        f.write(f"WINEDEBUG: {self.env.get('WINEDEBUG')}\n")
        f.write(f"PATH: {self.env.get('PATH')}\n")
        f.write("=========================================================\n")
        f.flush()

    # — assemble the full environment —
    def init_session(self, make_prefix=True):
        n = self.neutron
        cd = self.compatdata
        env = self.env

        self._load_user_settings()

        # Wine binaries
        env["WINE"] = n.wine
        # Unified Wine has no separate wine64 executable; in that layout the
        # normal wine loader handles both PE32 and PE32+ programs.
        env["WINE64"] = n.loader()
        env["WINESERVER"] = n.wineserver
        env["WINEBOOT"] = n.wineboot
        env["WINELOADER"] = n.loader()

        # WoW64 (new-style 32-on-64 without a 32-bit Wine) when requested
        env.pop("WINEARCH", None)
        if self.use_wow64:
            env["WINEARCH"] = "wow64"

        # Wine prefix
        if cd.prefix:
            env["WINEPREFIX"] = cd.prefix
            if make_prefix:
                makedirs(cd.prefix)

        # preserve the caller's LD path so Wine can restore it for child apps
        if "ORIG_LD_LIBRARY_PATH" not in env:
            env["ORIG_LD_LIBRARY_PATH"] = env.get("LD_LIBRARY_PATH", "")

        # PATH
        prepend_to_env(env, "PATH", n.bin_dir, ":")

        # Steam overlay paths
        overlay_paths = []
        if cd.steam_root:
            overlay_paths += [
                os.path.join(cd.steam_root, "ubuntu12_64"),
                os.path.join(cd.steam_root, "ubuntu12_32"),
            ]

        # SteamVR runtime exposure
        steamvr_home = ""
        if cd.steam_root:
            candidate = os.path.join(cd.steam_root, "steamapps",
                                     "common", "SteamVR")
            if os.path.isdir(candidate):
                steamvr_home = candidate
        if steamvr_home:
            steamvr_linux64 = os.path.join(steamvr_home, "bin", "linux64")
            overlay_paths += [steamvr_linux64,
                              os.path.join(steamvr_home, "bin")]
            env.setdefault("VR_OVERRIDE", steamvr_home)
            vrclient = os.path.join(steamvr_linux64, "vrclient.so")
            if os.path.isfile(vrclient):
                env.setdefault("OPENVR_RUNTIME", vrclient)

        # OpenXR runtime
        for runtime in self.OPENXR_RUNTIMES:
            if os.path.isfile(runtime):
                env.setdefault("XR_RUNTIME_JSON", runtime)
                break

        ac_wine_paths = []

        # LD_LIBRARY_PATH
        ld_parts = [n.lib_dir] + overlay_paths
        existing_ld = env.get("LD_LIBRARY_PATH", "")
        env["LD_LIBRARY_PATH"] = ":".join(
            p for p in ld_parts + [existing_ld] if p)

        # WINEDLLPATH
        dll_paths = []
        for d in (n.pe_system32, n.pe_syswow64):
            if os.path.isdir(d):
                dll_paths.append(d)
        dll_paths += ac_wine_paths
        opencomposite = env.get("OPENCOMPOSITE_PATH")
        if opencomposite and os.path.isdir(opencomposite):
            dll_paths.insert(0, opencomposite)
        if dll_paths:
            existing_dllpath = env.get("WINEDLLPATH", "")
            env["WINEDLLPATH"] = ":".join(
                dll_paths + ([existing_dllpath] if existing_dllpath else []))

        # DLL overrides (compat_config-aware)
        self._build_dll_overrides()

        # Sync primitives
        self._detect_sync()

        # Build-profile defaults (per-build curation)
        for key, value in profile()["env_defaults"].items():
            if key == "WINE_GST_REGISTRY_DIR":
                value = os.path.join(cd.compat_data, "gstreamer-1.0") + "/"
            env.setdefault(key, value)
        if profile()["proton_env"]:
            # proton-wine's winegstreamer expects the bundle's own plugins
            gst_dirs = [d for d in (os.path.join(n.lib_dir, "gstreamer-1.0"),
                                    os.path.join(n.files_dir, "lib64",
                                                 "gstreamer-1.0"))
                        if os.path.isdir(d)]
            if gst_dirs:
                env.setdefault("GST_PLUGIN_SYSTEM_PATH_1_0", ":".join(gst_dirs))

        # General defaults
        if "forcelgadd" in self.compat_config:
            env.setdefault("WINE_LARGE_ADDRESS_AWARE", "1")
        elif "noforcelgadd" in self.compat_config:
            env["WINE_LARGE_ADDRESS_AWARE"] = "0"
        env.setdefault("WINEDEBUG", "-all")
        env.setdefault("DXVK_LOG_LEVEL", "none")

        # Display driver (native Wayland vs X11/XWayland)
        self._apply_wayland_env()

        # DualShock 4 / DualSense: XInput fallback vs native PlayStation mode
        self._apply_sony_input_env()

        # DXVK defaults
        if self.use_nvapi:
            env.setdefault("DXVK_ENABLE_NVAPI", "1")
        env.setdefault("DXVK_STATE_CACHE", "1")
        env.setdefault("DXVK_HDR", "0")
        if env.get("NEUTRON_DXVK_ASYNC") == "1":
            env.setdefault("DXVK_ASYNC", "1")
        if os.path.isfile(n.dxvk_conf):
            env.setdefault("DXVK_CONFIG_FILE", n.dxvk_conf)
        # FSR & DXVK FPS limit toggles
        if os.environ.get("NEUTRON_FSR") == "1":
            env.setdefault("WINE_FULLSCREEN_FSR", "1")
        fps_limit = os.environ.get("NEUTRON_FPS_LIMIT")
        if fps_limit:
            env.setdefault("DXVK_FRAME_RATE", fps_limit)

        # Mesa / Vulkan hints
        env.setdefault("RADV_PERFTEST", "gpl,nggc,sam")
        env.setdefault("__GLVND_DISALLOW_PATCHING", "1")

        # GPU-hiding workarounds (compat_config)
        if "hidenvgpu" in self.compat_config:
            env.setdefault("WINE_HIDE_NVIDIA_GPU", "1")
        if "hideamdgpu" in self.compat_config:
            env.setdefault("WINE_HIDE_AMD_GPU", "1")
        if "hideintelgpu" in self.compat_config:
            env.setdefault("WINE_HIDE_INTEL_GPU", "1")
        if "hideapu" in self.compat_config:
            env.setdefault("WINE_HIDE_APU", "1")

        # Wine heap workarounds (compat_config)
        if "heapdelayfree" in self.compat_config:
            env.setdefault("WINE_HEAP_DELAY_FREE", "1")
        if "heapzeromemory" in self.compat_config:
            env.setdefault("WINE_HEAP_ZERO_MEMORY", "1")
        if "heaptopdown" in self.compat_config:
            env.setdefault("WINE_HEAP_TOP_DOWN", "1")

        # NVIDIA driver DLL dir for NGX/DLSS fallback discovery
        if self.nvidia_wine_dll_dir:
            env.setdefault("NVIDIA_WINE_DLL_DIR", self.nvidia_wine_dll_dir)

        # NVIDIA PRIME offload
        if os.environ.get("NEUTRON_PRIME_RENDER_OFFLOAD") == "1":
            env.setdefault("__NV_PRIME_RENDER_OFFLOAD", "1")
            env.setdefault("__GLX_VENDOR_LIBRARY_NAME", "nvidia")
            env.setdefault("__VK_LAYER_NV_optimus", "NVIDIA_only")

        # VR-specific debugging
        if env.get("NEUTRON_VR_DEBUG") == "1":
            env["WINEDEBUG"] = "+timestamp,+vrclient,+openxr"
            env["DXVK_LOG_LEVEL"] = "info"

        # MangoHud
        if env.get("MANGOHUD") == "1":
            env.setdefault("MANGOHUD_DLSYM", "1")

        # GameMode
        gamemode_available = shutil.which("gamemoderun") is not None
        use_gamemode = os.environ.get("NEUTRON_GAMEMODE", "auto")
        if use_gamemode == "auto":
            use_gamemode = "1" if gamemode_available else "0"
        self.gamemode_wrap = use_gamemode == "1" and gamemode_available

        # Steam App ID forwarding
        app_id = os.environ.get("SteamAppId", "")
        game_id = os.environ.get("SteamGameId", app_id)
        if app_id:
            env.setdefault("SteamAppId", app_id)
            env.setdefault("SteamGameId", game_id)

        # Host health diagnostics
        self._check_system_limits()

        # NEUTRON_LOG file logging (verbose Wine debug + header)
        if nonzero(env.get("NEUTRON_LOG", "")):
            if "WINEDEBUG" not in os.environ and \
                    env.get("NEUTRON_VR_DEBUG") != "1":
                env["WINEDEBUG"] = \
                    "+timestamp,+pid,+tid,+seh,+module,+loaddll,+mscoree"
            env.setdefault("DXVK_LOG_LEVEL", "info")
            self._setup_logging()

    def _build_dll_overrides(self):
        cd = self.compatdata
        overrides = {}

        if cd.compat_data:
            overrides["lsteamclient"] = "n,b"

        # Translation-layer overrides: only for DLLs we actually ship, in the
        # profile's style ("n" = native-only like Proton, no silent fallback).
        n = self.neutron
        style = profile()["d3d_override"]
        wined3d = "wined3d" in self.compat_config
        for layer in TRANSLATION_LAYERS:
            if wined3d and layer.wined3d_off:
                continue
            for dll, _ in n.layer_dlls(layer, "x64"):
                overrides[dll] = style

        # Proton's steam.exe helper (registers the Steam client for the game)
        if self.steam_bridge:
            overrides["steam.exe"] = "b"

        # Native Wayland driver: make sure it isn't disabled by a stale override
        if self.use_wayland:
            overrides["winewayland.drv"] = "b"

        # Disable VR client DLLs unless this build ships its own — another
        # tool's copy (a Proton that ran in the prefix, or the atom container)
        # crashes against our Wine as soon as DXVK's openvr bridge loads it
        if os.environ.get("NEUTRON_ATOM_PROTON") or not n.has_vrclient():
            overrides["vrclient"] = ""
            overrides["vrclient_x64"] = ""

        combined = ";".join(f"{k}={v}" for k, v in overrides.items())
        if combined:
            prepend_to_env(self.env, "WINEDLLOVERRIDES", combined, ";")

    # — Vulkan sanity check —
    @staticmethod
    def check_vulkan():
        vulkaninfo = shutil.which("vulkaninfo")
        if not vulkaninfo:
            log("warning: vulkaninfo not found")
            return
        try:
            result = subprocess.run([vulkaninfo], stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL, timeout=10)
            if result.returncode != 0:
                log("warning: Vulkan appears unhealthy")
        except Exception:
            log("warning: Vulkan validation failed")

    # — base-Proton runtime libs (lsteamclient & co.) for prefixes created
    #   with `createprefix --proton`; opt-in via NEUTRON_INJECT_BASE_PROTON=1 —
    def _inject_base_proton(self):
        unix_paths, dll_paths, base_proton_dir = \
            self.compatdata.proton_lib_paths()
        if not base_proton_dir or \
                os.environ.get("NEUTRON_INJECT_BASE_PROTON") != "1":
            return
        # Never into LD_LIBRARY_PATH (clashes with our own unix libs and
        # breaks Vulkan); WINEDLLPATH is where Wine resolves builtins.
        all_paths = unix_paths + dll_paths
        if all_paths:
            prepend_to_env(self.env, "WINEDLLPATH", ":".join(all_paths), ":")
        log(f"injecting base Proton lib paths from {base_proton_dir}")

    # — Atom mode: run Proton prefix setup every launch, then launch
    #   with Neutron's Wine.  Mimics Steam's require_tool_appid. —
    def _atom_proton_setup(self):
        atom_proton = os.environ.get("NEUTRON_ATOM_PROTON", "")
        if not atom_proton:
            return
        base_proton_dir = os.path.realpath(atom_proton)
        base_proton_script = os.path.join(base_proton_dir, "proton")
        if not os.path.isfile(base_proton_script):
            log(f"warning: NEUTRON_ATOM_PROTON set but no proton script at "
                f"{base_proton_script}")
            return

        log(f"Atom mode — running base Proton prefix setup "
            f"({os.path.basename(base_proton_dir)})...")

        atom_env = os.environ.copy()
        for pvar in ("PYTHONHOME", "PYTHONPATH", "PYTHONDONTWRITEBYTECODE"):
            atom_env.pop(pvar, None)
        atom_env["STEAM_COMPAT_DATA_PATH"] = self.compatdata.compat_data
        atom_env["WINEPREFIX"] = self.compatdata.prefix
        atom_env.setdefault("WINEDEBUG", "-all")
        atom_env.setdefault("STEAM_COMPAT_CLIENT_INSTALL_PATH",
                            os.path.expanduser("~/.steam/steam"))
        for key in ("SteamAppId", "SteamGameId", "STEAM_COMPAT_APP_ID",
                     "STEAM_COMPAT_INSTALL_PATH", "STEAM_COMPAT_TOOL_PATHS",
                     "STEAM_COMPAT_MOUNTS"):
            if key in os.environ:
                atom_env[key] = os.environ[key]

        # Use runinprefix + wineboot -u: this runs Proton's wine to
        # create/update the prefix structure WITHOUT Proton's DLL overlay.
        # Neutron's own setup_prefix() then installs compatible DLLs.
        # (waitforexitandrun would install Proton's Wine 11 DLLs which
        # are incompatible with Neutron's Wine 10.x binary.)
        result = subprocess.run(
            [base_proton_script, "runinprefix", "wineboot", "-u"],
            env=atom_env, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE, timeout=120)
        if result.returncode != 0:
            stderr_text = result.stderr.decode("utf-8", errors="replace")
            log(f"Atom: base Proton returned {result.returncode}")
            if stderr_text.strip():
                debug("Atom Proton stderr", text=stderr_text[:500])

        base_wineserver = os.path.join(base_proton_dir, "files", "bin",
                                       "wineserver")
        if os.path.isfile(base_wineserver):
            try:
                subprocess.run([base_wineserver, "-k"], env=atom_env,
                               timeout=15, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
            except Exception:
                pass

        marker = os.path.join(self.compatdata.prefix,
                              self.compatdata.PROTON_MARKER)
        try:
            with open(marker, "w") as f:
                f.write(base_proton_dir)
        except OSError:
            pass

        log("Atom: base Proton setup complete, launching with Neutron")

    # — run / waitforexitandrun —
    def run(self, args, wait=True):
        n = self.neutron
        cd = self.compatdata
        env = self.env

        debug("Session.run() entered", args=list(args), wait=wait)

        self._atom_proton_setup()

        debug("Preparing prefix")
        cd.setup_prefix(self)
        debug("Prefix ready")

        debug("Checking Vulkan")
        self.check_vulkan()
        debug("Vulkan check complete")

        self._inject_base_proton()

        # honour cmdlineappend from compat_config
        args = list(args) + self.cmdlineappend

        runner = n.runner()
        exe_name = os.path.basename(args[0]).lower() if args else ""

        use_start_wait = os.environ.get("NEUTRON_START_WAIT", "auto")
        if use_start_wait == "auto":
            use_start_wait = ("launcher" in exe_name or "steamvr" in exe_name)
        else:
            use_start_wait = use_start_wait == "1"

        steam_exe = (os.path.join(cd.prefix, "drive_c", "windows",
                                  "system32", "steam.exe")
                     if cd.prefix else None)
        use_steam_shim = (
            steam_exe and os.path.exists(steam_exe)
            and exe_name != "steam.exe"
            and self.use_steam_shim)

        if use_steam_shim:
            log("launching through steam.exe shim")
            debug("Launch mode", mode="Steam shim")
            win_args = []
            for a in args:
                if os.path.isabs(a) and os.path.exists(a):
                    win_args.append("Z:" + a.replace("/", "\\"))
                else:
                    win_args.append(a)
            cmd = [runner, "c:\\windows\\system32\\steam.exe"] + win_args
        elif use_start_wait:
            log(f"using start /wait mode ({exe_name})")
            debug("Launch mode", mode="wine start /wait")
            cmd = [runner, "start", "/wait", "/unix"] + args
        else:
            debug("Launch mode", mode="Direct Wine")
            cmd = [runner] + args

        # Native Gamescope integration
        if os.environ.get("NEUTRON_GAMESCOPE") == "1" and shutil.which("gamescope"):
            # prepend gamescope and optional args
            scope_args = os.environ.get("NEUTRON_GAMESCOPE_ARGS", "").split()
            debug("Launch mode", mode="Gamescope")
            cmd = ["gamescope", *scope_args, "--"] + cmd

        if "steamvr" in exe_name:
            env.setdefault("PROTON_ENABLE_NVAPI", "1")
            env.setdefault("VR_COMPOSITOR_FORCE_GPU", "1")

        if self.gamemode_wrap:
            debug("Launch mode", mode="gamemoderun")
            cmd = ["gamemoderun"] + cmd

        debug("Building launch command", command=cmd)

        interesting_env_keys = [
            "WINEPREFIX",
            "WINEDLLOVERRIDES",
            "WINEDLLPATH",
            "PATH",
            "LD_LIBRARY_PATH",
            "STEAM_COMPAT_DATA_PATH",
            "STEAM_COMPAT_INSTALL_PATH",
            "STEAM_COMPAT_CLIENT_INSTALL_PATH",
            "STEAM_COMPAT_TOOL_PATHS",
            "STEAM_COMPAT_SHADER_PATH",
            "PROTONPATH",
            "NTSYNC",
            "DXVK_ASYNC",
        ]
        env_dump = {k: env.get(k) for k in interesting_env_keys if k in env}

        launch_cwd = os.getcwd()

        debug(
            "Launch",
            runner=runner,
            executable=args[0] if args else None,
            working_directory=launch_cwd,
            cwd=launch_cwd,
            argv=cmd,
            prefix=env.get("WINEPREFIX"),
            wine_executable=n.wine,
            wineserver_executable=n.wineserver,
            wine64_executable=(n.wine64 if os.path.isfile(n.wine64) else None),
            environment=env_dump,
        )

        debug("Preparing subprocess")
        out = self.log_file or None
        try:
            debug("Calling subprocess.Popen()")
            proc = subprocess.Popen(cmd, env=env, stdout=out, stderr=out, cwd=launch_cwd)
            debug("subprocess.Popen() succeeded", pid=proc.pid)
        except Exception:
            traceback.print_exc()
            raise

        if wait:
            try:
                debug("Waiting for process")
                proc.wait()
            except KeyboardInterrupt:
                proc.terminate()
            debug("Child exited", returncode=proc.returncode)
            try:
                subprocess.run([n.wineserver, "-w"], env=env, timeout=30)
            except subprocess.TimeoutExpired:
                subprocess.run([n.wineserver, "-k"], env=env)
            except Exception:
                pass
            debug("Process exited", returncode=proc.returncode)
            sys.exit(proc.returncode)

        sys.exit(0)

    # — runinprefix —
    def run_in_prefix(self, args):
        self.compatdata.setup_prefix(self)
        self._inject_base_proton()
        proc = subprocess.run([self.neutron.runner()] + list(args), env=self.env)
        sys.exit(proc.returncode)

    # — getcompatpath —
    def get_compat_path(self, args):
        unix_path = args[0] if args else ""
        result = subprocess.run(
            [self.neutron.runner(), "winepath", "-w", unix_path],
            env=self.env, capture_output=True, text=True)
        print(result.stdout.strip())
        sys.exit(result.returncode)

    # — getnativepath —
    def get_native_path(self, args):
        win_path = args[0] if args else ""
        result = subprocess.run(
            [self.neutron.runner(), "winepath", "-u", win_path],
            env=self.env, capture_output=True, text=True)
        print(result.stdout.strip())
        sys.exit(result.returncode)

    # — stop —
    def stop(self):
        subprocess.run([self.neutron.wineserver, "-k"], env=self.env)
        sys.exit(0)

    # — diag — inspect the resolved configuration without launching anything —
    def diag(self, args):
        n = self.neutron
        cd = self.compatdata
        env = self.env
        full_env = "--full-env" in args or "--all" in args

        def section(title):
            print(f"\n== {title} ==")

        def kv(key, value):
            print(f"  {key:<22} {value}")

        print("neutron diag — resolved launch configuration (no game launched)")

        section("distribution")
        kv("neutron dir", n.dir)
        kv("tool version", n.tool_version())
        kv("files dir", n.files_dir)
        for label, path in (("wine", n.wine), ("wine64", n.wine64),
                            ("wineserver", n.wineserver),
                            ("wineboot", n.wineboot)):
            state = "found" if os.path.isfile(path) else "MISSING"
            kv(label, f"[{state}] {path}")
        kv("runner", n.runner())
        kv("prefix schema",
           f"{CURRENT_PREFIX_VERSION} (from {PREFIX_VERSION_SOURCE})")
        kv("build profile",
           f"{ACTIVE_PROFILE} — {profile()['description']}")
        bi = n.build_info
        if bi:
            kv("build-info", "  ".join(f"{k}={bi[k]}" for k in
                                       ("PROFILE", "BUILD_MODE", "WAYLAND", "SOURCE")
                                       if bi.get(k)))
        kv("steam bridge",
           "lsteamclient + steam.exe built with this Wine (Proton Steam model)"
           if self.steam_bridge else
           "not built with this Wine — steamclient DLLs not installed")
        kv("steam.exe launch",
           ("yes" if self.use_steam_shim else "no") + f" — {self.steam_shim_reason}")
        xi = n.xinput_features()
        kv("sony controllers", self.sony_mode)
        kv("xinput", ", ".join(
            [name for name, on in (("GE Sony stack", xi["sony_auto"]),
                                   ("Mythix native mode", xi["glyphs"])) if on]
            ) or "stock (no Sony handling)")
        kv("display driver",
           ("wayland" if self.use_wayland else
            env.get("WINE_GRAPHICS_DRIVER", "build default"))
           + f" — {self.wayland_reason}")
        if self.use_wayland:
            kv("wayland monitor", env.get("WAYLANDDRV_PRIMARY_MONITOR", "(compositor default)"))
        # Proton-only components decide whether Steam titles can bridge at all
        comps = []
        for name, path in (
                ("lsteamclient.dll", os.path.join(n.pe_system32, "lsteamclient.dll")),
                ("lsteamclient.so", os.path.join(n.lib_dir, "wine", "x86_64-unix",
                                                 "lsteamclient.so")),
                ("steam.exe", os.path.join(n.pe_system32, "steam.exe")),
                ("vrclient_x64.dll", os.path.join(n.pe_system32, "vrclient_x64.dll")),
                ("wineopenxr.dll", os.path.join(n.pe_system32, "wineopenxr.dll"))):
            comps.append(f"{name}:{'yes' if os.path.exists(path) else 'NO'}")
        kv("proton components", "  ".join(comps))
        if not os.path.exists(os.path.join(n.pe_system32, "lsteamclient.dll")):
            kv("", "no lsteamclient in this build — Steam titles need a "
                   "base-Proton prefix (createprefix --proton) + "
                   "NEUTRON_INJECT_BASE_PROTON=1")
        if n.missing_default_prefix():
            template_state = "missing (created on first launch)"
        elif n.default_prefix_stale():
            template_state = "stale (regenerated on next launch)"
        else:
            template_state = "ready"
        kv("default_pfx", f"[{template_state}] {n.default_pfx_dir}")

        section("translation layers (bundled)")
        found = False
        for layer in TRANSLATION_LAYERS:
            for arch, _ in PREFIX_ARCH_DIRS:
                d = n.layer_dir(layer, arch)
                if not d:
                    continue
                found = True
                sub = os.path.basename(d)
                for dll in sorted(os.listdir(d)):
                    if not dll.lower().endswith(".dll"):
                        continue
                    problem = check_translation_dll(os.path.join(d, dll), arch)
                    shipped = dll.lower()[:-4] in layer.dlls
                    kv(f"{layer.name} {sub}/{dll}",
                       ("ok" if problem is None else f"BAD — {problem}")
                       + ("" if shipped else " (not in manifest, never installed)"))
        if not found:
            kv("(none)", "no bundled DXVK/VKD3D-Proton dirs under files/lib/wine")
        kv("overrides style", profile()["d3d_override"]
           + (" (wined3d: DXVK overrides off)"
              if "wined3d" in self.compat_config else ""))

        section("sync backend")
        build_ntsync = self._binary_has(n.wineserver, "ntsync")
        build_fsync = self._binary_has(n.wineserver, "fsync")
        build_esync = self._binary_has(n.wineserver, "esync")
        supported = [s for s, b in (("ntsync", build_ntsync),
                                    ("fsync", build_fsync),
                                    ("esync", build_esync)) if b]
        kv("NEUTRON_NTSYNC (knob)", os.environ.get("NEUTRON_NTSYNC", "auto"))
        kv("build supports", ", ".join(supported) or "none")
        kv("/dev/ntsync", "present" if os.path.exists("/dev/ntsync") else "absent")
        kv("WINENTSYNC", env.get("WINENTSYNC", "(unset)"))
        kv("NEUTRON_NTSYNC", env.get("NEUTRON_NTSYNC", "(unset)"))
        kv("WINEFSYNC", env.get("WINEFSYNC", "(unset)"))
        kv("WINEESYNC", env.get("WINEESYNC", "(unset)"))
        if env.get("WINENTSYNC") == "1":
            preferred = "ntsync"
        elif env.get("WINEFSYNC") == "1":
            preferred = "fsync"
        elif env.get("WINEESYNC") == "1":
            preferred = "esync"
        else:
            preferred = "none (wineserver default)"
        kv("=> preferred", preferred)

        section("compat config")
        kv("compat_config", ", ".join(sorted(self.compat_config)) or "(none)")
        kv("cmdlineappend", " ".join(self.cmdlineappend) or "(none)")
        kv("WoW64", "on" if self.use_wow64 else "off")
        kv("nvapi", "on" if self.use_nvapi else "off")
        kv("WINEDLLOVERRIDES", env.get("WINEDLLOVERRIDES", "(unset)"))

        section("nvidia / vr")
        kv("nvidia wine dlls", self.nvidia_wine_dll_dir or "(not found)")
        kv("NVIDIA_WINE_DLL_DIR", env.get("NVIDIA_WINE_DLL_DIR", "(unset)"))
        kv("PROTON_VR_RUNTIME", env.get("PROTON_VR_RUNTIME", "(unset)"))
        kv("VR_OVERRIDE", env.get("VR_OVERRIDE", "(unset)"))
        kv("XR_RUNTIME_JSON", env.get("XR_RUNTIME_JSON", "(unset)"))

        section("prefix")
        kv("STEAM_COMPAT_DATA_PATH", cd.compat_data or "(unset)")
        kv("WINEPREFIX", cd.prefix or "(unset)")
        if cd.prefix:
            initialized = os.path.isfile(os.path.join(cd.prefix, "system.reg"))
            kv("initialized", "yes" if initialized else "no")
            pfx_ver = "(none)"
            if cd.version_file and os.path.isfile(cd.version_file):
                try:
                    pfx_ver = open(cd.version_file).read().strip()
                except OSError:
                    pfx_ver = "(unreadable)"
            kv("prefix version", pfx_ver)
            tracked = "(none)"
            if cd.tracked_files_file and os.path.isfile(cd.tracked_files_file):
                try:
                    tracked = f"{sum(1 for _ in open(cd.tracked_files_file))} files"
                except OSError:
                    tracked = "(unreadable)"
            kv("tracked files", tracked)
        kv("steam root", cd.steam_root or "(unset)")

        section("container")
        containerized = in_container()
        kv("in container", "yes" if containerized else "no")
        kv("PRESSURE_VESSEL_RUNTIME",
           os.environ.get("PRESSURE_VESSEL_RUNTIME", "(unset)"))
        kv("PRESSURE_VESSEL_RUNTIME_BASE",
           os.environ.get("PRESSURE_VESSEL_RUNTIME_BASE", "(unset)"))
        kv("STEAM_RUNTIME",
           os.environ.get("STEAM_RUNTIME", "(unset)"))

        section("wrappers & runtimes")
        kv("gamemode", "will wrap" if self.gamemode_wrap else "no")
        kv("gamemoderun", shutil.which("gamemoderun") or "(not found)")
        kv("vulkaninfo", shutil.which("vulkaninfo") or "(not found)")
        kv("reflink copies", "yes" if hasattr(os, "copy_file_range") else "no")
        kv("MANGOHUD", env.get("MANGOHUD", "(unset)"))
        kv("NEUTRON_LOG", env.get("NEUTRON_LOG", "(unset)"))

        if full_env:
            section("environment (full)")
            keys = sorted(env.keys())
        else:
            section("environment (neutron-managed; pass --full-env for all)")
            managed_prefixes = ("WINE", "PROTON_", "NEUTRON_", "RADV_",
                                "__NV", "__GLX", "__VK", "__GLVND", "MANGOHUD",
                                "VR_", "OPENVR", "XR_", "STEAM",
                                "NVIDIA_", "ORIG_", "WAYLAND")
            managed_exact = {"LD_LIBRARY_PATH", "PATH", "WINEARCH",
                             "SteamAppId", "SteamGameId", "OPENCOMPOSITE_PATH"}
            keys = sorted(k for k in env
                          if k in managed_exact or k.startswith(managed_prefixes))
        for k in keys:
            print(f"  {k}={env[k]}")

        sys.exit(0)


# ── Dispatch ─────────────────────────────────────────────────────────────────
def main():
    tool_dir = os.path.dirname(os.path.realpath(__file__))
    neutron = Neutron(tool_dir)
    load_prefix_version(neutron.version_file)
    select_build_profile(CURRENT_PREFIX_VERSION)

    if not neutron.has_wine():
        die(f"Wine binary not found: {neutron.wine}")

    if in_container():
        runtime = os.environ.get("PRESSURE_VESSEL_RUNTIME", "unknown")
        log(f"running inside container (runtime: {runtime})")
    else:
        container_self_wrap()

    if len(sys.argv) < 2:
        die("Usage: neutron <verb> [args...]")

    verb = sys.argv[1]
    extra = sys.argv[2:]

    compatdata = CompatData()

    # createprefix drives a base Proton with its own minimal env, then
    # applies the Neutron overlay using a normal session environment.
    if verb == "createprefix":
        import argparse
        parser = argparse.ArgumentParser(prog="neutron createprefix")
        parser.add_argument("--proton", required=True,
                            help="Path to a base Proton installation directory")
        parsed = parser.parse_args(extra)
        session = Session(neutron, compatdata)
        session.init_session(make_prefix=True)
        compatdata.create_with_proton(session, parsed.proton)
        sys.exit(0)

    # destroyprefix removes exactly what Neutron installed (tracked files).
    if verb == "destroyprefix":
        compatdata.remove_tracked_files()
        sys.exit(0)

    # makedefaultpfx (re)creates the prefix template — handy at package time
    # so bundles can ship a prebuilt files/share/default_pfx like Proton.
    if verb == "makedefaultpfx":
        session = Session(neutron, compatdata)
        session.init_session(make_prefix=False)
        neutron.make_default_prefix(session.env, force="--force" in extra)
        log(f"default_pfx at {neutron.default_pfx_dir}")
        sys.exit(0)

    session = Session(neutron, compatdata)
    session.init_session(make_prefix=(verb != "diag"))

    if verb in ("run", "waitforexitandrun"):
        session.run(extra, wait=True)
    elif verb == "runinprefix":
        session.run_in_prefix(extra)
    elif verb == "getcompatpath":
        session.get_compat_path(extra)
    elif verb == "getnativepath":
        session.get_native_path(extra)
    elif verb == "stop":
        session.stop()
    elif verb == "diag":
        session.diag(extra)
    else:
        log(f"unknown verb '{verb}', forwarding to wine")
        session.run([verb] + extra, wait=True)


if __name__ == "__main__":
    main()
