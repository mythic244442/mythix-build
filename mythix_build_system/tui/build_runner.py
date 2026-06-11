"""Pure-async subprocess runner for builds.

Separated from :mod:`mythix_build_system.tui.build_screen` so it can be exercised
by unit tests without spinning up a Textual ``App`` + ``Pilot`` (which
chokes on our long-running workers and ``set_interval`` timers — the
pilot's ``_wait_for_screen`` expects message queues to drain, and an
actively-streaming subprocess keeps them permanently busy).

:func:`stream_build` spawns ``bash <path> <args...>``, reads its combined
stdout/stderr line by line, parses each line into a :class:`StageEvent`,
folds it into a :class:`ProgressState`, and invokes ``on_event`` with both.
Callers (like :class:`BuildScreen`) use ``on_event`` as a UI-update hook.
"""

from __future__ import annotations

import asyncio
import os
import signal
from dataclasses import dataclass
from pathlib import Path
from typing import Awaitable, Callable

from mythix_build_system.tui.progress import ProgressState, StageEvent, parse_line

EventCallback = Callable[[StageEvent, ProgressState], None]
"""Sync callback — receives each parsed event and the cumulative state."""


@dataclass(slots=True)
class BuildOutcome:
    """Final result of a build run."""

    returncode: int
    """``0`` on clean exit, ``127`` if the tool couldn't be launched,
    whatever the child exited with otherwise."""

    state: ProgressState
    """Cumulative counts and last-seen stage/section."""

    launched: bool
    """True iff the subprocess was actually spawned (vs. launch failure)."""

    @property
    def ok(self) -> bool:
        return self.launched and self.returncode == 0


async def stream_build(
    path: Path,
    args: list[str],
    on_event: EventCallback | None = None,
) -> tuple[BuildOutcome, asyncio.subprocess.Process | None]:
    """Run ``bash path args...``, pump output through the parser.

    Returns ``(outcome, process)``. The process is returned so callers can
    send signals to it (e.g. SIGINT on ctrl-c). It will already have exited
    by the time this returns.

    The ``on_event`` callback is invoked once per parsed line, with the
    event and the current cumulative :class:`ProgressState`. Exceptions
    raised in the callback propagate and abort the stream — keep callbacks
    cheap and non-throwing.
    """
    state = ProgressState()

    try:
        process = await asyncio.create_subprocess_exec(
            "bash", str(path), *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            env={**os.environ, "PYTHONUNBUFFERED": "1"},
        )
    except OSError:
        # Most commonly: ENOENT on bash or the script — both count as 127.
        return BuildOutcome(returncode=127, state=state, launched=False), None

    assert process.stdout is not None
    async for raw in process.stdout:
        event = parse_line(raw.decode(errors="replace"))
        state.update(event)
        if on_event is not None:
            on_event(event, state)

    returncode = await process.wait()
    return BuildOutcome(returncode=returncode, state=state, launched=True), process


async def cancel_process(
    process: asyncio.subprocess.Process,
    grace_seconds: float = 5.0,
) -> None:
    """Politely ask ``process`` to exit; escalate to SIGTERM on timeout.

    Separated so :class:`BuildScreen`'s cancel action stays small.
    """
    try:
        process.send_signal(signal.SIGINT)
    except ProcessLookupError:
        return
    try:
        await asyncio.wait_for(process.wait(), timeout=grace_seconds)
    except asyncio.TimeoutError:
        try:
            process.terminate()
        except ProcessLookupError:
            pass
