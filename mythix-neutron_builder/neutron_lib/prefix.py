"""The Steam compatdata directory and its Wine prefix."""

import array
import fcntl
import fnmatch
import os
import re
import shutil
import subprocess
import uuid

from . import version
from .common import (EXT2_IOC_GETFLAGS, EXT2_IOC_SETFLAGS, EXT4_CASEFOLD_FL,
                     FileLock, WINE_BUILTIN_LINK_DIRS, die, dir_sig,
                     file_exists, file_is_wine_builtin_dll, log, makedirs,
                     mtime_str, try_copy)
from .dist import PREFIX_ARCH_DIRS, TRANSLATION_LAYERS
from .version import parse_prefix_version


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
    # The order is part of the prefix format: reordering it makes every
    # existing prefix re-overlay once.
    def _compute_config_info(self, session):
        n = session.neutron
        cc = session.compat_config
        return "\n".join((
            version.CURRENT_PREFIX_VERSION,
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
            str(bool(session.components["nvidia"].dll_dir)),
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

    def _sweep_foreign_files(self, session):
        own = os.path.realpath(session.neutron.dir) + os.sep
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
        for c in session.components.values():
            for rel in c.stray_files():
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
        if old_ver == version.CURRENT_PREFIX_VERSION:
            return

        if old_ver is None:
            log(f"Initializing Neutron prefix "
                f"({version.CURRENT_PREFIX_VERSION}) ({self.compat_data})")
            return  # fresh prefix, nothing to migrate

        log(f"Neutron: upgrading prefix from {old_ver} to "
            f"{version.CURRENT_PREFIX_VERSION} ({self.compat_data})")

        old = parse_prefix_version(old_ver)
        new = parse_prefix_version(version.CURRENT_PREFIX_VERSION)
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

    # — each component's files, appended to the manifest —
    def _overlay_extras(self, session, track_file):
        for c in session.components.values():
            c.install(track_file)

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
            swept = not first_init and self._sweep_foreign_files(session)

            # versioned DLL overlay — only when something relevant changed
            config_info = self._compute_config_info(session)
            old_config = ""
            if os.path.isfile(self.config_info_file):
                try:
                    old_config = open(self.config_info_file).read()
                except OSError:
                    pass

            if first_init or swept or old_ver != version.CURRENT_PREFIX_VERSION \
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
                f.write(version.CURRENT_PREFIX_VERSION + "\n")

            # cheap per-launch wiring
            self._setup_drives(session)
            for c in session.components.values():
                c.per_launch()
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
                f.write(version.CURRENT_PREFIX_VERSION + "\n")

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
