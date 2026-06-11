"""Smoke tests for the Click CLI."""

from __future__ import annotations

from pathlib import Path

import pytest
from click.testing import CliRunner

from mythix_build_system import __version__
from mythix_build_system.cli import main


def test_version_subcommand() -> None:
    runner = CliRunner()
    result = runner.invoke(main, ["version"])
    assert result.exit_code == 0
    assert result.output.strip() == __version__


def test_help() -> None:
    runner = CliRunner()
    result = runner.invoke(main, ["--help"])
    assert result.exit_code == 0
    assert "mythix-build" in result.output
    assert "launch" in result.output
    assert "doctor" in result.output


def test_list_keys_format() -> None:
    runner = CliRunner()
    result = runner.invoke(main, ["list", "--format=keys"])
    assert result.exit_code == 0
    keys = result.output.strip().splitlines()
    assert "wine-builder" in keys
    assert "neutron-builder" in keys
    assert "wine_toolz" in keys


def test_launch_unknown_tool(monkeypatch: pytest.MonkeyPatch) -> None:
    runner = CliRunner()
    result = runner.invoke(main, ["launch", "totally-fake-tool"])
    assert result.exit_code == 2
    assert "Unknown tool" in result.output


def test_build_unknown_tool(monkeypatch: pytest.MonkeyPatch) -> None:
    """`mythix build` rejects unknown tool keys before spawning a TUI."""
    runner = CliRunner()
    result = runner.invoke(main, ["build", "totally-fake-tool"])
    assert result.exit_code == 2
    assert "Unknown tool" in result.output


def test_build_help_mentions_non_interactive() -> None:
    runner = CliRunner()
    result = runner.invoke(main, ["build", "--help"])
    assert result.exit_code == 0
    assert "live progress" in result.output or "non-interactive" in result.output


def test_doctor_runs(
    monkeypatch: pytest.MonkeyPatch,
    fake_source_tree: Path,
) -> None:
    monkeypatch.setenv("MYTHIX_ROOT", str(fake_source_tree))
    monkeypatch.setenv("PATH", "/nonexistent-for-doctor")
    runner = CliRunner()
    result = runner.invoke(main, ["doctor"])
    assert result.exit_code == 0
    assert "mythix-build doctor" in result.output
    assert str(fake_source_tree) in result.output
