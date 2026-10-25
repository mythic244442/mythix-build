#!/usr/bin/env python3
# _____________________________________________________________________________
# |-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-***_Neutron_***-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|
# |//////////////////////////////////#########\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\|
# |___________________________________________________________________________|
# |-|-|-|-|-|-|-|-|-|-|-|-|-|-***_Python_launcher_***-|-|-|-|-|-|-|-|-|-|-|-|-|
# |//////////////////////////////#################\\\\\\\\\\\\\\\\\\\\\\\\\\\\|
# |___________________________________________________________________________|
#
# Speaks the standard Steam compat-tool verb interface:
#
#     run | waitforexitandrun | runinprefix | getcompatpath | getnativepath
#
# plus helper verbs:
#
#     createprefix | destroyprefix | makedefaultpfx | slimprefix | stop | diag
#
# Incorporates engine improvements adapted (re-implemented, not copied) from
# Valve Proton 11 — see mythix-build NOTICE for attribution:
#   - default prefix template (files/share/default_pfx): boot Wine once, then
#     clone new prefixes from it via symlinks + reflink copies
#   - prefix version file + upgrade_pfx: logged upgrades, downgrade recovery
#   - reflink (copy_file_range) DLL copies — fast, space-saving prefix setup
#   - config-info hashing — re-overlay only when the build or inputs change
#   - tracked-files manifest + `destroyprefix` for clean uninstalls
#   - file-locking so concurrent Steam launches don't race the prefix
#   - wine-builtin-DLL detection — overlays don't clobber user-native DLLs
#   - per-prefix MachineGuid regeneration when cloning the template
#   - NVIDIA nvngx/DLSS DLL discovery + NVIDIA_WINE_DLL_DIR
#   - OpenVR openvrpaths.vrpath rewriting into the prefix
#   (Neutron's own) foreign-tool sweep: DLL symlinks a Proton/GE run leaves
#   in system32/syswow64, plus its vrclient when this build has none, are
#   quarantined to <compatdata>/foreign-quarantine every launch
#   - game / Steam-library DOS drives (s: / t:)
#   - Wine Mono / Gecko unpacked once under files/share/wine and shared by
#     every prefix; `slimprefix` moves an older prefix off its private Mono
#   - WoW64 mode toggle, user_settings.py overrides, an extensible
#     compat_config framework, and NEUTRON_LOG logging + health warnings
#
# Optional integrations (translation layers, Steam, VR, NVIDIA, Sony pads,
# Wine Mono/Gecko) are Component classes listed in COMPONENTS: each says what
# it installs, which env and DLL overrides it adds, what it sweeps, what it
# redoes every launch and what diag shows; the core only calls the hooks.
#
# This script is only the entry point; the launcher is the neutron_lib/
# package next to it (see neutron_lib/__init__.py for the map).
#
# Bundled DXVK / VKD3D-Proton DLLs under files/lib/wine are installed into
# prefixes by the tracked runtime overlay.  `wined3d` disables DXVK injection;
# VKD3D-Proton remains available for D3D12.
#
# Per-build curation: BUILD_PROFILES (keyed by the version-file tag, or
# NEUTRON_PROFILE) records what each Wine build needs — like Valve shipping a
# proton script per Proton version. Bundled DXVK/VKD3D-Proton DLLs are PE-
# validated before overlay; `diag` reports their health and the active profile.
#
# Control knobs are NEUTRON_* (the proton bundle reads PROTON_* via rebrand).

import os
import sys

# Fallback prefix schema for a missing/unparseable version file; the packager
# stamps the package's own version here.
FALLBACK_PREFIX_VERSION = "mythix-neutron-0.0"

# no __pycache__ inside the compat tool dir
sys.dont_write_bytecode = True

if __name__ == "__main__":
    entry = os.path.realpath(__file__)
    sys.path.insert(0, os.path.dirname(entry))
    try:
        from neutron_lib.main import main
    except ImportError as e:
        sys.exit(f"neutron: ERROR: the neutron_lib package next to {entry} "
                 f"is missing or incomplete ({e}); reinstall this compat tool")
    main(entry, FALLBACK_PREFIX_VERSION)
