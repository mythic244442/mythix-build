"""Tests for the stage-marker parser."""

from __future__ import annotations

import pytest

from mythix_build_system.tui.progress import (
    EventKind,
    ProgressState,
    parse_line,
    strip_ansi,
)


def test_strip_ansi_removes_colour_codes() -> None:
    coloured = "\x1b[1;35m==>\x1b[0m \x1b[1mConfiguring\x1b[0m"
    assert strip_ansi(coloured) == "==> Configuring"


def test_strip_ansi_preserves_plain_text() -> None:
    assert strip_ansi("plain text here") == "plain text here"


class TestParseLine:
    """Cover every EventKind with realistic shell-tool output."""

    def test_stage_heading(self) -> None:
        ev = parse_line("==> Configuring Wine\n")
        assert ev.kind is EventKind.STAGE
        assert ev.text == "Configuring Wine"

    def test_stage_heading_with_ansi(self) -> None:
        ev = parse_line("\x1b[1;35m==> \x1b[0m\x1b[1mBuilding 64-bit\x1b[0m\n")
        assert ev.kind is EventKind.STAGE
        assert ev.text == "Building 64-bit"

    def test_section_separator(self) -> None:
        ev = parse_line("── MinGW cross-compiler check ──\n")
        assert ev.kind is EventKind.SECTION
        assert ev.text == "MinGW cross-compiler check"

    def test_section_separator_with_leading_newline_stripped(self) -> None:
        # ``sep()`` prints "\n── title ──" — the caller strips line-by-line
        # so we only see the "── title ──" part.
        ev = parse_line("── Patch application ──")
        assert ev.kind is EventKind.SECTION
        assert ev.text == "Patch application"

    def test_detail_line(self) -> None:
        ev = parse_line(" -> Source dir  : /home/blu2442/wine\n")
        assert ev.kind is EventKind.DETAIL
        assert ev.text == "Source dir  : /home/blu2442/wine"

    def test_ok_tick(self) -> None:
        ev = parse_line(" ✓  MinGW cross-compiler: 14.1\n")
        assert ev.kind is EventKind.OK
        assert ev.text == "MinGW cross-compiler: 14.1"

    def test_warn(self) -> None:
        ev = parse_line("warn Patch had fuzz — check for .rej files\n")
        assert ev.kind is EventKind.WARN
        assert ev.text == "Patch had fuzz — check for .rej files"

    def test_err(self) -> None:
        ev = parse_line("ERR! configure not found\n")
        assert ev.kind is EventKind.ERROR
        assert ev.text == "configure not found"

    def test_plain_line(self) -> None:
        ev = parse_line("make[1]: Entering directory '/tmp/build'\n")
        assert ev.kind is EventKind.PLAIN
        assert ev.text == "make[1]: Entering directory '/tmp/build'"

    def test_empty_line(self) -> None:
        ev = parse_line("\n")
        assert ev.kind is EventKind.PLAIN
        assert ev.text == ""

    @pytest.mark.parametrize("line", [
        "==>no-space",              # no space after ==> → plain
        " => indirect",             # wrong marker → plain
        "---- sep ----",            # wrong separator chars → plain
    ])
    def test_non_markers_are_plain(self, line: str) -> None:
        assert parse_line(line).kind is EventKind.PLAIN


class TestProgressState:
    def test_fresh_state_is_zeroed(self) -> None:
        s = ProgressState()
        assert s.sections_seen == 0
        assert s.successes == 0
        assert s.warnings == 0
        assert s.errors == 0
        assert s.current_stage == ""
        assert s.current_section == ""

    def test_stage_updates_current_stage(self) -> None:
        s = ProgressState()
        s.update(parse_line("==> Configuring"))
        assert s.current_stage == "Configuring"
        assert s.sections_seen == 0  # stage, not section

    def test_section_advances_counter(self) -> None:
        s = ProgressState()
        for title in ["Prep", "Configure", "Compile", "Install"]:
            s.update(parse_line(f"── {title} ──"))
        assert s.sections_seen == 4
        assert s.current_section == "Install"

    def test_ok_warn_err_tallies(self) -> None:
        s = ProgressState()
        s.update(parse_line(" ✓  first"))
        s.update(parse_line(" ✓  second"))
        s.update(parse_line("warn maybe bad"))
        s.update(parse_line("ERR! very bad"))
        assert s.successes == 2
        assert s.warnings == 1
        assert s.errors == 1

    def test_plain_lines_are_noop(self) -> None:
        s = ProgressState()
        for _ in range(10):
            s.update(parse_line("make: doing things"))
        assert s.sections_seen == 0
        assert s.successes == 0

    def test_realistic_neutron_builder_session(self) -> None:
        """Feed a plausible slice of neutron-builder output through state."""
        lines = [
            "",
            "── Proton Wine Build Core ──",
            " -> Source key  : proton-wine",
            " -> Source dir  : /home/blu/wine",
            "── MinGW cross-compiler check ──",
            " ✓  64-bit MinGW: 14.1",
            " ✓  32-bit MinGW: 14.1",
            "── Patch application ──",
            " -> Applying: 0001-foo.patch",
            "warn Patch 0002-bar.patch had fuzz",
            " ✓  2 patch(es) applied",
            "── Loading configuration ──",
            " ✓  Config loaded",
        ]
        s = ProgressState()
        for line in lines:
            s.update(parse_line(line))
        assert s.sections_seen == 4
        assert s.successes == 4
        assert s.warnings == 1
        assert s.errors == 0
        assert s.current_section == "Loading configuration"
