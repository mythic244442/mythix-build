"""Launcher decisions that depend on the host: steam.exe launches and Sony pads.

Every package ships the `neutron` entry script (neutron.py here) with the
neutron_lib/ package next to it; the tests import neutron_lib from the
builder directory the same way the entry script does.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

BUILDER = Path(__file__).resolve().parent.parent / "mythix-neutron_builder"
NEUTRON_PY = BUILDER / "neutron.py"
LAUNCHER_SOURCES = [NEUTRON_PY, *sorted((BUILDER / "neutron_lib").rglob("*.py"))]


@pytest.fixture(scope="module")
def neutron_mod():
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(BUILDER))
    from neutron_lib import components, dist, prefix, session
    from neutron_lib.components import steam
    # classes by name; patch hooks on the module that looks them up
    return SimpleNamespace(
        Neutron=dist.Neutron, CompatData=prefix.CompatData, Session=session.Session,
        TRANSLATION_LAYERS=dist.TRANSLATION_LAYERS, Component=components.Component,
        components=components, steam=steam)


def make_package(root: Path, build_info: str = "", xinput: bytes | None = None) -> Path:
    pkg = root / "pkg"
    (pkg / "files" / "lib" / "wine" / "x86_64-windows").mkdir(parents=True)
    (pkg / "version").write_text("1 Mythix-Neutron-11.19-3\n")
    (pkg / "build-info").write_text(build_info)
    if xinput is not None:
        (pkg / "files" / "lib" / "wine" / "x86_64-windows" / "xinput1_3.dll").write_bytes(xinput)
    return pkg


@pytest.fixture
def session_for(neutron_mod, tmp_path, monkeypatch):
    """Build a Session for a fake package, with a clean launch environment."""
    for key in ("SteamGameId", "SteamAppId", "NEUTRON_USE_STEAM_SHIM",
                "MYTHIX_DS4_GLYPHS", "PROTON_SONY_AUTO_XINPUT", "WAYLAND_DISPLAY",
                "NEUTRON_WAYLAND", "STEAM_COMPAT_CONFIG", "NEUTRON_CONFIG"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv("STEAM_COMPAT_DATA_PATH", str(tmp_path / "compatdata"))
    (tmp_path / "compatdata").mkdir()

    def build(build_info="", xinput=None, **env):
        for key, value in env.items():
            monkeypatch.setenv(key, value)
        pkg = make_package(tmp_path, build_info, xinput)
        neutron = neutron_mod.Neutron(str(pkg))
        return neutron_mod.Session(neutron, neutron_mod.CompatData())

    return build


BRIDGE = "STEAM_BRIDGE=ge\nWAYLAND=1\n"


# ── steam.exe launches ──────────────────────────────────────────────────────

def test_mythix_launcher_hex_id_launches_directly(session_for, neutron_mod, monkeypatch):
    monkeypatch.setattr(neutron_mod.steam, "steam_client_running", lambda: True)
    s = session_for(BRIDGE, SteamGameId="78da8e29", SteamAppId="78da8e29")
    assert not s.components["steam"].use_shim
    assert "78da8e29" in s.components["steam"].shim_reason


def test_steam_app_without_steam_client_launches_directly(session_for, neutron_mod, monkeypatch):
    monkeypatch.setattr(neutron_mod.steam, "steam_client_running", lambda: False)
    s = session_for(BRIDGE, SteamGameId="1091500")
    assert not s.components["steam"].use_shim
    assert "not running" in s.components["steam"].shim_reason


def test_steam_app_with_steam_client_uses_steam_exe(session_for, neutron_mod, monkeypatch):
    monkeypatch.setattr(neutron_mod.steam, "steam_client_running", lambda: True)
    s = session_for(BRIDGE, SteamGameId="1091500")
    assert s.components["steam"].use_shim


def test_no_bridge_build_never_auto_uses_steam_exe(session_for, neutron_mod, monkeypatch):
    monkeypatch.setattr(neutron_mod.steam, "steam_client_running", lambda: True)
    s = session_for("WAYLAND=1\n", SteamGameId="1091500")
    assert not s.components["steam"].use_shim


@pytest.mark.parametrize(("knob", "expected"), [("0", False), ("1", True)])
def test_shim_knob_overrides(session_for, neutron_mod, monkeypatch, knob, expected):
    monkeypatch.setattr(neutron_mod.steam, "steam_client_running", lambda: not expected)
    s = session_for(BRIDGE, SteamGameId="1091500", NEUTRON_USE_STEAM_SHIM=knob)
    assert s.components["steam"].use_shim is expected


def test_steam_client_running_reads_pid_file(neutron_mod, tmp_path, monkeypatch):
    home = tmp_path / "home"
    (home / ".steam").mkdir(parents=True)
    monkeypatch.setenv("HOME", str(home))
    assert not neutron_mod.steam.steam_client_running()          # no pid file

    fake_steam = tmp_path / "steam"                         # /proc/<pid>/comm == "steam"
    fake_steam.symlink_to(Path(sys.executable).resolve())
    proc = subprocess.Popen([str(fake_steam), "-c", "import time; time.sleep(30)"])
    try:
        (home / ".steam" / "steam.pid").write_text(f"{proc.pid}\n")
        assert neutron_mod.steam.steam_client_running()
        (home / ".steam" / "steam.pid").write_text(f"{os.getpid()}\n")   # not steam
        assert not neutron_mod.steam.steam_client_running()
    finally:
        proc.kill()
        proc.wait()


# ── DualShock 4 / DualSense ─────────────────────────────────────────────────

GE_XINPUT = b"MZ...PROTON_SONY_AUTO_XINPUT...MYTHIX_DS4_GLYPHS..."   # 11.19-3+ xinput
LUNA_XINPUT = b"MZ...MYTHIX_DS4_GLYPHS..."                          # Neutron-11.0 xinput
STOCK_XINPUT = b"MZ..."


def test_ge_xinput_defaults_to_sony_fallback(session_for):
    s = session_for(BRIDGE, GE_XINPUT)
    s.components["sony"].apply_env(s.env)
    assert s.env["PROTON_SONY_AUTO_XINPUT"] == "1"


def test_glyph_mode_keeps_sony_native(session_for):
    s = session_for(BRIDGE, GE_XINPUT, MYTHIX_DS4_GLYPHS="1")
    s.components["sony"].apply_env(s.env)
    assert "PROTON_SONY_AUTO_XINPUT" not in s.env
    assert s.components["sony"].mode.startswith("native PlayStation")


def test_user_choice_is_kept(session_for):
    s = session_for(BRIDGE, GE_XINPUT, PROTON_SONY_AUTO_XINPUT="0")
    s.components["sony"].apply_env(s.env)
    assert s.env["PROTON_SONY_AUTO_XINPUT"] == "0"


@pytest.mark.parametrize("xinput", [LUNA_XINPUT, STOCK_XINPUT, None])
def test_other_xinputs_are_left_alone(session_for, xinput):
    s = session_for(BRIDGE, xinput)
    s.components["sony"].apply_env(s.env)
    assert "PROTON_SONY_AUTO_XINPUT" not in s.env


# ── steamclient DLLs for steam.exe launches ─────────────────────────────────

def test_steamclient_dlls_installed_and_refreshed(session_for, tmp_path):
    steam = tmp_path / "steam"
    (steam / "legacycompat").mkdir(parents=True)
    for name in ("steamclient.dll", "steamclient64.dll"):
        (steam / "legacycompat" / name).write_bytes(b"MZ" + name.encode())
    s = session_for(BRIDGE, STEAM_COMPAT_CLIENT_INSTALL_PATH=str(steam))
    (tmp_path / "compatdata" / "pfx").mkdir()

    steam_c = s.components["steam"]
    steam_c.ensure_steamclient_dlls()
    dst = tmp_path / "compatdata" / "pfx" / "drive_c" / "Program Files (x86)" / "Steam"
    assert (dst / "steamclient64.dll").read_bytes() == b"MZsteamclient64.dll"
    tracked = (tmp_path / "compatdata" / "tracked_files").read_text().splitlines()
    assert "drive_c/Program Files (x86)/Steam/steamclient64.dll" in tracked

    # unchanged source → left alone; a Steam update → refreshed
    before = (dst / "steamclient.dll").stat().st_ino
    steam_c.ensure_steamclient_dlls()
    assert (dst / "steamclient.dll").stat().st_ino == before
    src = steam / "legacycompat" / "steamclient.dll"
    src.write_bytes(b"MZ-updated")
    os.utime(src, (src.stat().st_atime, src.stat().st_mtime + 60))
    steam_c.ensure_steamclient_dlls()
    assert (dst / "steamclient.dll").read_bytes() == b"MZ-updated"
    assert len((tmp_path / "compatdata" / "tracked_files").read_text().splitlines()) == 2


# ── vrclient DLL overrides ───────────────────────────────────────────────────
# A vrclient left in the prefix by another tool (e.g. a Proton run symlinking
# its own) asserts at startup because Neutron never sets up Proton's OpenVR
# registry state — the game dies with exit code 3 (Cyberpunk, 2026-10-19).
# Only a build that ships its own vrclient may run one.

def test_foreign_vrclient_disabled_when_build_ships_none(session_for):
    s = session_for(BRIDGE)
    s._build_dll_overrides()
    combined = s.env.get("WINEDLLOVERRIDES", "")
    assert "vrclient=" in combined
    assert "vrclient_x64=" in combined


def ship_vrclient(neutron, unix=True):
    (Path(neutron.pe_system32) / "vrclient_x64.dll").write_bytes(b"MZvrclient")
    if unix:
        Path(neutron.unix_dir).mkdir(parents=True, exist_ok=True)
        (Path(neutron.unix_dir) / "vrclient.so").write_bytes(b"\x7fELF")


def test_own_vrclient_stays_enabled(session_for):
    s = session_for(BRIDGE)
    ship_vrclient(s.neutron)
    s._build_dll_overrides()
    combined = s.env.get("WINEDLLOVERRIDES", "")
    assert "vrclient=" not in combined
    assert "vrclient_x64=" not in combined


def test_vrclient_without_unix_half_is_disabled(session_for):
    s = session_for(BRIDGE)
    ship_vrclient(s.neutron, unix=False)
    s._build_dll_overrides()
    assert "vrclient_x64=" in s.env.get("WINEDLLOVERRIDES", "")


# ── foreign-tool sweep ──────────────────────────────────────────────────────
# A Proton run symlinks its DLLs into the prefix, pointing into its own
# lib/wine. Names our template doesn't cover survive every overlay, so the
# sweep moves them (and a foreign vrclient/vrpath) to foreign-quarantine.

def poison_prefix(s, tmp_path):
    pfx = Path(s.compatdata.prefix) / "drive_c"
    sys32, wow = pfx / "windows" / "system32", pfx / "windows" / "syswow64"
    sys32.mkdir(parents=True)
    wow.mkdir(parents=True)
    other = tmp_path / "GE-Proton" / "files" / "lib" / "wine"
    (other / "x86_64-windows").mkdir(parents=True)
    (other / "x86_64-windows" / "protontts.dll").write_bytes(b"MZ")
    (sys32 / "protontts.dll").symlink_to(other / "x86_64-windows" / "protontts.dll")
    (wow / "winscard.dll").symlink_to(tmp_path / "gone" / "lib" / "wine" / "i386-windows" / "winscard.dll")
    ours = Path(s.neutron.pe_system32) / "kernel32.dll"
    ours.write_bytes(b"MZ")
    (sys32 / "kernel32.dll").symlink_to(ours)
    (sys32 / "d3d11.dll").write_bytes(b"MZuser")
    (pfx / "vrclient" / "bin").mkdir(parents=True)
    (pfx / "vrclient" / "bin" / "vrclient_x64.dll").write_bytes(b"MZ")
    return pfx


def test_sweep_quarantines_foreign_files(session_for, tmp_path):
    s = session_for(BRIDGE)
    pfx = poison_prefix(s, tmp_path)
    assert s.compatdata._sweep_foreign_files(s) is True
    quarantine = Path(s.compatdata.quarantine_dir) / "drive_c"
    for rel in ("windows/system32/protontts.dll", "windows/syswow64/winscard.dll",
                "vrclient/bin/vrclient_x64.dll"):
        assert not os.path.lexists(pfx / rel)
        assert os.path.lexists(quarantine / rel)
    # our own links and user-native DLLs stay; a second pass has nothing to do
    assert (pfx / "windows" / "system32" / "kernel32.dll").is_symlink()
    assert (pfx / "windows" / "system32" / "d3d11.dll").read_bytes() == b"MZuser"
    assert s.compatdata._sweep_foreign_files(s) is False


def test_sweep_keeps_vrclient_when_build_ships_one(session_for, tmp_path):
    s = session_for(BRIDGE)
    ship_vrclient(s.neutron)
    pfx = poison_prefix(s, tmp_path)
    s.compatdata._sweep_foreign_files(s)
    assert (pfx / "vrclient" / "bin" / "vrclient_x64.dll").exists()


# ── template diet ───────────────────────────────────────────────────────────
# Byte-identical builtins in the template become relative links into lib/wine,
# so clones stop duplicating ~500 MB; anything that differs stays a real file.

def test_template_builtins_become_links(session_for):
    s = session_for(BRIDGE)
    n = s.neutron
    Path(n.pe_syswow64).mkdir(parents=True, exist_ok=True)
    (Path(n.pe_system32) / "kernel32.dll").write_bytes(b"MZ64")
    (Path(n.pe_syswow64) / "kernel32.dll").write_bytes(b"MZ32")
    (Path(n.pe_system32) / "ddraw.dll").write_bytes(b"MZbuiltin")
    win = Path(n.default_pfx_dir) / "drive_c" / "windows"
    (win / "system32" / "drivers").mkdir(parents=True)
    (win / "syswow64").mkdir(parents=True)
    (win / "system32" / "kernel32.dll").write_bytes(b"MZ64")
    (win / "syswow64" / "kernel32.dll").write_bytes(b"MZ32")
    (win / "system32" / "ddraw.dll").write_bytes(b"MZnative")
    (win / "system32" / "notes.txt").write_text("x")

    assert n._link_template_builtins(n.default_pfx_dir) == 2
    for sub in ("system32", "syswow64"):
        link = win / sub / "kernel32.dll"
        assert link.is_symlink() and not os.path.isabs(os.readlink(link))
    assert (win / "syswow64" / "kernel32.dll").read_bytes() == b"MZ32"
    assert not (win / "system32" / "ddraw.dll").is_symlink()
    assert not (win / "system32" / "notes.txt").is_symlink()
    assert (Path(n.default_pfx_dir) / n._BUILTINS_LINKED).read_text() == "2\n"


# ── shared Wine Mono / Gecko ────────────────────────────────────────────────
# Unpacked once under files/share/wine like Proton; the versions are the ones
# the build's appwiz.cpl names, and a prefix's private Mono can be dropped.

def ship_appwiz(neutron):
    names = "\0".join(("wine-gecko-2.47.4-x86_64.msi", "gecko",
                       "wine-mono-10.4.1-x86.msi", "mono"))
    (Path(neutron.pe_system32) / "appwiz.cpl").write_bytes(
        b"MZ\0\0" + names.encode("utf-16-le"))


def ship_addons(neutron, *names):
    for name in names:
        kind = name.split("-")[1]
        (Path(neutron.share_dir) / "wine" / kind / name).mkdir(parents=True)


def test_addon_versions_come_from_appwiz(session_for):
    n = session_for(BRIDGE).neutron
    assert n.addon_version("mono") is None and n.shared_addon_dirs("mono") == []
    ship_appwiz(n)
    n = type(n)(n.dir)                                # versions are cached
    assert (n.addon_version("mono"), n.addon_version("gecko")) == ("10.4.1", "2.47.4")
    ship_addons(n, "wine-mono-9.3.1", "wine-gecko-2.47.4-x86_64")
    assert n.shared_addon_dirs("mono") == []          # not the version Wine wants
    assert n.shared_addon_dirs("gecko") == []         # needs both arches
    ship_addons(n, "wine-mono-10.4.1", "wine-gecko-2.47.4-x86")
    assert [Path(d).name for d in n.shared_addon_dirs("mono")] == ["wine-mono-10.4.1"]
    assert len(n.shared_addon_dirs("gecko")) == 2


def test_template_with_private_mono_is_regenerated(session_for):
    from neutron_lib import version
    n = session_for(BRIDGE).neutron
    ship_appwiz(n)
    pfx = Path(n.default_pfx_dir)
    (pfx / "drive_c" / "windows" / "mono" / "mono-2.0").mkdir(parents=True)
    (pfx / "dosdevices").mkdir()
    for reg in ("system.reg", "user.reg", "userdef.reg"):
        (pfx / reg).write_text("")
    (pfx / n._DEFAULT_PFX_STAMP).write_text(version.CURRENT_PREFIX_VERSION + "\n")
    os.utime(pfx / "system.reg", (2**31, 2**31))      # newer than the build
    assert not n.default_prefix_stale()
    ship_addons(n, "wine-mono-10.4.1")
    assert n.default_prefix_stale()


FAKE_WINE = """#!/bin/sh
# uninstaller --list / msiexec /x / wineboot -u, as far as slimprefix needs
win="$WINEPREFIX/drive_c/windows"
case "$1 $2" in
"uninstaller --list")
    echo "{C6477445}|||Wine Mono Runtime" >&2
    echo "{0591009C}|||Wine Mono Windows Support" >&2 ;;
"msiexec /x") rm -rf "$win/mono" "$win/Installer/runtime.msi" ;;
"-u ") echo support > "$win/Installer/support.msi" ;;
esac
"""


def private_mono_prefix(pkg, cd, owner):
    for name, body in (("wine", FAKE_WINE), ("wineboot", FAKE_WINE.replace(
            'case "$1 $2"', 'case "$1 "')), ("wineserver", "#!/bin/sh\n")):
        (pkg / "files" / "bin" / name).write_text(body)
        (pkg / "files" / "bin" / name).chmod(0o755)
    win = cd / "pfx" / "drive_c" / "windows"
    (win / "mono" / "mono-2.0" / "bin").mkdir(parents=True)
    (win / "mono" / "mono-2.0" / "bin" / "libmono-2.0-x86_64.dll").write_bytes(b"MZ")
    (win / "mono" / "mono-2.0" / "mscorlib.dll").write_bytes(b"x" * 65536)
    (win / "Installer").mkdir()
    (win / "Installer" / "runtime.msi").write_bytes(b"x" * 65536)
    (cd / "version").write_text(owner + "\n")
    (cd / "tracked_files").write_text("system.reg\ndrive_c/windows/mono/\n"
                                      "drive_c/windows/mono/mono-2.0/mscorlib.dll\n"
                                      "drive_c/windows/Installer/\n")
    return win


def test_slimprefix_swaps_private_mono_for_shared(tmp_path):
    pkg = install_tool(tmp_path, fallback="Mythix-Neutron-11.19-9")
    cd = tmp_path / "game"
    win = private_mono_prefix(pkg, cd, "Mythix-Neutron-11.19-9")

    r = run_tool(pkg, tmp_path, "slimprefix", str(cd))
    assert r.returncode != 0 and "no shared Wine Mono" in r.stderr
    assert (win / "mono").is_dir()

    ship_appwiz(SimpleNamespace(pe_system32=pkg / "files/lib/wine/x86_64-windows"))
    ship_addons(SimpleNamespace(share_dir=pkg / "files/share"), "wine-mono-10.4.1")
    r = run_tool(pkg, tmp_path, "diag")
    assert "10.4.1 shared from files/share/wine/mono" in r.stdout
    r = run_tool(pkg, tmp_path, "slimprefix", str(cd))
    assert r.returncode == 0, r.stderr
    assert not (win / "mono").exists()
    assert sorted(os.listdir(win / "Installer")) == ["support.msi"]
    assert (cd / "tracked_files").read_text() == "system.reg\ndrive_c/windows/Installer/\n"
    assert "uses the shared Mono" in run_tool(pkg, tmp_path, "slimprefix", str(cd)).stderr


def test_slimprefix_clears_a_half_replaced_runtime(tmp_path):
    # wineboot already moved the runtime out; only strays and a registry
    # entry whose msi is gone remain, so the uninstall removes nothing
    pkg = install_tool(tmp_path, fallback="Mythix-Neutron-11.19-9")
    ship_appwiz(SimpleNamespace(pe_system32=pkg / "files/lib/wine/x86_64-windows"))
    ship_addons(SimpleNamespace(share_dir=pkg / "files/share"), "wine-mono-10.4.1")
    cd = tmp_path / "game"
    win = private_mono_prefix(pkg, cd, "Mythix-Neutron-11.19-9")
    wine = pkg / "files" / "bin" / "wine"
    wine.write_text(wine.read_text().replace('rm -rf "$win/mono" ', ""))
    shutil.rmtree(win / "mono" / "mono-2.0" / "bin")
    r = run_tool(pkg, tmp_path, "slimprefix", str(cd))
    assert r.returncode == 0, r.stderr
    assert not (win / "mono").exists()


def test_slimprefix_leaves_other_builds_prefixes_alone(tmp_path):
    pkg = install_tool(tmp_path, fallback="Mythix-Neutron-11.19-9")
    ship_appwiz(SimpleNamespace(pe_system32=pkg / "files/lib/wine/x86_64-windows"))
    ship_addons(SimpleNamespace(share_dir=pkg / "files/share"), "wine-mono-10.4.1")
    cd = tmp_path / "game"
    win = private_mono_prefix(pkg, cd, "GE-Proton10-23")
    r = run_tool(pkg, tmp_path, "slimprefix", str(cd))
    assert r.returncode != 0 and "belongs to GE-Proton10-23" in r.stderr
    assert (win / "mono" / "mono-2.0" / "mscorlib.dll").exists()


# ── translation-layer manifest ──────────────────────────────────────────────
# One manifest drives install, overrides, config_info and diag.

def ship_layers(neutron, dxvk_sub="x86_64-windows"):
    wine = Path(neutron.lib_dir) / "wine"
    for sub, dlls in ((f"dxvk/{dxvk_sub}", ("d3d11", "dxgi")),
                      ("vkd3d-proton/x86_64-windows", ("d3d12",))):
        (wine / sub).mkdir(parents=True, exist_ok=True)
        for dll in dlls:
            (wine / sub / f"{dll}.dll").write_bytes(b"MZ")


@pytest.mark.parametrize("dxvk_sub", ["x64", "x86_64-windows"])
def test_overrides_follow_manifest(session_for, dxvk_sub):
    s = session_for(BRIDGE)
    ship_layers(s.neutron, dxvk_sub)
    s._build_dll_overrides()
    combined = s.env["WINEDLLOVERRIDES"]
    for dll in ("d3d11", "dxgi", "d3d12"):
        assert f"{dll}=" in combined
    assert "d3d9=" not in combined  # not shipped by this build


def test_wined3d_drops_dxvk_but_keeps_vkd3d(session_for):
    s = session_for(BRIDGE, STEAM_COMPAT_CONFIG="wined3d")
    ship_layers(s.neutron)
    s._build_dll_overrides()
    combined = s.env["WINEDLLOVERRIDES"]
    assert "d3d11=" not in combined and "dxgi=" not in combined
    assert "d3d12=" in combined


def test_config_info_tracks_wine_style_dxvk_dir(session_for, neutron_mod):
    # dir_sig() returns "0" (truthy) for a missing dir, so the old
    # `sig(x64) or sig(x86_64-windows)` never looked at the second layout
    s = session_for(BRIDGE)
    ship_layers(s.neutron, "x86_64-windows")
    before = s.compatdata._compute_config_info(s)
    dll = Path(s.neutron.lib_dir) / "wine" / "dxvk" / "x86_64-windows" / "d3d11.dll"
    os.utime(dll, (dll.stat().st_atime, dll.stat().st_mtime + 60))
    assert s.compatdata._compute_config_info(s) != before


def test_manifest_names_are_bare_dll_names(neutron_mod):
    for layer in neutron_mod.TRANSLATION_LAYERS:
        assert set(layer.subdirs) == {"x64", "x86"}
        for dll in layer.dlls:
            assert dll.isidentifier() and not dll.endswith(".dll")


# ── components ──────────────────────────────────────────────────────────────
# A new integration is one Component subclass listed in COMPONENTS; the core
# must reach every hook without being edited.

def test_a_new_component_is_wired_everywhere(session_for, neutron_mod, monkeypatch, capsys):
    calls = []

    class Probe(neutron_mod.Component):
        name = title = "probe"
        def ld_paths(self): return ["/probe/lib"]
        def apply_env(self, env): env.setdefault("PROBE", "1")
        def overrides(self): return {"probe": "n"}
        def install(self, track_file): calls.append("install")
        def stray_files(self): return ("drive_c/probe.dll",)
        def per_launch(self): calls.append("per_launch")
        def diag(self, kv): kv("probe", "here")

    monkeypatch.setattr(neutron_mod.components, "COMPONENTS",
                        neutron_mod.components.COMPONENTS + (Probe,))
    s = session_for(BRIDGE)
    s.init_session(make_prefix=False)
    assert s.env["PROBE"] == "1"
    assert "probe=n" in s.env["WINEDLLOVERRIDES"].split(";")
    assert "/probe/lib" in s.env["LD_LIBRARY_PATH"].split(":")

    drive_c = Path(s.compatdata.prefix) / "drive_c"
    drive_c.mkdir(parents=True)
    (drive_c / "probe.dll").write_bytes(b"MZ")
    assert s.compatdata._sweep_foreign_files(s)
    assert not (drive_c / "probe.dll").exists()

    s.compatdata._overlay_extras(s, None)
    assert calls == ["install"]
    with pytest.raises(SystemExit):
        s.diag([])
    assert "== probe ==" in capsys.readouterr().out


def test_components_have_unique_names(neutron_mod):
    names = [c.name for c in neutron_mod.components.COMPONENTS]
    assert all(names) and len(set(names)) == len(names)


# ── missing-comma lint ──────────────────────────────────────────────────────
# Python glues adjacent string literals together, so ("d3d11.dll" "dxgi.dll")
# is one string. Flag two adjacent name-like literals (no spaces) — log
# messages split across lines contain spaces and are left alone.

def test_no_adjacent_name_literals():
    import ast
    import io
    import tokenize
    suspects = []
    for path in LAUNCHER_SOURCES:
        toks = [t for t in tokenize.generate_tokens(io.StringIO(path.read_text()).readline)
                if t.type not in (tokenize.NL, tokenize.NEWLINE, tokenize.COMMENT,
                                  tokenize.INDENT, tokenize.DEDENT)]
        for a, b in zip(toks, toks[1:]):
            if a.type == b.type == tokenize.STRING and not a.string[:1] in "fFbB" \
                    and not b.string[:1] in "fFbB":
                va, vb = ast.literal_eval(a.string), ast.literal_eval(b.string)
                if va and vb and " " not in va + vb:
                    suspects.append(f"{path.relative_to(BUILDER)}:{a.start[0]}: "
                                    f"{a.string} {b.string}")
    assert not suspects, "missing comma?\n" + "\n".join(suspects)


# ── packaged layout ─────────────────────────────────────────────────────────
# What neutron-package.sh ships: `neutron` (the entry script, its fallback
# schema stamped by sed) with neutron_lib/ beside it.

def install_tool(tmp_path, fallback=None):
    pkg = make_package(tmp_path)
    (pkg / "version").unlink()
    (pkg / "files" / "bin").mkdir(parents=True)
    (pkg / "files" / "bin" / "wine").write_text("#!/bin/sh\n")
    entry = NEUTRON_PY.read_text()
    if fallback:
        entry = entry.replace('FALLBACK_PREFIX_VERSION = "mythix-neutron-0.0"',
                              f'FALLBACK_PREFIX_VERSION = "{fallback}"')
    (pkg / "neutron").write_text(entry)
    shutil.copytree(BUILDER / "neutron_lib", pkg / "neutron_lib",
                    ignore=shutil.ignore_patterns("__pycache__"))
    return pkg


def run_tool(pkg, tmp_path, *args):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("STEAM", "Steam", "PYTHON"))}
    env.update(NEUTRON_NO_CONTAINER="1", HOME=str(tmp_path / "home"),
               STEAM_COMPAT_DATA_PATH=str(tmp_path / "cd"))
    return subprocess.run([sys.executable, str(pkg / "neutron"), *args], env=env,
                          capture_output=True, text=True, timeout=60)


def test_packaged_entry_runs_diag(tmp_path):
    pkg = install_tool(tmp_path, fallback="Mythix-Neutron-11.19-9")
    r = run_tool(pkg, tmp_path, "diag")
    assert r.returncode == 0, r.stderr
    for title in ("translation layers (bundled)", "steam", "vr", "nvidia",
                  "sony controllers", "wine mono / gecko"):
        assert f"== {title} ==" in r.stdout
    assert "Mythix-Neutron-11.19-9 (from fallback)" in r.stdout
    assert not list(pkg.rglob("__pycache__"))


def test_entry_without_package_says_so(tmp_path):
    pkg = install_tool(tmp_path)
    shutil.rmtree(pkg / "neutron_lib")
    r = run_tool(pkg, tmp_path, "diag")
    assert r.returncode != 0 and "neutron_lib package" in r.stderr
