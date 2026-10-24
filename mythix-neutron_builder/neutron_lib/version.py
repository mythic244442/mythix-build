"""Prefix schema version and per-build profiles.

CURRENT_PREFIX_VERSION, PREFIX_VERSION_SOURCE and ACTIVE_PROFILE are
reassigned at startup: read them as version.NAME, never import them."""

import os
import re

from .common import log


# ── Prefix schema version (brand-neutral so both bundles share prefixes) ─────
# Format: <tag>-<MAJ.MIN>-<revision>, brand-neutral so both bundles share
# prefixes. upgrade_pfx() parses it; bump REV to force a DLL re-overlay,
# bump MAJ.MIN for schema changes. rev 2: DXVK/VKD3D no longer bundled.
# Downgrade detection only applies within the same <tag> — prefixes from a
# different scheme (e.g. old "tkg-neutron-11.11") upgrade non-destructively.
#
# The live value is adopted from the bundle's version file (Proton format:
# "<build timestamp> <version>", last token wins) via load_prefix_version()
# so mythix-build stamps it at package time and the script never drifts.
# The fallback for missing/unparseable version files lives in the `neutron`
# entry script, where the packager stamps it; main() hands it to set_fallback.
CURRENT_PREFIX_VERSION = "mythix-neutron-0.0"
PREFIX_VERSION_SOURCE = "fallback"


def set_fallback(ver):
    global CURRENT_PREFIX_VERSION, PREFIX_VERSION_SOURCE
    CURRENT_PREFIX_VERSION = ver
    PREFIX_VERSION_SOURCE = "fallback"

# Accepts "<tag>-MAJ.MIN[-REV]" and the builder's git-describe form
# "<tag>-MAJ.MIN.r<REV>.g<hash>" (e.g. Mythix-Neutron-10.17.r0.gf686957b).
_PREFIX_VERSION_RE = re.compile(
    r"^\s*(.*?)-?(\d+)\.(\d+)(?:-(\d+)|\.r(\d+))?(?:\.g[0-9a-f]+)?\s*$")


def parse_prefix_version(ver):
    """-> (tag, major, minor, revision) or None when unparseable."""
    if not ver:
        return None
    m = _PREFIX_VERSION_RE.match(ver)
    if not m:
        return None
    return (m.group(1), int(m.group(2)), int(m.group(3)),
            int(m.group(4) or m.group(5) or 0))


def load_prefix_version(version_file):
    """Adopt the prefix schema version from the bundle's version file, like
    Proton reads its own. Missing file -> keep the fallback (dev checkouts);
    unparseable content -> warn and keep the fallback."""
    global CURRENT_PREFIX_VERSION, PREFIX_VERSION_SOURCE
    try:
        with open(version_file) as f:
            tokens = f.readline().split()
    except OSError:
        return
    if tokens and parse_prefix_version(tokens[-1]):
        CURRENT_PREFIX_VERSION = tokens[-1]
        PREFIX_VERSION_SOURCE = "version file"
    else:
        log(f"warning: unparseable version file ({version_file}); "
            f"using fallback prefix schema {CURRENT_PREFIX_VERSION}")


def load_build_info(path):
    """KEY=VALUE facts the builder writes next to the version file
    (BUILD_MODE, PROFILE, WAYLAND, ...). Missing file -> {}."""
    info = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                info[key.strip()] = value.strip()
    except OSError:
        pass
    return info


# ── Build profiles — per-Wine-build curation, like Valve's per-version proton ─
# Selected from the version tag (case-insensitive prefix match); NEUTRON_PROFILE
# overrides. Keep facts about a build here rather than scattering if/elses.
BUILD_PROFILES = {
    # Mythix Neutron 10.x: Valve bleeding-edge proton-wine + staging/TkG/GE,
    # classic multilib (has wine64), esync/fsync only (no ntsync yet).
    "mythix-neutron-10": dict(
        description="Mythix Neutron 10.x (proton-wine bleeding-edge base)",
        wine_tree="proton",
        ntsync=False,               # build targets e/fsync; never opt into ntsync
        d3d_override="n",           # DXVK/VKD3D native-only, exactly like Proton
        proton_env=True,            # proton-wine reads PROTON_* + WINE_* knobs
        env_defaults={
            "WINE_LARGE_ADDRESS_AWARE": "1",
            "WINE_GST_REGISTRY_DIR": "",   # filled per-prefix in init_session
        },
    ),
    # Mythix Neutron 11.x: Valve bleeding-edge + GE (incl. GE's Wayland work)
    # + TkG + Mythix patches. 11.11 is a classic multilib build, 11.19+ the
    # WoW64 (Proton) layout; build-info BUILD_MODE says which. Valve's tree
    # carries ntsync alongside esync/fsync; the launcher still checks the
    # build + kernel.
    "mythix-neutron-11": dict(
        description="Mythix Neutron 11.x (Valve bleeding-edge + GE + TkG)",
        wine_tree="proton",
        ntsync=True,
        d3d_override="n",
        proton_env=True,
        env_defaults={
            "WINE_LARGE_ADDRESS_AWARE": "1",
            "WINE_GST_REGISTRY_DIR": "",   # filled per-prefix in init_session
        },
    ),
    # Anything else (upstream / tkg / kron4ek style unified builds)
    "generic": dict(
        description="generic Wine build",
        wine_tree="upstream",
        ntsync=True,
        d3d_override="n,b",
        proton_env=False,
        env_defaults={},
    ),
}
ACTIVE_PROFILE = "generic"


def select_build_profile(version_string):
    """Pick the profile whose key prefixes the version tag (longest wins)."""
    global ACTIVE_PROFILE
    forced = os.environ.get("NEUTRON_PROFILE")
    if forced in BUILD_PROFILES:
        ACTIVE_PROFILE = forced
        return
    parsed = parse_prefix_version(version_string)
    if parsed:
        ident = f"{parsed[0]}-{parsed[1]}.{parsed[2]}".lower()
    else:
        ident = (version_string or "").lower()
    best = ""
    for key in BUILD_PROFILES:
        if key == "generic" or len(key) <= len(best):
            continue
        if ident == key or (ident.startswith(key)
                            and ident[len(key)] in ".-"):
            best = key
    ACTIVE_PROFILE = best or "generic"


def profile():
    return BUILD_PROFILES[ACTIVE_PROFILE]
