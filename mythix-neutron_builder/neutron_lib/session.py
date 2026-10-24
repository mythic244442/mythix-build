"""Launch environment construction and process execution."""

import os
import re
import resource
import shutil
import subprocess
import sys
import traceback

from . import version
from . import components
from .common import (DEFAULT_BUILTIN_DLL_PATTERNS, debug, file_exists,
                     in_container, log, makedirs, nonzero, prepend_to_env)
from .version import profile


# ── Runtime environment construction and process execution ───────────────────
class Session:
    """Builds the launch environment and runs commands inside it."""

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
        self.use_wayland, self.wayland_reason = self._decide_wayland()

        self.components = {c.name: c for c in (cls(self) for cls in components.COMPONENTS)}

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

        # host library dirs the components need (Steam overlay, SteamVR)
        overlay_paths = [p for c in self.components.values()
                         for p in c.ld_paths()]

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

        # Steam, VR, NVIDIA, Sony pads, ...
        for c in self.components.values():
            c.apply_env(env)

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

        # MangoHud
        if env.get("MANGOHUD") == "1":
            env.setdefault("MANGOHUD_DLSYM", "1")

        # GameMode
        gamemode_available = shutil.which("gamemoderun") is not None
        use_gamemode = os.environ.get("NEUTRON_GAMEMODE", "auto")
        if use_gamemode == "auto":
            use_gamemode = "1" if gamemode_available else "0"
        self.gamemode_wrap = use_gamemode == "1" and gamemode_available

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
        overrides = {}
        for c in self.components.values():
            overrides.update(c.overrides())

        # Native Wayland driver: make sure it isn't disabled by a stale override
        if self.use_wayland:
            overrides["winewayland.drv"] = "b"

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
            and self.components["steam"].use_shim)

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
           f"{version.CURRENT_PREFIX_VERSION} (from {version.PREFIX_VERSION_SOURCE})")
        kv("build profile",
           f"{version.ACTIVE_PROFILE} — {profile()['description']}")
        bi = n.build_info
        if bi:
            kv("build-info", "  ".join(f"{k}={bi[k]}" for k in
                                       ("PROFILE", "BUILD_MODE", "WAYLAND", "SOURCE")
                                       if bi.get(k)))
        kv("display driver",
           ("wayland" if self.use_wayland else
            env.get("WINE_GRAPHICS_DRIVER", "build default"))
           + f" — {self.wayland_reason}")
        if self.use_wayland:
            kv("wayland monitor", env.get("WAYLANDDRV_PRIMARY_MONITOR", "(compositor default)"))
        if n.missing_default_prefix():
            template_state = "missing (created on first launch)"
        elif n.default_prefix_stale():
            template_state = "stale (regenerated on next launch)"
        else:
            template_state = "ready"
        kv("default_pfx", f"[{template_state}] {n.default_pfx_dir}")

        for c in self.components.values():
            section(c.title)
            c.diag(kv)

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
