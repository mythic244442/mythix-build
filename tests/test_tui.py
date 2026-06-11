"""Headless rendering tests for the Textual launcher."""

from __future__ import annotations

from pathlib import Path

import pytest

from mythix_build_system.core import TOOLS
from mythix_build_system.tui import LauncherApp


@pytest.mark.asyncio
async def test_launcher_composes(
    fake_source_tree: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The app mounts banner, subtitle, and menu with all tools enabled."""
    from textual.widgets import OptionList, Static

    monkeypatch.setenv("MYTHIX_ROOT", str(fake_source_tree))
    monkeypatch.setenv("PATH", "/nonexistent-for-tui-tests")

    app = LauncherApp()
    async with app.run_test(size=(120, 40)) as pilot:
        await pilot.pause()

        banner = app.query_one("#banner", Static)
        subtitle = app.query_one("#subtitle", Static)
        menu = app.query_one("#menu", OptionList)

        assert "mythix-build" in str(subtitle.renderable)
        assert "⣀⡀" in str(banner.renderable)

        # 4 group headings + 9 tools = 13 options total.
        assert menu.option_count == 13
        # Headings are disabled, tool rows are enabled.
        enabled = [o for o in menu._options if not o.disabled]
        assert len(enabled) == len(TOOLS)


@pytest.mark.asyncio
async def test_launcher_refresh_no_duplicate_ids(
    fake_source_tree: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Pressing 'r' repopulates the menu in place without duplicate-id errors.

    Regression test: an earlier implementation called `OptionList.remove()`
    (async) and immediately re-mounted with the same id, which raced.
    """
    from textual.widgets import OptionList

    monkeypatch.setenv("MYTHIX_ROOT", str(fake_source_tree))
    monkeypatch.setenv("PATH", "/nonexistent-for-tui-tests")

    app = LauncherApp()
    async with app.run_test(size=(120, 40)) as pilot:
        await pilot.pause()
        menu = app.query_one("#menu", OptionList)
        initial = menu.option_count

        for _ in range(3):
            await pilot.press("r")
            await pilot.pause()
            assert menu.option_count == initial


@pytest.mark.asyncio
async def test_launcher_quit_binding(
    fake_source_tree: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """q cleanly exits the app."""
    monkeypatch.setenv("MYTHIX_ROOT", str(fake_source_tree))
    monkeypatch.setenv("PATH", "/nonexistent-for-tui-tests")

    app = LauncherApp()
    async with app.run_test(size=(120, 40)) as pilot:
        await pilot.pause()
        await pilot.press("q")
        await pilot.pause()
    # If we got here without hanging, the quit binding worked.


@pytest.mark.asyncio
async def test_launcher_focuses_menu_on_mount(
    fake_source_tree: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Menu must be focused immediately so arrow keys work on first render.

    Regression: without focus-on-mount the first arrow-key press was
    swallowed and options visibly misaligned until the user clicked out and
    back in.
    """
    from textual.widgets import OptionList

    monkeypatch.setenv("MYTHIX_ROOT", str(fake_source_tree))
    monkeypatch.setenv("PATH", "/nonexistent-for-tui-tests")

    app = LauncherApp()
    async with app.run_test(size=(120, 40)) as pilot:
        await pilot.pause()
        assert app.focused is app.query_one("#menu", OptionList), (
            f"menu should be focused on mount, got {app.focused!r}"
        )


@pytest.mark.asyncio
async def test_launcher_all_icons_are_visually_2cell(
    fake_source_tree: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """All tool icons must render at the same visual width.

    Regression: mixing 1-cell symbols (``⇌``, ``⚙``) with 2-cell emojis
    shifted subsequent columns by one cell per row, and Textual's initial
    layout pass caught the wrong heights → rows appeared to merge.
    """
    from wcwidth import wcswidth  # type: ignore[import-untyped]

    from mythix_build_system.core import TOOLS

    widths = {tool.key: wcswidth(tool.icon) for tool in TOOLS}
    unique = set(widths.values())
    assert unique == {2}, (
        f"all icons must be visually 2-cell wide, got {widths}"
    )


@pytest.mark.asyncio
async def test_launcher_enter_routes_by_non_interactive_flag(
    fake_source_tree: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Enter on an interactive tool uses suspend; Enter on a non-interactive
    tool pushes BuildScreen.

    Both code paths are instrumented here so we can assert routing without
    actually suspending the terminal or spawning bash.
    """
    from textual.widgets import OptionList

    monkeypatch.setenv("MYTHIX_ROOT", str(fake_source_tree))
    monkeypatch.setenv("PATH", "/nonexistent-for-tui-tests")

    calls: list[tuple[str, str]] = []  # (mode, key)

    def fake_launch(self, key: str, *, mode: str = "suspend") -> None:
        calls.append((mode, key))

    monkeypatch.setattr(LauncherApp, "_launch_tool", fake_launch)

    # Flip wine-builder to non_interactive=True for the scope of this test.
    # Tool is a frozen dataclass, so we swap in a `dataclasses.replace()`d
    # copy via the module's get_tool lookup function rather than mutating.
    import dataclasses

    from mythix_build_system.core.tools import TOOLS_BY_KEY
    from mythix_build_system.tui import app as app_module

    swapped = {
        key: (dataclasses.replace(tool, non_interactive=True)
              if key == "wine-builder" else tool)
        for key, tool in TOOLS_BY_KEY.items()
    }
    monkeypatch.setattr(app_module, "get_tool", lambda k: swapped[k])

    app = LauncherApp()
    async with app.run_test(size=(120, 40)) as pilot:
        await pilot.pause()
        menu = app.query_one("#menu", OptionList)

        # Find indices for wine-builder (non-interactive) and proton-builder
        # (interactive) in the menu.
        def index_of(key: str) -> int:
            for idx in range(menu.option_count):
                if menu.get_option_at_index(idx).id == key:
                    return idx
            raise AssertionError(f"{key} not in menu")

        wine_idx = index_of("wine-builder")
        proton_idx = index_of("proton-builder")

        # Drive Enter by dispatching OptionSelected messages — the real
        # code path through on_option_list_option_selected.
        app.on_option_list_option_selected(
            OptionList.OptionSelected(menu, wine_idx)
        )
        app.on_option_list_option_selected(
            OptionList.OptionSelected(menu, proton_idx)
        )

    assert ("build", "wine-builder") in calls
    assert ("suspend", "proton-builder") in calls


@pytest.mark.asyncio
async def test_launcher_b_and_l_keys_force_modes(
    fake_source_tree: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """'b' forces BuildScreen; 'l' forces suspend — regardless of the flag."""
    from textual.widgets import OptionList

    monkeypatch.setenv("MYTHIX_ROOT", str(fake_source_tree))
    monkeypatch.setenv("PATH", "/nonexistent-for-tui-tests")

    calls: list[tuple[str, str]] = []

    def fake_launch(self, key: str, *, mode: str = "suspend") -> None:
        calls.append((mode, key))

    monkeypatch.setattr(LauncherApp, "_launch_tool", fake_launch)

    app = LauncherApp()
    async with app.run_test(size=(120, 40)) as pilot:
        await pilot.pause()
        menu = app.query_one("#menu", OptionList)
        # Move highlight to the first enabled tool row (skip group heading).
        for idx in range(menu.option_count):
            opt = menu.get_option_at_index(idx)
            if not opt.disabled:
                menu.highlighted = idx
                break
        await pilot.pause()

        first_key = menu.get_option_at_index(menu.highlighted).id
        assert first_key is not None

        await pilot.press("b")
        await pilot.pause()
        await pilot.press("l")
        await pilot.pause()

    # Both key presses should have routed the same tool into opposite modes.
    modes = [mode for mode, key in calls if key == first_key]
    assert "build" in modes, f"expected 'build' in {modes}"
    assert "suspend" in modes, f"expected 'suspend' in {modes}"


@pytest.mark.asyncio
async def test_launcher_b_key_ignores_disabled_rows(
    fake_source_tree: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """'b' pressed while a group-heading row is highlighted is a no-op.

    Regression guard: an earlier draft used ``option_list.highlighted`` to
    unconditionally look up the id, which was None for separators and
    crashed in _launch_tool.
    """
    from textual.widgets import OptionList

    monkeypatch.setenv("MYTHIX_ROOT", str(fake_source_tree))
    monkeypatch.setenv("PATH", "/nonexistent-for-tui-tests")

    calls: list[str] = []
    monkeypatch.setattr(
        LauncherApp,
        "_launch_tool",
        lambda self, key, *, mode="suspend": calls.append(key),
    )

    app = LauncherApp()
    async with app.run_test(size=(120, 40)) as pilot:
        await pilot.pause()
        menu = app.query_one("#menu", OptionList)
        # First row is the "── build ──" heading — disabled, id=None.
        menu.highlighted = 0
        await pilot.pause()
        assert menu.get_option_at_index(0).disabled

        await pilot.press("b")
        await pilot.pause()

    assert calls == [], f"disabled row should not launch anything, got {calls}"


@pytest.mark.asyncio
async def test_launcher_option_list_has_definite_width(
    fake_source_tree: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """OptionList must have a definite width, not height:auto + max-width.

    Regression: the previous CSS used ``max-width: 90; height: auto``
    inside an unsized Vertical, which made Textual's layout pass resolve
    row heights lazily and caused merged rows on first paint.
    """
    from textual.widgets import OptionList

    monkeypatch.setenv("MYTHIX_ROOT", str(fake_source_tree))
    monkeypatch.setenv("PATH", "/nonexistent-for-tui-tests")

    app = LauncherApp()
    async with app.run_test(size=(120, 40)) as pilot:
        await pilot.pause()
        menu = app.query_one("#menu", OptionList)
        # Rendered region width must be a concrete, positive cell count.
        assert menu.region.width > 0, menu.region
        # And it should match the configured 94 cells from the CSS.
        assert menu.region.width == 94, menu.region.width
