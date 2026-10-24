"""NVIDIA driver Wine DLLs (nvngx/DLSS) and PRIME offload."""

import os
from ctypes import (CDLL, POINTER, Structure, addressof, c_char_p, c_int, c_void_p, cast)

from ..common import file_exists, log, try_copy
from .base import Component


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


# — NVIDIA: the driver's own Wine DLLs (nvngx for DLSS), PRIME offload —
class Nvidia(Component):
    name = "nvidia"
    title = "nvidia"

    def __init__(self, session):
        super().__init__(session)
        self.dll_dir = find_nvidia_wine_dll_dir()

    def apply_env(self, env):
        # NGX/DLSS fallback discovery
        if self.dll_dir:
            env.setdefault("NVIDIA_WINE_DLL_DIR", self.dll_dir)
        if os.environ.get("NEUTRON_PRIME_RENDER_OFFLOAD") == "1":
            env.setdefault("__NV_PRIME_RENDER_OFFLOAD", "1")
            env.setdefault("__GLX_VENDOR_LIBRARY_NAME", "nvidia")
            env.setdefault("__VK_LAYER_NV_optimus", "NVIDIA_only")

    def install(self, track_file):
        if not self.dll_dir:
            return
        log("installing NVIDIA nvngx DLLs...")
        for dll in ("_nvngx.dll", "nvngx.dll"):
            src = os.path.join(self.dll_dir, dll)
            if file_exists(src, follow_symlinks=True):
                try_copy(src, "drive_c/windows/system32",
                         prefix=self.compatdata.prefix,
                         track_file=track_file, optional=True)

    def diag(self, kv):
        kv("nvidia wine dlls", self.dll_dir or "(not found)")
        kv("NVIDIA_WINE_DLL_DIR",
           self.session.env.get("NVIDIA_WINE_DLL_DIR", "(unset)"))
        kv("PRIME offload",
           "on" if os.environ.get("NEUTRON_PRIME_RENDER_OFFLOAD") == "1" else "off")
