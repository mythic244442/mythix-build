"""Logging, file/env helpers, reflink copies, PE probes, locks, container."""

import errno
import fcntl
import os
import shutil
import stat
import subprocess
import sys


def debug(stage, **kwargs):
    if os.getenv("NEUTRON_DEBUG", "0") != "1":
        return

    print(f"[NEUTRON] {stage}")

    for k, v in kwargs.items():
        print(f"    {k}: {v}")


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


def container_self_wrap(script_path):
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

    cmd = [run_script, "--", sys.executable, script_path] + sys.argv[1:]
    os.execv(run_script, cmd)


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
