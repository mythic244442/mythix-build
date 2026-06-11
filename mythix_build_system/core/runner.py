"""Subprocess orchestration for launching the shell tools.

We deliberately hand the child process a full TTY — the existing shell tools
use ``fzf``, ``zenity``, and their own TUIs, and would break if we captured
stdin/stdout. The caller is responsible for suspending the Textual app
(via :meth:`textual.app.App.suspend`) around the call.
"""

from __future__ import annotations

import os
import signal
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

from mythix_build_system.core.discovery import find_tool
from mythix_build_system.core.tools import Tool


@dataclass(frozen=True, slots=True)
class RunResult:
    """Outcome of a tool launch."""

    tool_key: str
    path: Path | None
    returncode: int

    @property
    def ok(self) -> bool:
        """True if the tool exited cleanly or via Ctrl+C (SIGINT)."""
        return self.returncode in (0, 128 + signal.SIGINT)

    @property
    def not_found(self) -> bool:
        """True if the tool could not be located on disk."""
        return self.path is None


def run_tool(
    key_or_tool: str | Tool,
    args: Sequence[str] = (),
    *,
    cwd: Path | None = None,
    env_extra: dict[str, str] | None = None,
) -> RunResult:
    """Launch one of the shell tools as a subprocess with inherited stdio.

    The child shares our controlling TTY, so its ``fzf`` / ``zenity`` /
    ``read`` prompts work the same as if the user had run the shell script
    directly. We ignore ``SIGINT`` in the parent while the child runs — the
    signal still reaches the foreground process group and the child can
    handle it, but our launcher stays alive to return to the menu.
    """
    tool = (
        key_or_tool
        if isinstance(key_or_tool, Tool)
        else __import__(
            "mythix_build_system.core.tools", fromlist=("get_tool",)
        ).get_tool(key_or_tool)
    )
    path = find_tool(tool)
    if path is None:
        return RunResult(tool_key=tool.key, path=None, returncode=127)

    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)

    # Match the legacy launcher: parent ignores SIGINT while the child runs
    # so Ctrl+C kills the tool but returns us to the menu instead of exiting.
    prev_handler = signal.getsignal(signal.SIGINT)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    try:
        completed = subprocess.run(
            ["bash", str(path), *args],
            cwd=str(cwd) if cwd else None,
            env=env,
            check=False,
        )
    finally:
        signal.signal(signal.SIGINT, prev_handler)

    return RunResult(
        tool_key=tool.key,
        path=path,
        returncode=completed.returncode,
    )
