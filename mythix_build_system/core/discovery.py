"""On-disk discovery for mythix-build tools.

A Python port of the ``_find_tool`` logic from ``mythix-build.sh``, generalised
to the three layouts we might be running in:

1. **Installed with PATH** — ``make install`` copied a binary to
   ``PREFIX/bin/<tool>`` and added it to ``$PATH``. ``shutil.which`` finds it.

2. **Source tree** — the Python launcher is running from the repo checkout,
   alongside the ``mythix-*_builder`` subdirectories. Tools resolve via
   :attr:`Tool.source_relpath` off the repo root.

3. **Installed without PATH** — binary lives at ``PREFIX/bin/<tool>`` but
   ``$PATH`` is not set up (e.g. ``~/.local/bin`` not exported). We walk
   a few well-known prefixes (``~/.local``, ``/usr/local``, ``/usr``).

We additionally honour ``$MYTHIX_ROOT`` as an explicit override for the
source-tree root.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path

from mythix_build_system.core.tools import Tool, get_tool


# ── Repo root resolution ─────────────────────────────────────────────────────

# Markers that reliably identify a mythix-build source checkout.
_ROOT_MARKERS: tuple[str, ...] = (
    "mythix-build.sh",
    "mythix-neutron_builder",
    "mythix-wine_builder",
)

# Well-known install prefixes to probe for ``bin/`` and ``lib/`` layouts.
_INSTALL_PREFIXES: tuple[str, ...] = (
    "~/.local",
    "/usr/local",
    "/usr",
)


def _looks_like_root(path: Path) -> bool:
    """True if *path* contains enough marker files to be the repo root."""
    if not path.is_dir():
        return False
    return sum((path / m).exists() for m in _ROOT_MARKERS) >= 2


def resolve_root(start: Path | None = None) -> Path | None:
    """Locate the mythix-build repo root.

    Search order:
      1. ``$MYTHIX_ROOT`` environment variable (if set and valid).
      2. *start* (defaults to CWD) and each of its ancestors.
      3. Directory containing the ``mythix_build_system`` package — walk up from
         this file's location. Useful when installed editable from a clone.

    Returns ``None`` if no checkout is detectable.
    """
    # ``MYTHIX_ROOT`` is the canonical override; ``LOONI_ROOT`` is honoured as a
    # backward-compatible fallback for setups predating the mythix rebrand.
    env_root = os.environ.get("MYTHIX_ROOT") or os.environ.get("LOONI_ROOT")
    if env_root:
        p = Path(env_root).expanduser().resolve()
        if _looks_like_root(p):
            return p

    candidates: list[Path] = []
    if start is None:
        start = Path.cwd()
    candidates.append(start.resolve())
    candidates.extend(p for p in start.resolve().parents)

    # Also try the package's own on-disk location — when installed with
    # ``pip install -e .`` the package sits inside the repo checkout.
    pkg_dir = Path(__file__).resolve().parent.parent
    candidates.append(pkg_dir)
    candidates.extend(pkg_dir.parents)

    seen: set[Path] = set()
    for cand in candidates:
        if cand in seen:
            continue
        seen.add(cand)
        if _looks_like_root(cand):
            return cand
    return None


# ── Tool lookup ──────────────────────────────────────────────────────────────


def find_tool(key_or_tool: str | Tool, root: Path | None = None) -> Path | None:
    """Return the on-disk path to a tool, or ``None`` if not found.

    *key_or_tool* may be a string key (``"wine-builder"``) or a :class:`Tool`.
    *root* overrides the auto-detected repo root — pass it in tests.
    """
    tool = key_or_tool if isinstance(key_or_tool, Tool) else get_tool(key_or_tool)

    # 1. Binary on PATH — the happy path for installed users.
    on_path = shutil.which(tool.key)
    if on_path:
        return Path(on_path)

    # 2. Source tree.
    repo_root = root if root is not None else resolve_root()
    if repo_root is not None:
        candidate = repo_root / tool.source_relpath
        if candidate.is_file():
            return candidate.resolve()

    # 3. Installed without PATH — probe well-known prefixes.
    for prefix_str in _INSTALL_PREFIXES:
        prefix = Path(prefix_str).expanduser()
        bin_candidate = prefix / "bin" / tool.key
        if bin_candidate.is_file():
            return bin_candidate.resolve()
        if tool.installed_lib_subdir:
            lib_candidate = (
                prefix
                / "lib"
                / tool.installed_lib_subdir
                / Path(tool.source_relpath).name
            )
            if lib_candidate.is_file():
                return lib_candidate.resolve()

    return None
