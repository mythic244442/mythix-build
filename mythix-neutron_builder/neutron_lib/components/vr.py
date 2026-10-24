"""SteamVR / OpenVR / OpenXR."""

import json
import os

from ..common import file_exists, makedirs, try_copy
from .base import Component


# — SteamVR / OpenVR / OpenXR —
# Only a build that ships its own vrclient (both halves) may run one: another
# tool's copy left in the prefix crashes against our Wine as soon as DXVK's
# openvr bridge loads it (Cyberpunk exit code 3, 2026-10-19).
class VR(Component):
    name = "vr"
    title = "vr"

    OPENXR_RUNTIMES = [
        "/usr/share/openxr/1/openxr_monado.json",
        "/etc/openxr/1/active_runtime.json",
    ]
    # what a VR-capable tool leaves in a prefix
    VR_FILES = (
        "drive_c/windows/system32/vrclient_x64.dll",
        "drive_c/windows/syswow64/vrclient.dll",
        "drive_c/vrclient/bin/vrclient_x64.dll",
        "drive_c/vrclient/bin/vrclient.dll",
        "drive_c/users/steamuser/AppData/Local/openvr/openvrpaths.vrpath",
    )

    def __init__(self, session):
        super().__init__(session)
        self.steamvr_home = ""
        root = self.compatdata.steam_root
        if root:
            candidate = os.path.join(root, "steamapps", "common", "SteamVR")
            if os.path.isdir(candidate):
                self.steamvr_home = candidate

    @property
    def available(self):
        return self.neutron.has_vrclient()

    def ld_paths(self):
        if not self.steamvr_home:
            return []
        return [os.path.join(self.steamvr_home, "bin", "linux64"),
                os.path.join(self.steamvr_home, "bin")]

    def apply_env(self, env):
        if self.steamvr_home:
            env.setdefault("VR_OVERRIDE", self.steamvr_home)
            vrclient = os.path.join(self.steamvr_home, "bin", "linux64",
                                    "vrclient.so")
            if os.path.isfile(vrclient):
                env.setdefault("OPENVR_RUNTIME", vrclient)
        for runtime in self.OPENXR_RUNTIMES:
            if os.path.isfile(runtime):
                env.setdefault("XR_RUNTIME_JSON", runtime)
                break
        if env.get("NEUTRON_VR_DEBUG") == "1":
            env["WINEDEBUG"] = "+timestamp,+vrclient,+openxr"
            env["DXVK_LOG_LEVEL"] = "info"

    def overrides(self):
        # the atom container's Proton leaves its own vrclient behind too
        if os.environ.get("NEUTRON_ATOM_PROTON") or not self.available:
            return {"vrclient": "", "vrclient_x64": ""}
        return {}

    def install(self, track_file):
        n, cd = self.neutron, self.compatdata
        vrclient_dir = "drive_c/vrclient/bin"
        for src in (os.path.join(n.pe_system32, "vrclient_x64.dll"),
                    os.path.join(n.pe_syswow64, "vrclient.dll")):
            if file_exists(src, follow_symlinks=True):
                makedirs(os.path.join(cd.prefix, vrclient_dir))
                try_copy(src, vrclient_dir, prefix=cd.prefix,
                         track_file=track_file, optional=True)

    def stray_files(self):
        return () if self.available else self.VR_FILES

    def per_launch(self):
        """Rewrite openvrpaths.vrpath into the prefix, capture the runtime.
        Without a vrclient of our own a vrpath would only lead DXVK's openvr
        bridge to one (the sweep keeps other tools' copies out)."""
        if not self.available:
            return
        env = self.session.env
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
        dst_dir = os.path.join(self.compatdata.prefix,
                               "drive_c/users/steamuser/AppData/Local/openvr")
        makedirs(dst_dir)
        try:
            with open(os.path.join(dst_dir, "openvrpaths.vrpath"), "w") as f:
                json.dump(contents, f, indent=3)
        except OSError:
            pass

    def diag(self, kv):
        n, env = self.neutron, self.session.env
        kv("vrclient", "shipped by this build" if self.available else
           "not shipped — foreign vrclients disabled and swept "
           "(NEUTRON_FORCE_VR=1 trusts them)")
        kv("wineopenxr.dll",
           "yes" if os.path.exists(os.path.join(n.pe_system32, "wineopenxr.dll"))
           else "NO")
        kv("PROTON_VR_RUNTIME", env.get("PROTON_VR_RUNTIME", "(unset)"))
        kv("VR_OVERRIDE", env.get("VR_OVERRIDE", "(unset)"))
        kv("XR_RUNTIME_JSON", env.get("XR_RUNTIME_JSON", "(unset)"))
