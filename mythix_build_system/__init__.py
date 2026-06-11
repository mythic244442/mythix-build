"""mythix-build — Python TUI frontend over the shell build engines.

This package is a thin, modern Python layer on top of the battle-tested
``mythix-*`` shell scripts. The shell scripts still do all the real build
work; Python just handles the launcher UX, config, discovery, and
orchestration.

Entry points:
  - ``mythix`` console script          → :func:`mythix_build_system.cli.main`
  - ``python -m mythix_build_system``          → :mod:`mythix_build_system.__main__`
"""

from __future__ import annotations

__version__ = "1.0.0"

__all__ = ["__version__"]
