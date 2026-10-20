"""Launcher decisions that depend on the host: steam.exe launches and Sony pads.

neutron.py is a standalone script shipped inside every package, so it is
loaded from its file rather than imported as a package module.
"""

import importlib.util
import os
import subprocess
import sys
from pathlib import Path

import pytest

NEUTRON_PY = Path(__file__).resolve().parent.parent / "mythix-neutron_builder" / "neutron.py"


@pytest.fixture(scope="module")
def neutron_mod():
    spec = importlib.util.spec_from_file_location("neutron_launcher", NEUTRON_PY)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


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
    monkeypatch.setattr(neutron_mod, "steam_client_running", lambda: True)
    s = session_for(BRIDGE, SteamGameId="78da8e29", SteamAppId="78da8e29")
    assert not s.use_steam_shim
    assert "78da8e29" in s.steam_shim_reason


def test_steam_app_without_steam_client_launches_directly(session_for, neutron_mod, monkeypatch):
    monkeypatch.setattr(neutron_mod, "steam_client_running", lambda: False)
    s = session_for(BRIDGE, SteamGameId="1091500")
    assert not s.use_steam_shim
    assert "not running" in s.steam_shim_reason


def test_steam_app_with_steam_client_uses_steam_exe(session_for, neutron_mod, monkeypatch):
    monkeypatch.setattr(neutron_mod, "steam_client_running", lambda: True)
    s = session_for(BRIDGE, SteamGameId="1091500")
    assert s.use_steam_shim


def test_no_bridge_build_never_auto_uses_steam_exe(session_for, neutron_mod, monkeypatch):
    monkeypatch.setattr(neutron_mod, "steam_client_running", lambda: True)
    s = session_for("WAYLAND=1\n", SteamGameId="1091500")
    assert not s.use_steam_shim


@pytest.mark.parametrize(("knob", "expected"), [("0", False), ("1", True)])
def test_shim_knob_overrides(session_for, neutron_mod, monkeypatch, knob, expected):
    monkeypatch.setattr(neutron_mod, "steam_client_running", lambda: not expected)
    s = session_for(BRIDGE, SteamGameId="1091500", NEUTRON_USE_STEAM_SHIM=knob)
    assert s.use_steam_shim is expected


def test_steam_client_running_reads_pid_file(neutron_mod, tmp_path, monkeypatch):
    home = tmp_path / "home"
    (home / ".steam").mkdir(parents=True)
    monkeypatch.setenv("HOME", str(home))
    assert not neutron_mod.steam_client_running()          # no pid file

    fake_steam = tmp_path / "steam"                         # /proc/<pid>/comm == "steam"
    fake_steam.symlink_to(Path(sys.executable).resolve())
    proc = subprocess.Popen([str(fake_steam), "-c", "import time; time.sleep(30)"])
    try:
        (home / ".steam" / "steam.pid").write_text(f"{proc.pid}\n")
        assert neutron_mod.steam_client_running()
        (home / ".steam" / "steam.pid").write_text(f"{os.getpid()}\n")   # not steam
        assert not neutron_mod.steam_client_running()
    finally:
        proc.kill()
        proc.wait()


# ── DualShock 4 / DualSense ─────────────────────────────────────────────────

GE_XINPUT = b"MZ...PROTON_SONY_AUTO_XINPUT...MYTHIX_DS4_GLYPHS..."   # 11.19-3+ xinput
LUNA_XINPUT = b"MZ...MYTHIX_DS4_GLYPHS..."                          # Neutron-11.0 xinput
STOCK_XINPUT = b"MZ..."


def test_ge_xinput_defaults_to_sony_fallback(session_for):
    s = session_for(BRIDGE, GE_XINPUT)
    s._apply_sony_input_env()
    assert s.env["PROTON_SONY_AUTO_XINPUT"] == "1"


def test_glyph_mode_keeps_sony_native(session_for):
    s = session_for(BRIDGE, GE_XINPUT, MYTHIX_DS4_GLYPHS="1")
    s._apply_sony_input_env()
    assert "PROTON_SONY_AUTO_XINPUT" not in s.env
    assert s.sony_mode.startswith("native PlayStation")


def test_user_choice_is_kept(session_for):
    s = session_for(BRIDGE, GE_XINPUT, PROTON_SONY_AUTO_XINPUT="0")
    s._apply_sony_input_env()
    assert s.env["PROTON_SONY_AUTO_XINPUT"] == "0"


@pytest.mark.parametrize("xinput", [LUNA_XINPUT, STOCK_XINPUT, None])
def test_other_xinputs_are_left_alone(session_for, xinput):
    s = session_for(BRIDGE, xinput)
    s._apply_sony_input_env()
    assert "PROTON_SONY_AUTO_XINPUT" not in s.env


# ── steamclient DLLs for steam.exe launches ─────────────────────────────────

def test_steamclient_dlls_installed_and_refreshed(neutron_mod, tmp_path, monkeypatch):
    steam = tmp_path / "steam"
    (steam / "legacycompat").mkdir(parents=True)
    for name in ("steamclient.dll", "steamclient64.dll"):
        (steam / "legacycompat" / name).write_bytes(b"MZ" + name.encode())
    monkeypatch.setenv("STEAM_COMPAT_DATA_PATH", str(tmp_path / "compatdata"))
    monkeypatch.setenv("STEAM_COMPAT_CLIENT_INSTALL_PATH", str(steam))
    (tmp_path / "compatdata" / "pfx").mkdir(parents=True)

    cd = neutron_mod.CompatData()
    cd._ensure_steamclient_dlls()
    dst = tmp_path / "compatdata" / "pfx" / "drive_c" / "Program Files (x86)" / "Steam"
    assert (dst / "steamclient64.dll").read_bytes() == b"MZsteamclient64.dll"
    tracked = (tmp_path / "compatdata" / "tracked_files").read_text().splitlines()
    assert "drive_c/Program Files (x86)/Steam/steamclient64.dll" in tracked

    # unchanged source → left alone; a Steam update → refreshed
    before = (dst / "steamclient.dll").stat().st_ino
    cd._ensure_steamclient_dlls()
    assert (dst / "steamclient.dll").stat().st_ino == before
    src = steam / "legacycompat" / "steamclient.dll"
    src.write_bytes(b"MZ-updated")
    os.utime(src, (src.stat().st_atime, src.stat().st_mtime + 60))
    cd._ensure_steamclient_dlls()
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


def test_own_vrclient_stays_enabled(session_for):
    s = session_for(BRIDGE)
    (Path(s.neutron.pe_system32) / "vrclient_x64.dll").write_bytes(b"MZvrclient")
    s._build_dll_overrides()
    combined = s.env.get("WINEDLLOVERRIDES", "")
    assert "vrclient=" not in combined
    assert "vrclient_x64=" not in combined
