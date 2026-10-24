"""Steam client DLLs, lsteamclient, steam.exe launches."""

import os

from ..common import log, makedirs, try_copy
from .base import Component


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


# — Steam: the client's DLLs in the prefix, lsteamclient, steam.exe launches —
class Steam(Component):
    name = "steam"
    title = "steam"

    STEAM_DIR = "drive_c/Program Files (x86)/Steam/"

    def __init__(self, session):
        super().__init__(session)
        # lsteamclient + steam.exe built with this Wine → Proton's Steam model
        self.bridge = self.neutron.build_info.get("STEAM_BRIDGE") == "ge"
        self.use_shim, self.shim_reason = self._decide_shim()

    def _decide_shim(self):
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
        if not self.bridge:
            return False, "build has no Steam bridge"
        env = self.session.env
        appid = env.get("SteamGameId") or env.get("SteamAppId") or ""
        if not (appid.isascii() and appid.isdigit() and int(appid) > 0):
            return False, f"no Steam app id ({appid or 'unset'}): direct launch"
        if not steam_client_running():
            return False, "Steam client not running: direct launch"
        return True, f"Steam app {appid}"

    def ld_paths(self):
        root = self.compatdata.steam_root
        if not root:
            return []
        return [os.path.join(root, "ubuntu12_64"),
                os.path.join(root, "ubuntu12_32")]

    def apply_env(self, env):
        app_id = os.environ.get("SteamAppId", "")
        if app_id:
            env.setdefault("SteamAppId", app_id)
            env.setdefault("SteamGameId", os.environ.get("SteamGameId", app_id))

    def overrides(self):
        o = {}
        if self.compatdata.compat_data:
            o["lsteamclient"] = "n,b"
        # Proton's steam.exe helper (registers the Steam client for the game)
        if self.bridge:
            o["steam.exe"] = "b"
        return o

    def install(self, track_file):
        log("installing Steam client DLLs...")
        cd = self.compatdata
        if not cd.steam_root:
            return
        makedirs(os.path.join(cd.prefix, self.STEAM_DIR))
        legacy = os.path.join(cd.steam_root, "legacycompat")
        # steamclient{,64}.dll are not part of the overlay: see
        # ensure_steamclient_dlls (steam.exe launches only).
        copies = [
            ("GameOverlayRenderer64.dll", "GameOverlayRenderer64.dll"),
            ("GameOverlayRenderer.dll", "GameOverlayRenderer.dll"),
            ("SteamService.exe", "steam.exe"),
            ("Steam.dll", "Steam.dll"),
        ]
        for src_name, dst_name in copies:
            src = os.path.join(legacy, src_name)
            if os.path.isfile(src):
                try_copy(src, self.STEAM_DIR + dst_name, prefix=cd.prefix,
                         track_file=track_file)

    def per_launch(self):
        if self.use_shim and self.bridge:
            self.ensure_steamclient_dlls()

    def ensure_steamclient_dlls(self):
        """Valve's ntdll trampolines Steam's steamclient{,64}.dll into
        lsteamclient, so they only work with an lsteamclient built for this
        exact Wine (STEAM_BRIDGE=ge builds). With a mismatched one they crash
        (the old Cyberpunk 2077 access violation). Installed per launch, only
        when the launch goes through steam.exe, and refreshed after Steam
        updates them."""
        cd = self.compatdata
        if not cd.steam_root:
            return
        legacy = os.path.join(cd.steam_root, "legacycompat")
        makedirs(os.path.join(cd.prefix, self.STEAM_DIR))
        with open(cd.tracked_files_file, "a") as tf:
            for name in ("steamclient.dll", "steamclient64.dll"):
                src = os.path.join(legacy, name)
                dst = os.path.join(cd.prefix, self.STEAM_DIR, name)
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
                try_copy(src, self.STEAM_DIR + name, prefix=cd.prefix,
                         track_file=tf)

    def diag(self, kv):
        n = self.neutron
        kv("steam bridge",
           "lsteamclient + steam.exe built with this Wine (Proton Steam model)"
           if self.bridge else
           "not built with this Wine — steamclient DLLs not installed")
        kv("steam.exe launch",
           ("yes" if self.use_shim else "no") + f" — {self.shim_reason}")
        # Proton-only components decide whether Steam titles can bridge at all
        comps = []
        for name, path in (
                ("lsteamclient.dll", os.path.join(n.pe_system32, "lsteamclient.dll")),
                ("lsteamclient.so", os.path.join(n.unix_dir, "lsteamclient.so")),
                ("steam.exe", os.path.join(n.pe_system32, "steam.exe"))):
            comps.append(f"{name}:{'yes' if os.path.exists(path) else 'NO'}")
        kv("proton components", "  ".join(comps))
        if not os.path.exists(os.path.join(n.pe_system32, "lsteamclient.dll")):
            kv("", "no lsteamclient in this build — Steam titles need a "
                   "base-Proton prefix (createprefix --proton) + "
                   "NEUTRON_INJECT_BASE_PROTON=1")
        kv("steam root", self.compatdata.steam_root or "(unset)")
