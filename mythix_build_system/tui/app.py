"""Main Textual application for the mythix-build launcher.

Mirrors the look of ``mythix-build.sh``'s menu (wolf banner + tool list) but
rendered as a modern TUI with keyboard navigation, grouping, and a footer of
keybinds. Tool selection hands off to :func:`mythix_build_system.core.run_tool`,
which runs the shell script with inherited stdio so ``fzf`` / ``zenity``
work transparently.
"""

from __future__ import annotations

from rich.text import Text
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Vertical
from textual.widgets import Footer, OptionList, Static
from textual.widgets.option_list import Option, Separator

from mythix_build_system import __version__
from mythix_build_system.core import TOOLS, find_tool, get_tool, run_tool

# Pre-rendered wolf art — same braille glyphs the shell launcher uses, so the
# two launchers look like the same program in different clothes.
_WOLF_ART = (
    "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀\n"
    "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠸⠁⠸⢳⡄⠀⠀⠀⠀⠀⠀⠀⠀\n"
    "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢠⠃⠀⠀⢸⠸⠀⡠⣄⠀⠀⠀⠀⠀\n"
    "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡠⠃⠀⠀⢠⣞⣀⡿⠀⠀⣧⠀⠀⠀⠀\n"
    "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣠⡖⠁⠀⠀⠀⢸⠈⢈⡇⠀⢀⡏⠀⠀⠀⠀\n"
    "⠀⠀⠀⠀⠀⠀⠀⠀⠀⡴⠩⢠⡴⠀⠀⠀⠀⠀⠈⡶⠉⠀⠀⡸⠀⠀⠀⠀⠀\n"
    "⠀⠀⠀⠀⠀⠀⠀⢀⠎⢠⣇⠏⠀⠀⠀⠀⠀⠀⠀⠁⠀⢀⠄⡇⠀⠀⠀⠀⠀\n"
    "⠀⠀⠀⠀⠀⠀⢠⠏⠀⢸⣿⣴⠀⠀⠀⠀⠀⠀⣆⣀⢾⢟⠴⡇⠀⠀⠀⠀⠀\n"
    "⠀⠀⠀⠀⠀⢀⣿⠀⠠⣄⠸⢹⣦⠀⠀⡄⠀⠀⢋⡟⠀⠀⠁⣇⠀⠀⠀⠀⠀\n"
    "⠀⠀⠀⠀⢀⡾⠁⢠⠀⣿⠃⠘⢹⣦⢠⣼⠀⠀⠉⠀⠀⠀⠀⢸⡀⠀⠀⠀⠀\n"
    "⠀⠀⢀⣴⠫⠤⣶⣿⢀⡏⠀⠀⠘⢸⡟⠋⠀⠀⠀⠀⠀⠀⠀⠀⢳⠀⠀⠀⠀\n"
    "⠐⠿⢿⣿⣤⣴⣿⣣⢾⡄⠀⠀⠀⠀⠳⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢣⠀⠀⠀\n"
    "⠀⠀⠀⣨⣟⡍⠉⠚⠹⣇⡄⠀⠀⠀⠀⠀⠀⠀⠀⠈⢦⠀⠀⢀⡀⣾⡇⠀⠀\n"
    "⠀⠀⢠⠟⣹⣧⠃⠀⠀⢿⢻⡀⢄⠀⠀⠀⠀⠐⣦⡀⣸⣆⠀⣾⣧⣯⢻⠀⠀\n"
    "⠀⠀⠘⣰⣿⣿⡄⡆⠀⠀⠀⠳⣼⢦⡘⣄⠀⠀⡟⡷⠃⠘⢶⣿⡎⠻⣆⠀⠀\n"
    "⠀⠀⠀⡟⡿⢿⡿⠀⠀⠀⠀⠀⠙⠀⠻⢯⢷⣼⠁⠁⠀⠀⠀⠀⠀⡄⡈⢆⠀\n"
    "⠀⠀⠀⠀⡇⣿⡅⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠙⠦⠀⠀⠀⠀⠀⠀⡇⢹⢿⡀\n"
    "⠀⠀⠀⠀⠁⠛⠓⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠼⠇⠁"
)

# Human-friendly labels for each tool group, shown as separator headings.
_GROUP_LABELS: dict[str, str] = {
    "build":   "── build ──────────────────────────────",
    "hybrid":  "── hybrid ─────────────────────────────",
    "install": "── install / deploy ───────────────────",
    "gui":     "── GUI ────────────────────────────────",
}


class LauncherApp(App[None]):
    """mythix-build main menu."""

    TITLE = "mythix-build"
    SUB_TITLE = f"v{__version__}"

    # ── Layout notes ────────────────────────────────────────────────────────
    # Giving OptionList a fixed ``width`` (rather than ``max-width`` +
    # ``height: auto`` nested inside an unsized Vertical) is what stops the
    # first-render "rows merging" bug. Textual's layout pass needs a definite
    # width to measure each Option's height consistently; ambiguous sizing
    # made row heights shift after the first focus change.
    CSS = """
    Screen {
        align: center top;
        background: $background;
    }

    #banner, #subtitle, #hint {
        width: 100%;
        content-align: center middle;
    }

    #banner {
        color: magenta;
        text-style: bold;
        padding: 1 0 0 0;
    }

    #subtitle {
        color: magenta;
        text-style: bold;
        padding: 0 0 1 0;
    }

    #hint {
        color: $text-muted;
        padding: 0 0 1 0;
    }

    #menu-wrap {
        width: auto;
        height: auto;
        align: center top;
    }

    OptionList {
        border: round magenta;
        background: $surface;
        width: 94;
        height: auto;
        padding: 0 1;
    }

    OptionList > .option-list--option-highlighted {
        background: $primary 30%;
        color: $text;
        text-style: bold;
    }
    """

    BINDINGS = [
        Binding("q,escape", "quit", "Quit", priority=True),
        Binding("?", "help", "Help"),
        Binding("r", "refresh", "Refresh"),
        # Two forced-mode keys for the currently-highlighted menu row:
        #   B = open in BuildScreen (captured output, live progress)
        #   L = legacy suspend-and-handoff (full TTY for the shell tool)
        # Enter picks the default for that tool (see Tool.non_interactive).
        Binding("b", "launch_highlighted('build')", "Build view", show=True),
        Binding("l", "launch_highlighted('suspend')", "Legacy launch", show=True),
    ]

    def compose(self) -> ComposeResult:
        yield Static(_WOLF_ART, id="banner")
        yield Static(f":3  mythix-build  •  Wine · Neutron · Proton  •  v{__version__}", id="subtitle")
        yield Static(
            "↑/↓ select   enter launch   b build-view   l legacy   q quit   ? help",
            id="hint",
        )
        yield Vertical(self._build_option_list(), id="menu-wrap")
        yield Footer()

    def on_mount(self) -> None:
        """Grab focus for the menu on first render.

        Without an explicit focus call the OptionList doesn't receive key
        events until the user clicks it, and its initial layout also settles
        late — which was half of the "rows merging until you click out and
        back in" bug.
        """
        self.query_one("#menu", OptionList).focus()

    # ── menu construction ────────────────────────────────────────────────────

    def _build_menu_items(self) -> list[Option | Separator]:
        """Produce the grouped list of Options / Separators for the menu.

        Split out from :meth:`_build_option_list` so :meth:`action_refresh`
        can repopulate an existing OptionList in place — :meth:`OptionList.remove`
        is asynchronous, so remount-with-same-id races with the pending remove.
        """
        items: list[Option | Separator] = []
        current_group: str | None = None
        for tool in TOOLS:
            if tool.group != current_group:
                if current_group is not None:
                    items.append(Separator())
                heading = _GROUP_LABELS.get(tool.group, tool.group)
                items.append(
                    Option(Text(heading, style="dim italic"), disabled=True)
                )
                current_group = tool.group

            path = find_tool(tool)
            available = path is not None
            # Build the prompt with no_wrap + ellipsis overflow so narrow
            # terminals truncate cleanly instead of wrapping a row to two
            # lines (which OptionList doesn't account for → visual row merge).
            prompt = Text(no_wrap=True, overflow="ellipsis")
            prompt.append(f"  {tool.icon}  ", style="bold magenta")
            prompt.append(
                f"{tool.title:<22}",
                style="bold" if available else "bold strike",
            )
            prompt.append("  ")
            prompt.append(
                tool.blurb,
                style="" if available else "dim strike",
            )
            if not available:
                prompt.append("  [missing]", style="red dim")
            items.append(Option(prompt, id=tool.key, disabled=not available))
        return items

    def _build_option_list(self) -> OptionList:
        """Construct the initial OptionList widget (used in compose)."""
        return OptionList(*self._build_menu_items(), id="menu")

    # ── event handlers ───────────────────────────────────────────────────────

    def on_option_list_option_selected(
        self, event: OptionList.OptionSelected
    ) -> None:
        """Enter pressed on a menu row — use the tool's default launch mode."""
        tool_key = event.option_id
        if not tool_key:
            return
        try:
            tool = get_tool(tool_key)
        except KeyError:
            return
        mode = "build" if tool.non_interactive else "suspend"
        self._launch_tool(tool_key, mode=mode)

    # ── actions ──────────────────────────────────────────────────────────────

    def action_refresh(self) -> None:
        """Re-probe tool availability (useful after `make install`)."""
        menu = self.query_one("#menu", OptionList)
        menu.clear_options()
        menu.add_options(self._build_menu_items())

    def action_help(self) -> None:
        self.notify(
            "enter: launch (auto) · b: build-view · l: legacy · "
            "r: refresh · q/Esc: quit",
            title="Keybindings",
            timeout=5,
        )

    def action_launch_highlighted(self, mode: str) -> None:
        """Handler for the 'b' and 'l' keybindings.

        ``mode`` is ``"build"`` (BuildScreen) or ``"suspend"`` (legacy
        TTY-handoff). Resolves the highlighted row to a tool key, skipping
        disabled rows (group headings, missing tools).
        """
        menu = self.query_one("#menu", OptionList)
        if menu.highlighted is None:
            return
        option = menu.get_option_at_index(menu.highlighted)
        if option.disabled or option.id is None:
            return
        self._launch_tool(option.id, mode=mode)

    # ── runner ───────────────────────────────────────────────────────────────

    def _launch_tool(self, key: str, *, mode: str = "suspend") -> None:
        """Launch ``key`` in either BuildScreen mode or suspend mode.

        ``mode`` is ``"build"`` (push the BuildScreen and stream output) or
        ``"suspend"`` (classic: suspend the TUI and hand the TTY to bash).
        """
        if mode == "build":
            self._launch_tool_in_build_screen(key)
        else:
            self._launch_tool_suspended(key)

    def _launch_tool_in_build_screen(self, key: str) -> None:
        """Open a BuildScreen for ``key`` — stays inside the TUI."""
        # Local import: BuildScreen pulls in asyncio.subprocess machinery we
        # don't want to touch at import time.
        from mythix_build_system.tui.build_screen import BuildScreen

        def _on_dismiss(_rc: int | None) -> None:
            # Refresh in case the tool just installed something new on PATH.
            self.action_refresh()

        self.push_screen(BuildScreen(key), _on_dismiss)

    def _launch_tool_suspended(self, key: str) -> None:
        """Suspend the TUI, hand the TTY to the shell tool, then return."""
        with self.suspend():
            # Clear the screen so the shell tool's banner starts clean,
            # matching the behaviour of ``mythix-build.sh``.
            print("\033[2J\033[H", end="", flush=True)
            result = run_tool(key)
            if result.not_found:
                print(
                    f"\n  ✖  Could not find: {key}\n"
                    "  Make sure mythix-build is installed (make install) "
                    "or run from the repo root.\n"
                )
                input("  Press Enter to return to the menu... ")
            elif not result.ok:
                print(
                    f"\n  ✖  {key} exited with code {result.returncode}.\n"
                )
                input("  Press Enter to return to the menu... ")
        # After resume, refresh availability in case the tool just installed something.
        self.action_refresh()
