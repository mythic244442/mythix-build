"""Live build screen — runs a shell tool and shows progress + log tail.

Unlike :meth:`LauncherApp._launch_tool` (which suspends the TUI so the shell
tool gets a full TTY — needed for ``fzf``/``zenity``), this screen keeps the
TUI alive and captures the child's stdout/stderr via ``asyncio`` pipes.

Use it for **non-interactive** runs — typically long builds where watching
progress without losing the UI is worth more than interactive prompts.
Interactive tools (anything with ``fzf``/``zenity``/a ``read`` prompt) should
still go through the suspend-and-hand-off path in :class:`LauncherApp`.

Layout
------

::

    ╭─ mythix-build ──────────────────────────────────────╮
    │  neutron-builder                    00:02:17       │   ← heading + clock
    │  ── Building 64-bit ──                              │   ← current section
    │  ▒▒▒▒▒▒▒▒▒▒░░░░░░░░░░░░░░░░░░   42%                │   ← progress bar
    │ ┌─ log tail ─────────────────────────────────────┐ │
    │ │  ==> Configuring                               │ │
    │ │   ✓  MinGW cross-compiler                      │ │
    │ │  make -j16 ...                                 │ │
    │ │  ...                                           │ │
    │ └────────────────────────────────────────────────┘ │
    │  ctrl-c cancel · enter dismiss (when done)         │
    ╰────────────────────────────────────────────────────╯
"""

from __future__ import annotations

import asyncio
import time
from pathlib import Path

from rich.text import Text
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Vertical
from textual.reactive import reactive
from textual.screen import Screen
from textual.widgets import Footer, Label, ProgressBar, RichLog, Static

from mythix_build_system.core.discovery import find_tool
from mythix_build_system.core.tools import get_tool
from mythix_build_system.tui.build_runner import (
    BuildOutcome,
    cancel_process,
    stream_build,
)
from mythix_build_system.tui.progress import EventKind, ProgressState, StageEvent

# Max lines we keep in the RichLog buffer. Neutron builds can easily emit
# 100k+ lines — no point keeping them all in memory when we just want a tail.
_LOG_MAX_LINES = 2000

# Stage budget below which we treat the progress bar as indeterminate
# (because one-or-two sections would otherwise look "done" before we start).
_MIN_SECTIONS_FOR_DETERMINATE = 3


class BuildScreen(Screen[int]):
    """Run a shell tool with live progress display.

    Returns the child's exit code when dismissed.
    """

    BINDINGS = [
        Binding("ctrl+c", "cancel", "Cancel", priority=True),
        Binding("enter", "dismiss_if_done", "Dismiss", show=False),
        Binding("q,escape", "dismiss_if_done", "Quit", show=False),
    ]

    CSS = """
    BuildScreen {
        align: center top;
        background: $background;
    }

    #build-wrap {
        width: 100;
        height: auto;
        border: round magenta;
        padding: 1 2;
        margin: 1 0 0 0;
    }

    #build-title {
        width: 100%;
        content-align: left middle;
        color: magenta;
        text-style: bold;
    }

    #build-clock {
        width: 100%;
        content-align: right middle;
        color: $text-muted;
    }

    #build-section {
        width: 100%;
        color: $text;
        padding: 0 0 1 0;
    }

    ProgressBar {
        width: 100%;
        padding: 0 0 1 0;
    }

    RichLog {
        height: 20;
        border: round $primary 60%;
        background: $surface;
        padding: 0 1;
    }

    #build-status {
        width: 100%;
        padding: 1 0 0 0;
        content-align: center middle;
        color: $text-muted;
    }
    """

    # Reactive values drive the heading/clock/section labels.
    elapsed_seconds: reactive[int] = reactive(0)
    is_running: reactive[bool] = reactive(True)

    def __init__(
        self,
        tool_key: str,
        args: list[str] | None = None,
        tool_path: Path | None = None,
    ) -> None:
        """Create a screen that will run ``tool_key`` with ``args``.

        ``tool_path`` is optional — when provided we skip discovery (useful
        in tests where we want to run a throwaway script).
        """
        super().__init__()
        self._tool_key = tool_key
        self._args = list(args or [])
        self._tool_path = tool_path
        self._state = ProgressState()
        self._process: asyncio.subprocess.Process | None = None
        self._outcome: BuildOutcome | None = None
        self._start_time: float = 0.0
        self._returncode: int | None = None
        self._cancel_requested: bool = False

    def compose(self) -> ComposeResult:
        with Vertical(id="build-wrap"):
            yield Static(self._tool_key, id="build-title")
            yield Label("", id="build-clock")
            yield Static("starting…", id="build-section")
            yield ProgressBar(total=None, show_eta=False, id="build-progress")
            yield RichLog(
                id="build-log",
                max_lines=_LOG_MAX_LINES,
                highlight=False,
                markup=False,
                auto_scroll=True,
            )
            yield Static(
                "[ctrl-c] cancel   [enter] dismiss when done",
                id="build-status",
            )
        yield Footer()

    # ── lifecycle ────────────────────────────────────────────────────────────

    def on_mount(self) -> None:
        """Kick off the subprocess and the 1-Hz clock timer."""
        self._start_time = time.monotonic()
        self.set_interval(1.0, self._tick_clock)
        self.run_worker(self._run_build(), exclusive=True, name="build")

    def _tick_clock(self) -> None:
        if self.is_running:
            self.elapsed_seconds = int(time.monotonic() - self._start_time)

    def watch_elapsed_seconds(self, seconds: int) -> None:
        h, rem = divmod(seconds, 3600)
        m, s = divmod(rem, 60)
        try:
            clock = self.query_one("#build-clock", Label)
        except Exception:
            return
        clock.update(f"{h:02d}:{m:02d}:{s:02d}")

    # ── subprocess ───────────────────────────────────────────────────────────

    def _resolve_path(self) -> Path | None:
        if self._tool_path is not None:
            return self._tool_path
        try:
            tool = get_tool(self._tool_key)
        except KeyError:
            return None
        return find_tool(tool)

    async def _run_build(self) -> None:
        """Spawn the shell tool and pump its output into the UI."""
        log = self.query_one("#build-log", RichLog)

        path = self._resolve_path()
        if path is None:
            log.write(Text(f"✖  tool not found: {self._tool_key}", style="red bold"))
            self._returncode = 127
            self._finish()
            return

        log.write(Text(f"$ bash {path} {' '.join(self._args)}", style="dim"))

        outcome, process = await stream_build(
            path=path,
            args=self._args,
            on_event=self._on_event,
        )
        self._process = process
        self._outcome = outcome
        self._state = outcome.state
        self._returncode = outcome.returncode
        if not outcome.launched:
            log.write(
                Text(f"✖  failed to launch: {path}", style="red bold")
            )
        self._finish()

    def _on_event(self, event: StageEvent, state: ProgressState) -> None:
        """Update widgets for one parsed event. Called on the worker task."""
        # Keep a live reference so the UI reads a consistent snapshot.
        self._state = state
        try:
            log = self.query_one("#build-log", RichLog)
            section = self.query_one("#build-section", Static)
        except Exception:
            # If widgets aren't mounted yet or the screen is being torn down,
            # just swallow — next event will retry.
            return
        self._render_event(event, log, section)

    def _render_event(
        self,
        event: StageEvent,
        log: RichLog,
        section: Static,
    ) -> None:
        """Push one event into the log + update top-of-screen labels."""
        text: Text
        if event.kind is EventKind.STAGE:
            text = Text(f"==> {event.text}", style="bold magenta")
            section.update(Text(f"── {event.text} ──", style="bold cyan"))
        elif event.kind is EventKind.SECTION:
            text = Text(f"── {event.text} ──", style="bold cyan")
            section.update(Text(f"── {event.text} ──", style="bold cyan"))
            self._update_progress_bar()
        elif event.kind is EventKind.DETAIL:
            text = Text(f" -> {event.text}", style="cyan")
        elif event.kind is EventKind.OK:
            text = Text(f" ✓  {event.text}", style="green")
        elif event.kind is EventKind.WARN:
            text = Text(f"warn {event.text}", style="yellow")
        elif event.kind is EventKind.ERROR:
            text = Text(f"ERR! {event.text}", style="red bold")
        else:
            text = Text(event.raw)
        log.write(text)

    def _update_progress_bar(self) -> None:
        """Advance the progress bar based on ``sections_seen``.

        Rolling denominator (sections_seen + 1) keeps the bar below 100%
        mid-run so users don't see "100% complete" while the build still
        has hours to go.
        """
        try:
            bar = self.query_one("#build-progress", ProgressBar)
        except Exception:
            return
        if self._state.sections_seen < _MIN_SECTIONS_FOR_DETERMINATE:
            bar.update(total=None)
            return
        total = self._state.sections_seen + 1
        bar.update(total=total, progress=self._state.sections_seen)

    def _finish(self) -> None:
        """Called when the subprocess has terminated (for any reason)."""
        self.is_running = False
        try:
            log = self.query_one("#build-log", RichLog)
            bar = self.query_one("#build-progress", ProgressBar)
            status = self.query_one("#build-status", Static)
        except Exception:
            return

        rc = self._returncode if self._returncode is not None else -1

        if rc == 0:
            total = max(self._state.sections_seen, 1)
            bar.update(total=total, progress=total)
            summary = Text.assemble(
                ("✓  build completed", "bold green"),
                f"   ·   {self._state.successes} ok",
                f"   ·   {self._state.warnings} warn",
                f"   ·   exit 0",
            )
        else:
            bar.update(total=1, progress=0)
            reason = "cancelled" if self._cancel_requested else f"exit {rc}"
            summary = Text.assemble(
                ("✖  build failed", "bold red"),
                f"   ·   {reason}",
                f"   ·   {self._state.errors} err",
                f"   ·   {self._state.warnings} warn",
            )

        log.write(Text(""))
        log.write(summary)
        status.update("[enter] dismiss   [ctrl-c] cancel")

    # ── actions ──────────────────────────────────────────────────────────────

    async def action_cancel(self) -> None:
        """Send SIGINT to the child; escalate to SIGTERM after a grace period."""
        if not self.is_running or self._process is None:
            self.dismiss(self._returncode or 0)
            return

        self._cancel_requested = True
        try:
            log = self.query_one("#build-log", RichLog)
            log.write(Text("⚠  cancellation requested — sending SIGINT…", style="yellow"))
        except Exception:
            pass

        await cancel_process(self._process)

    def action_dismiss_if_done(self) -> None:
        """Dismiss only if the build is no longer running."""
        if not self.is_running:
            self.dismiss(self._returncode or 0)
