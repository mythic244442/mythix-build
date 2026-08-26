"""Click-based command-line entry point for mythix-build.

Exposes subcommands on top of the default TUI:

  * ``mythix``                  → open the TUI launcher (default)
  * ``mythix launch <tool>``    → run a single tool with full TTY handoff
  * ``mythix build  <tool>``    → run a non-interactive tool with live progress
  * ``mythix list``             → print the tool catalogue (for scripting)
  * ``mythix doctor``           → diagnose discovery / check what's found
  * ``mythix version``          → print the package version
"""

from __future__ import annotations

import sys
from pathlib import Path

import click

from mythix_build_system import __version__
from mythix_build_system.core import TOOLS, find_tool, resolve_root, run_tool
from mythix_build_system.core.tools import TOOLS_BY_KEY


@click.group(
    invoke_without_command=True,
    context_settings={"help_option_names": ["-h", "--help"]},
)
@click.version_option(__version__, "--version", "-V", prog_name="mythix-build")
@click.option("--gui", is_flag=True, help="Open the graphical launcher instead of TUI.")
@click.pass_context
def main(ctx: click.Context, gui: bool) -> None:
    """mythix-build — Wine, Neutron & Proton toolkit (TUI + CLI + GUI).

    Run without arguments to open the Textual launcher.
    Use --gui for the graphical launcher.
    """
    if ctx.invoked_subcommand is None:
        if gui:
            from mythix_build_system.gui import main as _gui_main

            _gui_main()
        else:
            from mythix_build_system.tui import LauncherApp

            LauncherApp().run()


@main.command("list")
@click.option(
    "--format",
    "fmt",
    type=click.Choice(["pretty", "plain", "keys"]),
    default="pretty",
    help="Output format — 'keys' prints one key per line for scripting.",
)
def list_tools(fmt: str) -> None:
    """Print the tool catalogue."""
    if fmt == "keys":
        for tool in TOOLS:
            click.echo(tool.key)
        return

    for tool in TOOLS:
        path = find_tool(tool)
        status = click.style("✓", fg="green") if path else click.style("✗", fg="red")
        location = str(path) if path else "not found"
        if fmt == "pretty":
            click.echo(
                f"  {status}  {tool.icon}  "
                f"{click.style(tool.title, bold=True):<24}  "
                f"{click.style(tool.blurb, dim=True)}"
            )
            click.echo(f"        {click.style(location, dim=True)}")
        else:
            click.echo(f"{tool.key}\t{path or '-'}\t{tool.blurb}")


@main.command("launch")
@click.argument("tool_key", metavar="TOOL")
@click.argument("args", nargs=-1)
def launch(tool_key: str, args: tuple[str, ...]) -> None:
    """Launch a single tool with full TTY handoff (for interactive tools)."""
    if tool_key not in TOOLS_BY_KEY:
        click.echo(
            f"Unknown tool: {tool_key!r}. Use `mythix list --format=keys`.",
            err=True,
        )
        sys.exit(2)
    result = run_tool(tool_key, list(args))
    if result.not_found:
        click.echo(f"Could not find tool: {tool_key}", err=True)
        sys.exit(127)
    sys.exit(result.returncode)


@main.command("build")
@click.argument("tool_key", metavar="TOOL")
@click.argument("args", nargs=-1)
def build(tool_key: str, args: tuple[str, ...]) -> None:
    """Run a non-interactive build with live progress + log tail.

    Unlike ``launch``, this keeps the TUI up and streams the tool's output
    into an in-app log pane — useful for long builds where you want to watch
    progress without losing the UI. Not suitable for tools that need to
    prompt (``fzf``/``zenity``); use ``launch`` for those.
    """
    if tool_key not in TOOLS_BY_KEY:
        click.echo(
            f"Unknown tool: {tool_key!r}. Use `mythix list --format=keys`.",
            err=True,
        )
        sys.exit(2)

    # Tiny hosting App so BuildScreen has something to run inside.
    from textual.app import App

    from mythix_build_system.tui.build_screen import BuildScreen

    class _Host(App[int]):
        TITLE = "mythix-build · build"

        def on_mount(self) -> None:
            self.push_screen(BuildScreen(tool_key, list(args)), self._on_done)

        def _on_done(self, rc: int | None) -> None:
            self.exit(rc if rc is not None else 0)

    rc = _Host().run() or 0
    sys.exit(rc)


@main.command("doctor")
def doctor() -> None:
    """Diagnose discovery — show repo root and resolved tool paths."""
    root = resolve_root()
    click.echo(click.style("mythix-build doctor", bold=True))
    click.echo(f"  version:   {__version__}")
    click.echo(f"  repo root: {root or click.style('(not found)', fg='yellow')}")
    click.echo("")
    click.echo(click.style("Tool resolution:", bold=True))
    missing = 0
    for tool in TOOLS:
        path = find_tool(tool)
        if path is None:
            missing += 1
            click.echo(
                f"  {click.style('✗', fg='red')}  {tool.key:<22}  "
                f"{click.style('not found', fg='red')}"
            )
        else:
            click.echo(
                f"  {click.style('✓', fg='green')}  {tool.key:<22}  "
                f"{click.style(str(path), dim=True)}"
            )
    click.echo("")
    if missing:
        click.echo(
            click.style(
                f"{missing} tool(s) not found. Run `make install` or set "
                "$MYTHIX_ROOT to your source checkout.",
                fg="yellow",
            )
        )
    else:
        click.echo(click.style("All tools resolved. You're good :3", fg="green"))


@main.command("version")
def version() -> None:
    """Print the mythix-build version."""
    click.echo(__version__)


if __name__ == "__main__":
    main()
