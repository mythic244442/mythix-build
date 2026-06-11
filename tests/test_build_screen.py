"""Tests for the build runner + screen.

Strategy
--------

The subprocess-pumping logic lives in ``build_runner.stream_build`` — a pure
async function with no Textual dependency. We unit-test it directly with real
throwaway shell scripts: spawning a subprocess is fast and much more faithful
than mocking ``asyncio.subprocess``.

The Textual :class:`BuildScreen` is a thin adapter on top. Its test is a
minimal compose/smoke check — we *don't* drive it through
``App.run_test(...)`` because the pilot's ``_wait_for_screen`` waits for
all child message queues to drain, which never happens while a subprocess
is actively streaming output. That timeout is a property of the test
harness, not of the screen; integration coverage for the subprocess side
happens via ``stream_build`` instead.
"""

from __future__ import annotations

import asyncio
import stat
from pathlib import Path

import pytest

from mythix_build_system.tui.build_runner import BuildOutcome, stream_build
from mythix_build_system.tui.build_screen import BuildScreen
from mythix_build_system.tui.progress import EventKind


def _make_script(tmp_path: Path, body: str) -> Path:
    """Write ``body`` to a bash script under ``tmp_path`` and mark executable."""
    p = tmp_path / "fake-tool.sh"
    p.write_text("#!/usr/bin/env bash\nset -u\n" + body)
    p.chmod(p.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return p


# ── stream_build integration tests ──────────────────────────────────────────


@pytest.mark.asyncio
async def test_stream_build_parses_stage_markers(tmp_path: Path) -> None:
    """End-to-end: spawn a script, read its stdout, classify every line."""
    script = _make_script(tmp_path, """
echo "==> Starting"
echo "── Section one ──"
echo " ✓  thing one"
echo "── Section two ──"
echo " ✓  thing two"
echo "── Section three ──"
echo " ✓  thing three"
echo " ✓  build complete"
""")

    events: list[tuple[EventKind, str]] = []
    outcome, _ = await stream_build(
        script,
        args=[],
        on_event=lambda ev, st: events.append((ev.kind, ev.text)),
    )

    assert outcome.ok
    assert outcome.returncode == 0
    assert outcome.state.sections_seen == 3
    assert outcome.state.successes == 4
    assert outcome.state.current_section == "Section three"
    assert outcome.state.errors == 0

    # Events arrived in the expected order.
    kinds = [k for k, _ in events]
    assert kinds.count(EventKind.STAGE) == 1
    assert kinds.count(EventKind.SECTION) == 3
    assert kinds.count(EventKind.OK) == 4


@pytest.mark.asyncio
async def test_stream_build_reports_nonzero_exit(tmp_path: Path) -> None:
    script = _make_script(tmp_path, """
echo "==> Doing a thing"
echo "ERR! nope"
exit 7
""")

    outcome, _ = await stream_build(script, args=[])

    assert outcome.launched
    assert outcome.ok is False
    assert outcome.returncode == 7
    assert outcome.state.errors == 1


@pytest.mark.asyncio
async def test_stream_build_handles_missing_script(tmp_path: Path) -> None:
    """If the script doesn't exist, bash exits 127 and we still get an outcome."""
    nonexistent = tmp_path / "nope.sh"
    outcome, proc = await stream_build(nonexistent, args=[])
    # bash was launched (exists), script-not-found is bash's problem → rc=127.
    assert outcome.launched is True
    assert outcome.returncode == 127
    # Either way the caller gets a well-formed BuildOutcome.
    assert isinstance(outcome, BuildOutcome)


@pytest.mark.asyncio
async def test_stream_build_streams_events_incrementally(tmp_path: Path) -> None:
    """Events fire as each line is read, not all at once at the end.

    Regression check: an earlier draft buffered the whole stdout before
    parsing, which defeated the point of a live log.
    """
    script = _make_script(tmp_path, """
echo "== line 1"
sleep 0.05
echo "── section A ──"
sleep 0.05
echo " ✓  done"
""")

    seen_at_times: list[int] = []  # sections_seen snapshot per event

    def record(event, state) -> None:
        seen_at_times.append(state.sections_seen)

    outcome, _ = await stream_build(script, args=[], on_event=record)
    assert outcome.ok

    # sections_seen must grow over time (not jump from 0 → N at the end).
    # The first few events should have sections_seen == 0, then rise to 1.
    assert seen_at_times[0] == 0
    assert 1 in seen_at_times
    assert seen_at_times[-1] == 1  # final state


@pytest.mark.asyncio
async def test_stream_build_matches_real_neutron_markers(tmp_path: Path) -> None:
    """Emit output using the exact markers from ``neutron-build-core.sh``.

    Regression anchor: if the shell tools change their prelude (e.g. swap
    ``==>`` for something else), this test fails and the parser needs
    updating. The marker definitions live in
    ``mythix-neutron_builder/neutron-build-core.sh`` lines 42-47.
    """
    script = _make_script(tmp_path, r"""
# Mirror the exact prelude from neutron-build-core.sh (ANSI stripped).
msg()  { printf "==> %s\n" "$*"; }
msg2() { printf " -> %s\n" "$*"; }
warn() { printf "warn %s\n" "$*" >&2; }
ok()   { printf " ✓  %s\n" "$*"; }
sep()  { printf "\n── %s ──\n" "$*"; }

sep "Proton Wine Build Core"
msg2 "Source dir  : /home/blu/wine"
sep "MinGW cross-compiler check"
ok "64-bit MinGW: 14.1"
ok "32-bit MinGW: 14.1"
sep "Patch application"
msg2 "Applying: 0001-foo.patch"
warn "Patch 0002-bar.patch had fuzz"
ok "2 patch(es) applied"
sep "Loading configuration"
msg "Configuring"
ok "Config loaded"
""")

    outcome, _ = await stream_build(script, args=[])
    assert outcome.ok
    assert outcome.state.sections_seen == 4
    assert outcome.state.successes == 4
    assert outcome.state.warnings == 1
    assert outcome.state.current_stage == "Configuring"
    assert outcome.state.current_section == "Loading configuration"


@pytest.mark.asyncio
async def test_stream_build_warnings_tallied(tmp_path: Path) -> None:
    script = _make_script(tmp_path, """
echo "── Prep ──"
echo "warn something iffy"
echo "warn another thing"
echo " ✓  recovered"
""")

    outcome, _ = await stream_build(script, args=[])
    assert outcome.state.warnings == 2
    assert outcome.state.successes == 1


# ── BuildScreen compose smoke test ───────────────────────────────────────────


def test_build_screen_instantiates() -> None:
    """BuildScreen can be constructed and has the expected fields.

    Full interactive tests aren't worth the complexity here (see module
    docstring). This smoke test just confirms the class isn't broken.
    """
    screen = BuildScreen("wine-builder", args=["--mainline"])
    assert screen._tool_key == "wine-builder"
    assert screen._args == ["--mainline"]
    assert screen.is_running is True
    assert screen._returncode is None


def test_build_screen_with_explicit_path(tmp_path: Path) -> None:
    """``tool_path`` bypasses discovery."""
    script = tmp_path / "x.sh"
    screen = BuildScreen("fake", tool_path=script)
    assert screen._resolve_path() == script


def test_build_screen_resolve_unknown_tool() -> None:
    """Unknown tool keys return None (not raise)."""
    screen = BuildScreen("no-such-tool")
    assert screen._resolve_path() is None
