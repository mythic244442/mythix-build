"""Tkinter GUI frontend for mythix-build.

Spawns shell tools in external terminal windows. Zero changes to the
bash engines — this is purely a launcher cockpit.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tkinter as tk
from pathlib import Path
from tkinter import ttk

from mythix_build_system import __version__
from mythix_build_system.core import TOOLS, find_tool

# ── Terminal detection ───────────────────────────────────────────────────────

_TERMINALS: list[tuple[str, list[str]]] = [
    ("xfce4-terminal", ["-e", "{cmd}"]),
    ("gnome-terminal", ["--", "bash", "-c", "{cmd}; exec bash"]),
    ("konsole", ["-e", "bash", "-c", "{cmd}; exec bash"]),
    ("alacritty", ["-e", "bash", "-c", "{cmd}; exec bash"]),
    ("kitty", ["-e", "bash", "-c", "{cmd}; exec bash"]),
    ("xterm", ["-e", "bash", "-c", "{cmd}; exec bash"]),
]


def _find_terminal() -> tuple[str, list[str]] | None:
    for name, argv in _TERMINALS:
        if shutil.which(name):
            return name, argv
    return None


# ── GUI ──────────────────────────────────────────────────────────────────────

GROUP_COLORS = {
    "build": "#ff6b6b",
    "hybrid": "#4ecdc4",
    "install": "#45b7d1",
    "gui": "#96ceb4",
}

GROUP_ICONS = {
    "build": "🔨",
    "hybrid": "🔀",
    "install": "📦",
    "gui": "🧰",
}


class MythixGui:
    def __init__(self) -> None:
        self.term = _find_terminal()
        self.root = tk.Tk()
        self.root.title("mythix-build")
        self.root.geometry("520x640")
        self.root.minsize(420, 400)
        self.root.configure(bg="#1e1e2e")

        self._style()
        self._build_ui()

    def _style(self) -> None:
        style = ttk.Style()
        style.theme_use("clam")
        style.configure("TFrame", background="#1e1e2e")
        style.configure("TLabel", background="#1e1e2e", foreground="#cdd6f4")
        style.configure("Header.TLabel", font=("Segoe UI", 20, "bold"), foreground="#cba6f7")
        style.configure("Group.TLabel", font=("Segoe UI", 12, "bold"), foreground="#89b4fa")
        style.configure("Tool.TButton", font=("Segoe UI", 11), padding=8)
        style.configure("Status.TLabel", font=("Segoe UI", 9), foreground="#6c7086")

    def _build_ui(self) -> None:
        # Header
        header = ttk.Label(self.root, text="🐺  mythix-build", style="Header.TLabel")
        header.pack(pady=(16, 4))

        sub = ttk.Label(self.root, text=f"v{__version__}  —  Wine / Neutron / Proton toolkit", style="Status.TLabel")
        sub.pack(pady=(0, 8))

        if self.term is None:
            warn = ttk.Label(
                self.root,
                text="⚠️  No terminal emulator found! Install xfce4-terminal, gnome-terminal, konsole, alacritty, kitty, or xterm.",
                foreground="#f38ba8",
                wraplength=480,
                justify="center",
            )
            warn.pack(pady=8)

        # Scrollable tool list
        canvas = tk.Canvas(self.root, bg="#1e1e2e", highlightthickness=0)
        scrollbar = ttk.Scrollbar(self.root, orient="vertical", command=canvas.yview)
        self.content = ttk.Frame(canvas)

        self.content.bind(
            "<Configure>",
            lambda e: canvas.configure(scrollregion=canvas.bbox("all")),
        )
        canvas.create_window((0, 0), window=self.content, anchor="nw", width=500)
        canvas.configure(yscrollcommand=scrollbar.set)

        canvas.pack(side="left", fill="both", expand=True, padx=(12, 0), pady=8)
        scrollbar.pack(side="right", fill="y", padx=(0, 8), pady=8)

        # Mousewheel scrolling
        def _on_scroll(event: tk.Event) -> None:  # type: ignore[type-arg]
            canvas.yview_scroll(int(-1 * (event.delta / 120)), "units")

        canvas.bind_all("<MouseWheel>", _on_scroll)

        self._populate_tools()

        # Status bar
        status = ttk.Label(
            self.root,
            text=f"Terminal: {self.term[0] if self.term else 'none found'}",
            style="Status.TLabel",
        )
        status.pack(side="bottom", pady=(4, 8))

    def _populate_tools(self) -> None:
        groups: dict[str, list] = {}
        for tool in TOOLS:
            groups.setdefault(tool.group, []).append(tool)

        for group, tools in groups.items():
            gframe = ttk.Frame(self.content)
            gframe.pack(fill="x", pady=(12, 4), padx=4)

            color = GROUP_COLORS.get(group, "#cdd6f4")
            icon = GROUP_ICONS.get(group, "⚙️")
            glabel = ttk.Label(
                gframe,
                text=f"{icon}  {group.upper()}",
                style="Group.TLabel",
                foreground=color,
            )
            glabel.pack(anchor="w", padx=4)

            # Separator
            sep = tk.Frame(gframe, height=2, bg=color)
            sep.pack(fill="x", pady=(2, 6), padx=4)

            for tool in tools:
                self._tool_button(gframe, tool)

    def _tool_button(self, parent: ttk.Frame, tool) -> None:  # type: ignore[no-untyped-def]
        path = find_tool(tool)
        found = path is not None

        btn_frame = tk.Frame(parent, bg="#313244", padx=8, pady=8)
        btn_frame.pack(fill="x", pady=3, padx=4)
        btn_frame.bind("<Button-1>", lambda e, t=tool: self._launch(t))

        # Hover effects
        def on_enter(e: tk.Event, f=btn_frame) -> None:  # type: ignore[type-arg]
            f.configure(bg="#45475a")

        def on_leave(e: tk.Event, f=btn_frame) -> None:  # type: ignore[type-arg]
            f.configure(bg="#313244")

        btn_frame.bind("<Enter>", on_enter)
        btn_frame.bind("<Leave>", on_leave)

        # Icon + title row
        title = tk.Label(
            btn_frame,
            text=f"{tool.icon}  {tool.title}",
            bg="#313244",
            fg="#cdd6f4" if found else "#6c7086",
            font=("Segoe UI", 11, "bold"),
            cursor="hand2" if found else "",
        )
        title.pack(anchor="w")
        title.bind("<Button-1>", lambda e, t=tool: self._launch(t))

        # Blurb
        blurb = tk.Label(
            btn_frame,
            text=tool.blurb,
            bg="#313244",
            fg="#a6adc8" if found else "#6c7086",
            font=("Segoe UI", 9),
            wraplength=440,
            justify="left",
        )
        blurb.pack(anchor="w", pady=(2, 0))
        blurb.bind("<Button-1>", lambda e, t=tool: self._launch(t))

        # Path hint
        hint = tk.Label(
            btn_frame,
            text=str(path) if path else "not found",
            bg="#313244",
            fg="#6c7086",
            font=("Segoe UI", 8),
        )
        hint.pack(anchor="w", pady=(2, 0))

        if not found:
            for w in (btn_frame, title, blurb, hint):
                w.bind("<Button-1>", lambda e: None)

    def _launch(self, tool) -> None:  # type: ignore[no-untyped-def]
        if self.term is None:
            return
        path = find_tool(tool)
        if path is None:
            return

        term_name, term_argv = self.term
        cmd = f"bash '{path}'"

        argv = [term_name]
        for arg in term_argv:
            argv.append(arg.format(cmd=cmd))

        subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def run(self) -> None:
        self.root.mainloop()


def main() -> None:
    MythixGui().run()


if __name__ == "__main__":
    main()
