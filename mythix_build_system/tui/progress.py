"""Stage-marker parser for mythix-build shell tools.

The shell tools (``neutron-build-core.sh`` et al.) print structured progress
markers defined in their tiny pretty-printer prelude::

    msg()  → '==> <heading>'          # major stage heading
    msg2() → ' -> <detail>'           # sub-step / status line
    sep()  → '── <title> ──'          # section separator
    ok()   → ' ✓  <message>'          # success tick
    warn() → 'warn <message>'         # warning (stderr)
    err()  → 'ERR! <message>'         # error, aborts (stderr)

We parse these into :class:`StageEvent` records so the BuildScreen can:

* update the current stage heading,
* increment a determinate progress bar when a new section is seen,
* style warnings/errors in the live log tail,
* tally success ticks for the summary panel.

This module is pure (no I/O) so it can be unit-tested easily.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum
from typing import Final

# Strip ANSI CSI sequences before matching — the shell tools use colour.
# Pattern covers the standard ``ESC[…m`` and a few cursor moves.
_ANSI_RE: Final[re.Pattern[str]] = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def strip_ansi(line: str) -> str:
    """Return ``line`` with ANSI escape sequences removed."""
    return _ANSI_RE.sub("", line)


class EventKind(str, Enum):
    """Kinds of structured log events emitted by shell tools."""

    STAGE = "stage"       # '==> heading'  (msg)
    SECTION = "section"   # '── title ──' (sep)
    DETAIL = "detail"     # ' -> detail' (msg2)
    OK = "ok"             # ' ✓  msg'    (ok)
    WARN = "warn"         # 'warn msg'    (warn)
    ERROR = "error"       # 'ERR! msg'   (err)
    PLAIN = "plain"       # anything else


@dataclass(frozen=True, slots=True)
class StageEvent:
    """One parsed log line."""

    kind: EventKind
    text: str
    """The *payload* text (heading, message, etc.) with markers stripped."""

    raw: str
    """The original line (ANSI-stripped) for logging."""


# Match order matters — ``sep`` and ``msg`` both start the line, but ``sep``'s
# ``── title ──`` pattern is more specific so it's checked first.
_STAGE_RE: Final[re.Pattern[str]] = re.compile(r"^==>\s+(.+?)\s*$")
_SECTION_RE: Final[re.Pattern[str]] = re.compile(r"^──\s+(.+?)\s+──\s*$")
_DETAIL_RE: Final[re.Pattern[str]] = re.compile(r"^\s*->\s+(.+?)\s*$")
_OK_RE: Final[re.Pattern[str]] = re.compile(r"^\s*✓\s+(.+?)\s*$")
_WARN_RE: Final[re.Pattern[str]] = re.compile(r"^warn\s+(.+?)\s*$")
_ERR_RE: Final[re.Pattern[str]] = re.compile(r"^ERR!\s+(.+?)\s*$")


def parse_line(line: str) -> StageEvent:
    """Classify ``line`` into a :class:`StageEvent`.

    The line may contain ANSI colour codes (shell output is colourised);
    they're stripped before matching.
    """
    raw = strip_ansi(line).rstrip("\r\n")
    stripped = raw.lstrip()

    if m := _SECTION_RE.match(stripped):
        return StageEvent(EventKind.SECTION, m.group(1), raw)
    if m := _STAGE_RE.match(stripped):
        return StageEvent(EventKind.STAGE, m.group(1), raw)
    if m := _DETAIL_RE.match(raw):  # keep leading whitespace to match ' -> '
        return StageEvent(EventKind.DETAIL, m.group(1), raw)
    if m := _OK_RE.match(raw):
        return StageEvent(EventKind.OK, m.group(1), raw)
    if m := _WARN_RE.match(stripped):
        return StageEvent(EventKind.WARN, m.group(1), raw)
    if m := _ERR_RE.match(stripped):
        return StageEvent(EventKind.ERROR, m.group(1), raw)
    return StageEvent(EventKind.PLAIN, raw, raw)


@dataclass(slots=True)
class ProgressState:
    """Running tally used by the BuildScreen to drive the progress bar.

    We don't know the total number of sections up-front (different tools and
    different sources emit different stage counts), so the progress bar uses
    the *highest observed section index* as a rolling denominator:

    * First section seen → progress = 1 / 1 = 100% would look done, so we
      clamp display to "indeterminate pulse" until we've seen ≥ 2 sections.
    * Thereafter the bar is determinate, advancing one unit per new section.
    """

    current_stage: str = ""
    """Latest ``msg()`` heading, e.g. ``'Building 64-bit'``."""

    current_section: str = ""
    """Latest ``sep()`` title, e.g. ``'MinGW cross-compiler check'``."""

    sections_seen: int = 0
    """Count of :class:`EventKind.SECTION` events observed so far."""

    successes: int = 0
    """Count of :class:`EventKind.OK` events (✓)."""

    warnings: int = 0
    """Count of :class:`EventKind.WARN` events."""

    errors: int = 0
    """Count of :class:`EventKind.ERROR` events (sets the screen to failed)."""

    def update(self, event: StageEvent) -> None:
        """Fold ``event`` into the running state."""
        if event.kind is EventKind.STAGE:
            self.current_stage = event.text
        elif event.kind is EventKind.SECTION:
            self.current_section = event.text
            self.sections_seen += 1
        elif event.kind is EventKind.OK:
            self.successes += 1
        elif event.kind is EventKind.WARN:
            self.warnings += 1
        elif event.kind is EventKind.ERROR:
            self.errors += 1
