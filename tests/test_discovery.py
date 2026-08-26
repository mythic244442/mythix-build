"""Tests for mythix_build_system.core.discovery."""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from mythix_build_system.core.discovery import find_tool, resolve_root
from mythix_build_system.core.tools import TOOLS, TOOLS_BY_KEY, get_tool


# ── resolve_root ─────────────────────────────────────────────────────────────


def test_resolve_root_honours_env(
    fake_source_tree: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """$MYTHIX_ROOT wins over CWD heuristics."""
    monkeypatch.setenv("MYTHIX_ROOT", str(fake_source_tree))
    monkeypatch.chdir("/tmp")
    assert resolve_root() == fake_source_tree


def test_resolve_root_ignores_invalid_env(
    fake_source_tree: Path,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A bogus $MYTHIX_ROOT falls through to the directory walk."""
    bogus = tmp_path / "not-a-repo"
    bogus.mkdir()
    monkeypatch.setenv("MYTHIX_ROOT", str(bogus))
    # But CWD is inside the real fake root.
    assert resolve_root(start=fake_source_tree) == fake_source_tree


def test_resolve_root_walks_up(
    fake_source_tree: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Starting deep inside the checkout walks up to the root."""
    deep = fake_source_tree / "mythix-wine_builder" / "patches"
    deep.mkdir(parents=True, exist_ok=True)
    monkeypatch.delenv("MYTHIX_ROOT", raising=False)
    assert resolve_root(start=deep) == fake_source_tree


def test_resolve_root_none_for_unrelated_dir(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """An empty directory has no root to find."""
    monkeypatch.delenv("MYTHIX_ROOT", raising=False)
    # tmp_path has no root markers. resolve_root also probes the package's
    # own on-disk location, so we accept either None or a path that is NOT
    # under tmp_path.
    result = resolve_root(start=tmp_path)
    if result is not None:
        assert tmp_path not in result.parents and result != tmp_path


# ── find_tool ────────────────────────────────────────────────────────────────


@pytest.mark.parametrize("tool", TOOLS, ids=[t.key for t in TOOLS])
def test_find_tool_source_tree(
    fake_source_tree: Path,
    clean_env: None,
    tool,
) -> None:
    """Every tool in the catalogue resolves to its source_relpath."""
    resolved = find_tool(tool, root=fake_source_tree)
    assert resolved == (fake_source_tree / tool.source_relpath).resolve()


def test_find_tool_accepts_key(
    fake_source_tree: Path,
    clean_env: None,
) -> None:
    """find_tool accepts either a Tool or its string key."""
    tool = TOOLS[0]
    by_key = find_tool(tool.key, root=fake_source_tree)
    by_obj = find_tool(tool, root=fake_source_tree)
    assert by_key == by_obj


def test_find_tool_returns_none_for_missing(
    tmp_path: Path,
    clean_env: None,
) -> None:
    """An empty root means no tool is found."""
    empty = tmp_path / "empty"
    empty.mkdir()
    assert find_tool("wine-builder", root=empty) is None


def test_find_tool_unknown_key(fake_source_tree: Path) -> None:
    """Unknown keys raise KeyError."""
    with pytest.raises(KeyError):
        find_tool("not-a-real-tool", root=fake_source_tree)


def test_find_tool_prefers_path(
    fake_source_tree: Path,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """If the tool is on $PATH, that wins over the source tree."""
    # Make a fake installed binary on PATH.
    fake_bin_dir = tmp_path / "fake-bin"
    fake_bin_dir.mkdir()
    fake_binary = fake_bin_dir / "wine-builder"
    fake_binary.write_text("#!/usr/bin/env bash\necho from-path\n")
    fake_binary.chmod(0o755)

    monkeypatch.setenv("PATH", str(fake_bin_dir))
    monkeypatch.setenv("HOME", "/nonexistent")

    resolved = find_tool("wine-builder", root=fake_source_tree)
    assert resolved == fake_binary.resolve()


# ── catalogue integrity ──────────────────────────────────────────────────────


def test_all_tool_keys_unique() -> None:
    """No duplicate keys — the catalogue is a proper mapping."""
    keys = [t.key for t in TOOLS]
    assert len(keys) == len(set(keys))


def test_tools_by_key_matches() -> None:
    for tool in TOOLS:
        assert TOOLS_BY_KEY[tool.key] is tool


def test_get_tool_raises_for_unknown() -> None:
    with pytest.raises(KeyError):
        get_tool("does-not-exist")


def test_every_group_is_known() -> None:
    """Every tool's group is one of the known UI group labels."""
    from mythix_build_system.tui.app import _GROUP_LABELS

    for tool in TOOLS:
        assert tool.group in _GROUP_LABELS, (
            f"Tool {tool.key!r} has group {tool.group!r} which has no UI label"
        )
