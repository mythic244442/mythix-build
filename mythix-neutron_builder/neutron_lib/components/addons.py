"""Wine Mono / Gecko, shared from the build instead of copied per prefix."""

import os
import shutil
import subprocess

from .. import version
from ..common import die, log
from .base import Component


def _du(path):
    total = 0
    for dirpath, _, files in os.walk(path):
        for name in files:
            try:
                total += os.lstat(os.path.join(dirpath, name)).st_blocks * 512
            except OSError:
                pass
    return total


# — Wine Mono / Gecko —
class WineAddons(Component):
    name = "addons"
    title = "wine mono / gecko"

    # what a prefix keeps of a private Mono: the runtime and its cached msi
    PRIVATE_MONO = ("drive_c/windows/mono", "drive_c/windows/Installer")

    def private_mono(self):
        """Bytes of the prefix's own Mono copy, 0 when it uses the shared one."""
        pfx = self.compatdata.prefix
        if not os.path.isdir(os.path.join(pfx, self.PRIVATE_MONO[0])):
            return 0
        return sum(_du(os.path.join(pfx, rel)) for rel in self.PRIVATE_MONO)

    def diag(self, kv):
        n = self.neutron
        for kind in ("mono", "gecko"):
            want = n.addon_version(kind)
            if not want:
                kv(kind, "(this Wine names no version)")
            elif n.shared_addon_dirs(kind):
                kv(kind, f"{want} shared from files/share/wine/{kind}")
            else:
                kv(kind, f"{want} not shipped — "
                   + ("each prefix installs its own copy" if kind == "mono"
                      else "HTML views in games stay blank"))
        size = self.private_mono()
        if size:
            hint = (" — `neutron slimprefix` frees it"
                    if n.shared_addon_dirs("mono") else "")
            kv("this prefix", f"private Mono copy, {size / 2**20:.0f} MB{hint}")
        elif os.path.isdir(self.compatdata.prefix):
            kv("this prefix", "uses the shared Mono")

    def slim(self):
        """Swap the prefix's private Mono for the shared one: uninstall the
        Wine Mono Runtime product (its files and cached msi go with it), then
        let wineboot -u put back the small support msi, exactly what a prefix
        made from a current template has. Run with the game closed."""
        n = self.neutron
        cd = self.compatdata
        env = self.session.env
        before = self.private_mono()
        if not before:
            log("this prefix already uses the shared Mono; nothing to do")
            return
        if not n.shared_addon_dirs("mono"):
            die(f"this build ships no shared Wine Mono {n.addon_version('mono')};"
                " the prefix keeps its own")
        try:
            with open(cd.version_file) as f:
                owner = f.readline().strip()
        except OSError:
            owner = "(no version file)"
        if owner != version.CURRENT_PREFIX_VERSION:
            die(f"this prefix belongs to {owner}, not "
                f"{version.CURRENT_PREFIX_VERSION}; launch the game once on "
                "this build first")

        runner = n.runner()
        with cd.lock:
            # wine's console output can land on either stream
            listing = subprocess.run([runner, "uninstaller", "--list"], env=env,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     text=True).stdout
            # "{GUID}|||Wine Mono Runtime"; the support msi comes back below
            products = [line.split("|||")[0] for line in listing.splitlines()
                        if "|||Wine Mono" in line and "Support" not in line]
            for guid in products:
                log(f"uninstalling the prefix's Wine Mono ({guid})")
                subprocess.run([runner, "msiexec", "/x", guid, "/qn"], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run([n.wineserver, "-w"], env=env)
            subprocess.run([n.wineboot, "-u"], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run([n.wineserver, "-w"], env=env)
            # an older runtime that wineboot already half-replaced can't be
            # uninstalled (its cached msi is gone) and leaves stray files
            leftover = os.path.join(cd.prefix, self.PRIVATE_MONO[0])
            if os.path.isdir(leftover) and not self._has_runtime(leftover):
                log("removing what an older Wine Mono left behind")
                shutil.rmtree(leftover)
            self._prune_tracked()

        if self.private_mono():
            die(f"{os.path.join(cd.prefix, self.PRIVATE_MONO[0])} is still there"
                f" ({len(products)} Mono product(s) uninstalled); left as is")
        freed = before - _du(os.path.join(cd.prefix, self.PRIVATE_MONO[1]))
        log(f"prefix now uses the shared Mono; freed {freed / 2**20:.0f} MB")

    @staticmethod
    def _has_runtime(mono_dir):
        """True when mono_dir still holds a Mono runtime mscoree would load."""
        bin_dir = os.path.join(mono_dir, "mono-2.0", "bin")
        return any(os.path.isfile(os.path.join(bin_dir, name)) for name in
                   ("libmono-2.0-x86_64.dll", "libmono-2.0.dll", "mono-2.0.dll"))

    def _prune_tracked(self):
        """Drop tracked_files entries for the Mono files the uninstall took."""
        tf = self.compatdata.tracked_files_file
        try:
            with open(tf) as f:
                lines = f.readlines()
        except OSError:
            return
        keep = [line for line in lines
                if not line.startswith(self.PRIVATE_MONO)
                or os.path.lexists(os.path.join(self.compatdata.prefix,
                                                line.strip()))]
        if len(keep) != len(lines):
            with open(tf, "w") as f:
                f.writelines(keep)
