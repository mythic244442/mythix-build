"""Core, UI-free building blocks: catalogue, discovery, subprocess runner."""

from __future__ import annotations

from mythix_build_system.core.tools import TOOLS, Tool, get_tool
from mythix_build_system.core.discovery import find_tool, resolve_root
from mythix_build_system.core.runner import run_tool, RunResult

__all__ = [
    "TOOLS",
    "Tool",
    "get_tool",
    "find_tool",
    "resolve_root",
    "run_tool",
    "RunResult",
]
