"""Catalogue of mythix-build tools surfaced by the launcher.

Each :class:`Tool` is one shell entry point — the Python launcher just needs
enough metadata to show it in the menu and resolve its on-disk location.

Ordering here matches the order shown in the legacy ``mythix-build.sh`` menu,
which is intentional: Luna has muscle memory for the numbered menu.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Final


@dataclass(frozen=True, slots=True)
class Tool:
    """Metadata for one shell tool exposed by the launcher."""

    key: str
    """Command name — also the installed binary name under ``~/.local/bin``."""

    icon: str
    """Single emoji/symbol shown in the UI. Kept to one char for alignment."""

    title: str
    """Short human-readable title (≤ ~30 chars)."""

    blurb: str
    """One-line description of what this tool does."""

    group: str
    """Category for UI grouping (``build``, ``hybrid``, ``install``, ``gui``)."""

    source_relpath: str
    """Path to the shell script, relative to the mythix-build repo root."""

    installed_lib_subdir: str | None = None
    """Optional lib subdir under ``PREFIX/lib`` for installed-lib discovery."""

    non_interactive: bool = False
    """True if this tool can run without a TTY (no fzf/zenity/read prompts).

    When True, pressing Enter in the launcher opens the :class:`BuildScreen`
    (captured stdout + live progress bar + log tail) instead of the classic
    suspend-and-handoff path. Interactive tools keep the suspend path so
    their prompts still work. Users can always force either mode with the
    ``B`` (build-screen) or ``L`` (legacy suspend) keys in the menu.

    Currently unset on all tools — flip to True per-tool once BuildScreen
    is validated to work for it (no hidden prompts, output fits the log
    tail, progress markers parse cleanly)."""


# NOTE on icons: every glyph below is a visually 2-cell emoji. Mixing 1-cell
# symbols (``⇌``, ``⚙``) with 2-cell emojis in the same OptionList made the
# prompt widths inconsistent by one cell, which confused Textual's initial
# layout pass and caused rows to visually "merge" until a focus cycle forced
# a remeasure. Keep them all 2-cell to preserve alignment.
TOOLS: Final[tuple[Tool, ...]] = (
    Tool(
        key="wine-builder",
        icon="🍷",
        title="wine-builder",
        blurb="Build Wine from source (mainline, staging, TKG, Valve…)",
        group="build",
        source_relpath="mythix-wine_builder/wine-builder.sh",
    ),
    Tool(
        key="neutron-builder",
        icon="🎮",
        title="neutron-builder",
        blurb="Build Neutron packages for Steam (Wine + DXVK + VKD3D)",
        group="build",
        source_relpath="mythix-neutron_builder/neutron-builder.sh",
    ),
    Tool(
        key="proton-builder",
        icon="🔧",
        title="proton-builder",
        blurb="Delegated builds — GE-Proton / proton-tkg upstream",
        group="build",
        source_relpath="mythix-proton_builder/proton-builder.sh",
        installed_lib_subdir="mythix-proton_builder",
    ),
    Tool(
        key="wine-proton_hybrid",
        icon="🔀",
        title="wine-proton_hybrid",
        blurb="Merge any Wine build over an existing Proton base",
        group="hybrid",
        source_relpath="mythix-wine-proton_hybrid_builder/wine-proton_hybrid-v1.0.0.sh",
    ),
    Tool(
        key="wine-neutron_hybrid",
        icon="🔀",
        title="wine-neutron_hybrid",
        blurb="Merge any Wine build over an existing Neutron base",
        group="hybrid",
        source_relpath="mythix-wine-neutron_hybrid_builder/wine-neutron_hybrid-v1.0.0.sh",
    ),
    Tool(
        key="wine_install_mgr",
        icon="📦",
        title="wine_install_mgr",
        blurb="Install, switch, and manage custom Wine builds",
        group="install",
        source_relpath="mythix-winetoolz/modules/shared_lib/wine_install_manager.sh",
        installed_lib_subdir="mythix-winetoolz/modules/shared_lib",
    ),
    Tool(
        key="neutron-install",
        icon="🚀",
        title="neutron-install",
        blurb="Deploy Neutron packages to Steam",
        group="install",
        source_relpath="mythix-neutron-install/neutron-install.sh",
        installed_lib_subdir="mythix-neutron-install",
    ),
    Tool(
        key="proton-install",
        icon="🛸",
        title="proton-install",
        blurb="Download & deploy GE-Proton / pre-built Proton to Steam",
        group="install",
        source_relpath="mythix-proton-install/proton-install.sh",
        installed_lib_subdir="mythix-proton-install",
    ),
    Tool(
        key="wine_toolz",
        icon="🧰",
        title="wine_toolz",
        blurb="GUI Wine toolkit — DXVK, prefixes, runtimes",
        group="gui",
        source_relpath="mythix-winetoolz/wine_toolz.sh",
        installed_lib_subdir="mythix-winetoolz",
    ),
)

TOOLS_BY_KEY: Final[dict[str, Tool]] = {t.key: t for t in TOOLS}


def get_tool(key: str) -> Tool:
    """Look up a tool by its key. Raises :class:`KeyError` if unknown."""
    try:
        return TOOLS_BY_KEY[key]
    except KeyError as e:
        raise KeyError(f"Unknown mythix-build tool: {key!r}") from e
