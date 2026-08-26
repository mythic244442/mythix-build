"""Regression tests for the Tool catalogue."""

from __future__ import annotations

import pytest

from mythix_build_system.core.tools import TOOLS, TOOLS_BY_KEY, Tool, get_tool


def test_tool_keys_are_unique() -> None:
    keys = [t.key for t in TOOLS]
    assert len(keys) == len(set(keys)), f"duplicate keys: {keys}"


def test_tools_by_key_matches_tools() -> None:
    assert set(TOOLS_BY_KEY) == {t.key for t in TOOLS}
    assert len(TOOLS_BY_KEY) == len(TOOLS)


def test_all_tools_have_a_known_group() -> None:
    """Keep the catalogue in sync with the launcher's group-label map."""
    allowed = {"build", "hybrid", "install", "gui"}
    for tool in TOOLS:
        assert tool.group in allowed, f"{tool.key} has unknown group {tool.group!r}"


def test_non_interactive_defaults_to_false() -> None:
    """All tools default to the safe, full-TTY-handoff path.

    Flipping this to True routes a tool through BuildScreen on Enter — only
    do that once you've verified the tool has no fzf/zenity/read prompts.
    """
    for tool in TOOLS:
        assert tool.non_interactive is False, (
            f"{tool.key} is marked non_interactive — make sure it really "
            "has no interactive prompts (no fzf/zenity/read)."
        )


def test_get_tool_raises_keyerror_for_unknown() -> None:
    with pytest.raises(KeyError):
        get_tool("definitely-not-a-real-tool")


def test_tool_is_frozen() -> None:
    """Tool instances must be immutable — otherwise monkeypatching one would
    silently mutate the module-level TOOLS tuple for other tests."""
    import dataclasses

    t = TOOLS[0]
    with pytest.raises(dataclasses.FrozenInstanceError):
        t.non_interactive = True  # type: ignore[misc]
