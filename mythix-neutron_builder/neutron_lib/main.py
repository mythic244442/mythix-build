"""Verb dispatch."""

import os
import sys

from . import version
from .common import container_self_wrap, die, in_container, log
from .dist import Neutron
from .prefix import CompatData
from .session import Session
from .version import load_prefix_version, select_build_profile


# ── Dispatch ─────────────────────────────────────────────────────────────────
def main(entry, fallback_prefix_version):
    """entry: the `neutron` script itself (its directory is the tool)."""
    version.set_fallback(fallback_prefix_version)
    tool_dir = os.path.dirname(entry)
    neutron = Neutron(tool_dir)
    load_prefix_version(neutron.version_file)
    select_build_profile(version.CURRENT_PREFIX_VERSION)

    if not neutron.has_wine():
        die(f"Wine binary not found: {neutron.wine}")

    if in_container():
        runtime = os.environ.get("PRESSURE_VESSEL_RUNTIME", "unknown")
        log(f"running inside container (runtime: {runtime})")
    else:
        container_self_wrap(entry)

    if len(sys.argv) < 2:
        die("Usage: neutron <verb> [args...]")

    verb = sys.argv[1]
    extra = sys.argv[2:]

    # slimprefix also takes the compatdata dir as an argument
    if verb == "slimprefix" and extra:
        os.environ["STEAM_COMPAT_DATA_PATH"] = os.path.abspath(extra[0])

    compatdata = CompatData()

    # createprefix drives a base Proton with its own minimal env, then
    # applies the Neutron overlay using a normal session environment.
    if verb == "createprefix":
        import argparse
        parser = argparse.ArgumentParser(prog="neutron createprefix")
        parser.add_argument("--proton", required=True,
                            help="Path to a base Proton installation directory")
        parsed = parser.parse_args(extra)
        session = Session(neutron, compatdata)
        session.init_session(make_prefix=True)
        compatdata.create_with_proton(session, parsed.proton)
        sys.exit(0)

    # destroyprefix removes exactly what Neutron installed (tracked files).
    if verb == "destroyprefix":
        compatdata.remove_tracked_files()
        sys.exit(0)

    # makedefaultpfx (re)creates the prefix template — handy at package time
    # so bundles can ship a prebuilt files/share/default_pfx like Proton.
    if verb == "makedefaultpfx":
        session = Session(neutron, compatdata)
        session.init_session(make_prefix=False)
        neutron.make_default_prefix(session.env, force="--force" in extra)
        log(f"default_pfx at {neutron.default_pfx_dir}")
        sys.exit(0)

    # slimprefix swaps a prefix's private Wine Mono for the shared one
    if verb == "slimprefix":
        if not os.path.isdir(compatdata.prefix):
            die(f"no prefix at {compatdata.prefix}")
        session = Session(neutron, compatdata)
        session.init_session(make_prefix=False)
        session.components["addons"].slim()
        sys.exit(0)

    session = Session(neutron, compatdata)
    session.init_session(make_prefix=(verb != "diag"))

    if verb in ("run", "waitforexitandrun"):
        session.run(extra, wait=True)
    elif verb == "runinprefix":
        session.run_in_prefix(extra)
    elif verb == "getcompatpath":
        session.get_compat_path(extra)
    elif verb == "getnativepath":
        session.get_native_path(extra)
    elif verb == "stop":
        session.stop()
    elif verb == "diag":
        session.diag(extra)
    else:
        log(f"unknown verb '{verb}', forwarding to wine")
        session.run([verb] + extra, wait=True)
