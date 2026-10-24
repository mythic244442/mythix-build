"""The Neutron distribution: the Wine build, its template, its layers."""

import collections
import filecmp
import os
import shutil
import subprocess
import uuid

from . import version
from .common import FileLock, debug, die, dir_sig, log, makedirs, mtime_str
from .version import load_build_info


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
                    return f.readline().strip() == version.CURRENT_PREFIX_VERSION
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
                    f.write(version.CURRENT_PREFIX_VERSION + "\n")

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
