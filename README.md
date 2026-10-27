# mythix-build

**Wine & Neutron builders, delegated Proton builder, hybrid installer, GUI toolkit, and installers — all in one repo.**

Build Wine from 10 upstream sources, compile full Neutron packages for Steam, build
GE-Proton and proton-tkg using their own upstream build systems, merge custom Wine
over existing Proton installs, manage installations with one-click switching, deploy
builds and download pre-built releases, and handle prefixes, DXVK, runtimes, and DLL
overrides through a zenity-based GUI. Or do it all from the CLI.

Now with a **Python frontend** — a Textual TUI, Tkinter GUI, and Click CLI that wrap
the battle-tested shell engines with modern keyboard navigation, live build progress,
and a tool catalogue.

```
                     ____________________
                _____   ..            .  _____
             ///.         .     .+            \\\
           //              |\     /\            .\\\
         //  .     .       |#\\  /##\               \\
       //.      +   .     |####_/#/##|  .             \
      (       .   .+     /###::##//###|     .     +.  .))
    (( +. .   +       /////:::########|   .   .  ..      )
   (   .          .///################|    .   .     +    )
   (      . ..    |/############\######\\               . )
  ( .     .   ___//:\\<o<#####\::\#####\\_\   .++          )
  (      ____/###############:##\\\\###\\#\|   ..          )
  ( ..   |################::#:\\#\:\#####\#\\   .           )
  (       \\#############:\\:\\\\\\:###:\\#\|      ..       )
  ( .       \'''''''#######///\\\\\#\:\\\##:#|         ..   )
  (                 |#######:#######\\########|      .     )
  (                 |:/#/::/:#:##\::##########\|       +   )
   (        .      |////////://##/########:\#:#|     +*   )
   (  .            |:/#///////:/:##########\\:##\ .       )
    ((        .    |/#/://///:##################\| +.    )
      (+      .    \/////#/:/::#####\#########\::\\    ))
       \           |/:#####/////////########::\\###|  /
        \\   +     |:########//:/#########\\:##:\#\<//
          \\\     |/#:/:##################/###/##///
             \\\   |##//\####################////
                ----|###/:################----
                    ----------------------
          __  ____     _______ _    _ _______   __
         |  \/  \ \   / /__   __| |  | |_   _\ \ / /
         | \  / |\ \_/ /   | |  | |__| | | |  \ V /
         | |\/| | \   /    | |  |  __  | | |   > <
         | |  | |  | |     | |  | |  | |_| |_ / . \
         |_|  |_|  |_|     |_|  |_|  |_|_____/_/ \_\
```

> **Note on the command examples below:** every command is in its own code block so
> you can copy and paste them one at a time. Commands that take multiple flags are
> still a single command — paste the whole block for those.

---

## Table of Contents

- [Quick Start](#quick-start)
- [Install](#install)
- [Python Frontend](#python-frontend)
  - [TUI (Textual)](#tui-textual)
  - [GUI (Tkinter)](#gui-tkinter)
  - [CLI (Click)](#cli-click)
- [Tools](#tools)
  - [wine-builder](#-wine-builder--mythix-wine_builder)
  - [neutron-builder](#-neutron-builder--mythix-neutron_builder)
  - [proton-builder](#-proton-builder--mythix-proton_builder)
  - [neutron-install](#-neutron-install--mythix-neutron-install)
  - [proton-install](#-proton-install--mythix-proton-install)
  - [wine-proton_hybrid](#-wine-proton_hybrid--mythix-wine-proton_hybrid_builder)
  - [wine-neutron_hybrid](#-wine-neutron_hybrid--mythix-wine-neutron_hybrid_builder)
- [Project Layout](#project-layout)
- [Data Directories](#data-directories)
- [Building with Containers (Recommended)](#building-with-containers-recommended)
- [Requirements](#requirements)
- [Uninstall](#uninstall)

---

## Quick Start

Clone the repo:

```bash
git clone https://github.com/mythic244242/mythix-build
```

Enter it:

```bash
cd mythix-build
```

Install to `~/.local` (also adds a `PATH` block to `~/.bashrc`):

```bash
make install
```

Reload your shell (first install only):

```bash
source ~/.bashrc
```

Then any of these — one per terminal:

```bash
mythix-build
```
```bash
wine-builder
```
```bash
neutron-builder
```
```bash
proton-builder
```
```bash
proton-install
```
```bash
neutron-install
```
```bash
wine_toolz
```
```bash
wine-proton_hybrid
```
```bash
wine-neutron_hybrid
```

(`mythix-build` is the main menu that can launch all of the above.)

### Python Quick Start

Editable install with dev dependencies:

```bash
make py-dev
```

Open the Textual TUI:

```bash
mythix
```

Open the Tkinter GUI:

```bash
mythix --gui
```

Run a tool with full TTY handoff:

```bash
mythix launch wine_toolz
```

Print the tool catalogue:

```bash
mythix list
```

Diagnose discovery and check what's found:

```bash
mythix doctor
```

---

## Install

User install to `~/.local` (default):

```bash
make install
```

System-wide (needs sudo):

```bash
make install PREFIX=/usr/local
```

Staged for packaging:

```bash
make install DESTDIR=/tmp/pkg
```

### Selective install

Neutron builder only:

```bash
make install-neutron
```

Proton builder only:

```bash
make install-proton
```

Wine builder only:

```bash
make install-wine
```

Wine–Proton hybrid builder only:

```bash
make install-hybrid
```

Wine–Neutron hybrid builder only:

```bash
make install-neutron-hybrid
```

neutron-install only:

```bash
make install-neutron-install
```

proton-install only:

```bash
make install-proton-install
```



Mythix main-menu launcher only:

```bash
make install-launcher
```

The installer adds a `PATH` block to `~/.bashrc` automatically. If `~/.local/bin`
is already in your `PATH`, it's skipped. Run `source ~/.bashrc` after first install.

### Python Frontend Install

Editable install (`pip install -e .[dev]`):

```bash
make py-dev
```

Run the test suite:

```bash
make py-test
```

Open the Textual TUI launcher:

```bash
make py-tui
```

Or install directly with pip — minimal (textual + click):

```bash
pip install -e .
```

With dev dependencies (pytest, pytest-asyncio, textual-dev):

```bash
pip install -e ".[dev]"
```

After install, the `mythix` console script is available. Open the TUI (default):

```bash
mythix
```

Open the Tkinter GUI:

```bash
mythix --gui
```

Run a tool with full TTY handoff:

```bash
mythix launch <tool>
```

Run a tool with the live progress screen:

```bash
mythix build <tool>
```

Print the tool catalogue:

```bash
mythix list
```

Diagnose tool discovery:

```bash
mythix doctor
```

Print the version:

```bash
mythix version
```

---

## Python Frontend

The `mythix_build_system/` Python package provides three frontends over the shell build
engines — a modern TUI, a graphical GUI, and a scriptable CLI. The shell scripts
still do all the real work; Python handles the launcher UX, tool discovery,
subprocess orchestration, and live build progress.

### TUI (Textual)

A full-featured terminal UI built with [Textual](https://github.com/Textualize/textual).
Same wolf banner and tool list as the bash launcher, rendered with keyboard navigation,
grouped categories, and a keybind footer.

Open the TUI:

```bash
mythix
```

Same thing via Makefile:

```bash
make py-tui
```

Same thing via Python module:

```bash
python -m mythix_build_system
```

**Keybindings:**

| Key | Action |
|-----|--------|
| `↑` / `↓` | Navigate the tool list |
| `Enter` | Launch the highlighted tool (auto-picks best mode) |
| `b` | Open in Build View — captured output with live progress bar |
| `l` | Legacy launch — suspend TUI, hand TTY to the shell tool |
| `r` | Refresh tool availability (useful after `make install`) |
| `?` | Show keybinding help |
| `q` / `Esc` | Quit |

**Two launch modes:**

- **Legacy (suspend)** — the TUI suspends and gives the shell tool a full TTY.
  `fzf` pickers, `zenity` dialogs, and `read` prompts all work exactly like
  running the script directly. This is the default for interactive tools.

- **Build View** — the TUI stays up and streams the tool's stdout/stderr into a
  live log pane with a progress bar, elapsed clock, and section headings parsed
  from the shell output. Use this for long non-interactive builds where watching
  progress without losing the UI is more valuable than interactive prompts.

### GUI (Tkinter)

A graphical launcher window using Python's built-in Tkinter. Tools are grouped by
category with colored headers and hover effects. Clicking a tool opens it in your
terminal emulator.

From the CLI:

```bash
mythix --gui
```

Direct module launch:

```bash
python -m mythix_build_system.gui
```

**Supported terminal emulators** (auto-detected in order):
xfce4-terminal, gnome-terminal, konsole, alacritty, kitty, xterm.

The GUI shows each tool's resolved path and greys out tools that can't be found.
A status bar at the bottom shows which terminal emulator was detected.

### CLI (Click)

A [Click](https://click.palletsprojects.com/)-based command-line interface for
scripting and direct tool invocation without opening a TUI.

Pretty-print the tool catalogue:

```bash
mythix list
```

One key per line (for scripting):

```bash
mythix list --format=keys
```

Tab-separated key/path/blurb:

```bash
mythix list --format=plain
```

Full TTY handoff:

```bash
mythix launch wine-builder
```

Pass flags through to the tool (after `--`):

```bash
mythix launch neutron-builder -- --source proton-wine --branch proton_9.0
```

Live progress screen, non-interactive:

```bash
mythix build neutron-builder -- --dry-run
```

Show repo root + tool resolution:

```bash
mythix doctor
```

Print the version string:

```bash
mythix version
```

| Command | Description |
|---------|-------------|
| `mythix` | Open the TUI launcher (default) |
| `mythix --gui` | Open the Tkinter GUI launcher |
| `mythix launch TOOL [ARGS...]` | Run a tool with full TTY handoff (fzf/zenity work) |
| `mythix build TOOL [ARGS...]` | Run a tool with live progress screen (non-interactive) |
| `mythix list` | Print the tool catalogue |
| `mythix doctor` | Diagnose discovery — repo root and resolved tool paths |
| `mythix version` | Print the version |

**Tool discovery** works in three modes:

1. **Installed with PATH** — `make install` put binaries in `~/.local/bin/` (or
   your `PREFIX/bin/`). `shutil.which` finds them.
2. **Source tree** — running from the repo checkout. Tools resolve via their
   relative path from the repo root.
3. **Installed without PATH** — probes `~/.local`, `/usr/local`, `/usr` for
   `bin/` and `lib/` layouts.

Set `$MYTHIX_ROOT` to explicitly point at a source checkout.

---

## Tools

### 🍷 wine-builder — mythix-wine_builder

Builds Wine from 10 upstream sources with full 32+64-bit cross-compile, ccache
support, TKG patch integration, and automated staging application.

Interactive source + version picker:

```bash
wine-builder
```

Upstream Wine (stable tags):

```bash
wine-builder --source mainline
```

Wine-Staging (pre-patched):

```bash
wine-builder --source staging
```

Mainline + staging patches (automated):

```bash
wine-builder --source tkg-patched
```

Valve proton-wine (branch picker):

```bash
wine-builder --source proton
```

Kron4ek wine-tkg build:

```bash
wine-builder --source kron4ek
```

Any git repo:

```bash
wine-builder --source custom --url <git-url> --branch main
```

An existing local source tree:

```bash
wine-builder --source local --local-dir ~/my-wine-src
```

Continue an interrupted build:

```bash
wine-builder --resume
```

Show completed builds:

```bash
wine-builder --list
```

Remove a build (interactive picker):

```bash
wine-builder --uninstall
```

#### Wine Sources

| Key | Source | Notes |
|-----|--------|-------|
| `mainline` | Wine mainline | Official WineHQ stable releases |
| `experimental` | Wine experimental | WineHQ bleeding-edge (master) |
| `staging` | Wine-Staging | Mainline + community patches, pre-applied |
| `tkg-patched` | Wine + Staging (automated) | Mainline with staging applied automatically |
| `proton` | Valve proton-wine | Valve's Wine fork (interactive branch picker) |
| `proton-experimental` | Valve Bleeding Edge | Valve's latest experiments |
| `wine-tkg` | wine-tkg (Frogging-Family) | Community patchset framework |
| `kron4ek` | Kron4ek wine-tkg | Kron4ek's Wine + Staging + TKG + ntsync |
| `local` | Local source | Use an existing directory (requires `--local-dir`) |
| `custom` | Custom URL | Any git repo (requires `--url`) |

#### Full CLI Reference

| Flag | Description |
|------|-------------|
| `--source NAME` | Wine source key (see table above) |
| `--branch BRANCH` | Pin to a specific branch or tag |
| `--url URL` | Git URL (required with `--source custom`) |
| `--local-dir PATH` | Existing source tree (required with `--source local`) |
| `--no-pull` | Skip `git pull` on existing source |
| `--dest DIR` | Root for `build-run/` and `install/` output |
| `--src-dir DIR` | Root for git-cloned sources |
| `--name NAME` | Custom build name (default: auto-generated) |
| `--jobs N` | Parallel make jobs (default: `nproc`) |
| `--cfg PATH` | Alternate `customization.cfg` |
| `--skip-32` | Skip 32-bit build |
| `--no-ccache` | Disable ccache |
| `--keep-symbols` | Keep debug symbols (skip strip) |
| `--build-type TYPE` | `release` (default) \| `debug` \| `debugoptimized` |
| `--native` | Compile with `-march=native` (faster, non-portable) |
| `--lto` | Enable link-time optimisation |
| `--resume` | Continue an interrupted build (skip configure) |
| `--verbose` | Stream raw make output |
| `--list` | Show installed builds |
| `--uninstall [NAME]` | Remove a build (interactive if no name given) |
| `--update` | Re-fetch and rebuild last-used source |
| `--dry-run` | Print planned actions without executing |

Build output lands in `buildz/install/<name>/` — a complete Wine prefix-ready
tree with `bin/wine`, `lib/`, etc.

---

### 🎮 neutron-builder — mythix-neutron_builder

Builds a complete **Neutron package** (a Steam-compatible Proton tool) from source: a Wine build
(proton-wine, GE-Proton, Mythix Wine, or kron4ek-tkg) compiled with MinGW PE support, plus DXVK and
VKD3D-Proton, all assembled into a Steam-loadable package. The result drops into
`compatibilitytools.d/` and appears in Steam's per-game Compatibility dropdown —
just like GE-Proton, but built locally from the sources you choose with the
compiler flags you want.

Build a pinned Mythix Wine profile (recommended — see below):

```bash
neutron-builder --profile mythix-11.19 --container
```

List the pinned Mythix Wine recipes:

```bash
neutron-builder --list-profiles
```

Interactive wizard:

```bash
neutron-builder
```

Valve proton-wine (branch picker):

```bash
neutron-builder --source proton-wine
```

Valve proton-wine, pinned branch:

```bash
neutron-builder --source proton-wine --branch proton_9.0
```

GE-Proton — proton-wine + GE gaming patches:

```bash
neutron-builder --source ge-proton
```

Kron4ek wine-tkg + ntsync:

```bash
neutron-builder --source kron4ek-tkg
```

Mythix Wine — Valve proton-wine + TkG + Staging + GE (the works):

```bash
neutron-builder --source mythix-wine
```

Apply all discovered patch groups:

```bash
neutron-builder --patches all
```

Apply specific groups:

```bash
neutron-builder --patches custom
```

Enable Steam Runtime Sniper container:

```bash
neutron-builder --sniper
```

Compile DXVK from source (instead of downloading):

```bash
neutron-builder --dxvk dxvk
```

Compile VKD3D-Proton from source:

```bash
neutron-builder --vkd3d vkd3d-proton
```

Rebuild DXVK only, skip Wine:

```bash
neutron-builder --dxvk-only
```

Rebuild VKD3D-Proton only:

```bash
neutron-builder --vkd3d-only
```

Re-package without rebuilding:

```bash
neutron-builder --reinstall-components
```

Show installed Neutron builds:

```bash
neutron-builder --list
```

#### Mythix Wine profiles

Mythix Wine flavours are built from **profiles**: pinned recipes in
`mythix-neutron_builder/profiles/`. Every upstream input is pinned, and every
build writes a `mythix-source.lock` into the package. Today there are three:

- `mythix-11.19`: GE-based, Wayland-first.
- `mythix-11.11`: safety net.
- `mythix-10.17`: frozen esync/fsync build.

See [`profiles/README.md`](mythix-neutron_builder/profiles/README.md).

#### Proton Wine Sources

| Key | Source | Notes |
|-----|--------|-------|
| `mainline` | WineHQ mainline | Official stable releases (version picker) |
| `experimental` | WineHQ experimental | Bleeding-edge master branch |
| `staging` | Wine-Staging | Mainline + community patches (version picker) |
| `proton-wine` | Valve proton-wine | Stable branches with interactive version picker |
| `proton-wine-experimental` | Valve proton-wine experimental | Bleeding-edge, no picker |
| `ge-proton` | GE-Proton | proton-wine/Staging + GE's full gaming patch set (version picker) |
| `kron4ek-tkg` | Kron4ek wine-tkg | Mainline + Staging + TKG patches + ntsync |
| `mythix-wine` | Mythix Wine | Valve proton-wine + TkG + Staging + GE (the works); base branch set with `--wine-base` |

#### DXVK & VKD3D-Proton Options

| DXVK Key | Description |
|----------|-------------|
| `dxvk-release` | Pre-built DXVK DLLs from GitHub releases (default, fastest) |
| `dxvk` | Standard DXVK — D3D9/10/11 → Vulkan, compiled from source (requires MinGW) |
| `dxvk-async` | DXVK + async pipeline compilation, compiled from source |
| `none` | Skip DXVK (falls back to WineD3D) |

| VKD3D Key | Description |
|-----------|-------------|
| `vkd3d-proton-release` | Pre-built VKD3D-Proton DLLs from GitHub releases (default, fastest) |
| `vkd3d-proton` | VKD3D-Proton — D3D12 → Vulkan, compiled from source (requires MinGW) |
| `none` | Skip VKD3D-Proton (D3D12 games won't work) |

#### Full CLI Reference

| Flag | Description |
|------|-------------|
| `--profile NAME` | Build a pinned Mythix Wine profile (`profiles/NAME`) |
| `--list-profiles` | Show available profiles |
| `--build-mode MODE` | `classic` (wine64 + 32-bit tree) \| `wow64` (unified) |
| `--allow-patch-failures` | Let profile patch layers fail (re-curation only) |
| `--source NAME` | Wine source key |
| `--branch BRANCH` | Pin proton-wine to a specific branch |
| `--wine-base BASE` | Mythix Wine base branch: `proton_10.0` (default) \| `bleeding-edge` |
| `--no-pull` | Skip `git pull` |
| `--dxvk NAME` | DXVK variant (`dxvk-release` \| `dxvk` \| `dxvk-async` \| `none`) |
| `--vkd3d NAME` | VKD3D variant (`vkd3d-proton-release` \| `vkd3d-proton` \| `none`) |
| `--dxvk-branch BRANCH` | Pin DXVK to specific tag |
| `--vkd3d-branch BRANCH` | Pin VKD3D-Proton to specific tag |
| `--name NAME` | Build name (default: `mythix-neutron-<ver>`) |
| `--dest DIR` | Root for build artefacts |
| `--src-dir DIR` | Root for git clones |
| `--jobs N` | Parallel make threads (default: `nproc`) |
| `--skip-32` | Skip 32-bit Wine build |
| `--no-ccache` | Disable ccache |
| `--keep-symbols` | Keep debug symbols |
| `--build-type TYPE` | `release` \| `debug` \| `debugoptimized` |
| `--native` | `-march=native` optimisation |
| `--lto` | Link-time optimisation |
| `--resume` | Continue interrupted build |
| `--dxvk-only` | Rebuild DXVK only (skip Wine) |
| `--vkd3d-only` | Rebuild VKD3D-Proton only (skip Wine) |
| `--reinstall-components` | Re-package without rebuilding |
| `--container` | Build inside the neutron container image (Podman) |
| `--no-container` | Build natively on the host, skip the container prompt |
| `--kron4ek-redist BUILD_DIR [PKG_DIR]` | Maintenance: re-run the compat redist step against an existing build dir |
| `--patches GROUPS` | Patch groups to apply (`all`, `none`, or comma-separated names) |
| `--patches-dir PATH` | Alternate patches directory |
| `--sniper` | Enable Steam Runtime Sniper mode (container isolation) |
| `--cfg PATH` | Alternate `neutron-customization.cfg` |
| `--list` | Show installed Neutron builds |
| `--dry-run` | Print planned actions |

Without `--container` / `--no-container`, the builder asks interactively whether
to build in the container or natively.

#### How neutron Works

neutron-builder assembles a **self-contained Neutron package** — the same
kind of package that Valve ships as Proton. The key
difference from a regular Wine build is that every component is compiled to run
inside Steam's Proton infrastructure:

**Wine with MinGW PE modules.** The `--with-mingw` configure flag tells Wine to build
its Windows DLLs (`.dll`) as genuine PE (Portable Executable) binaries using the
MinGW cross-compiler, rather than ELF Winelib objects. This is what makes Steam's
FPS counter overlay, Steam Input, and DRM/anti-cheat systems work correctly — they
require real PE DLLs to inject into.

**DXVK and VKD3D-Proton are statically self-contained.** The custom DXVK and
VKD3D-Proton builds produced by neutron-builder are compiled against bundled headers
(Vulkan, SPIR-V, DirectX) and linked without MinGW runtime DLL dependencies. The
resulting `.dll` files are fully standalone — no `libstdc++-6.dll` or other MinGW
runtime DLLs needed at runtime.

**toolmanifest.vdf — host-native or Sniper container.** By default, the generated
`toolmanifest.vdf` omits `require_tool_appid "1391110"`, so neutron packages run
**host-native** — direct access to Vulkan drivers, kernel features, and ntsync/fsync.
Pass `--sniper` to enable **Steam Runtime Sniper mode** instead, which adds
`require_tool_appid "1391110"` and runs the package inside Steam's SteamOS 3.x
container for SteamDeck-like isolation. The interactive builder offers this as an
fzf picker during the build wizard.

#### The neutron Python Launcher

Each built package contains a `neutron` Python script that Steam invokes in place of
Proton's `proton` launcher. It handles the full Steam Proton protocol:

**Steam verbs** — Steam passes a verb as the first argument to tell the launcher what
to do. `neutron` handles all standard Proton verbs:

| Verb | Behavior |
|------|----------|
| `waitforexitandrun` | Run the game via Wine and wait for it to exit (most common) |
| `run` | Run without waiting (Steam polls for exit) |
| `runinprefix` | Run a helper command inside the Wine prefix |
| `getcompatpath` | Convert a Unix path to a Windows path (printed to stdout) |
| `getnativepath` | Convert a Windows path to a Unix path (printed to stdout) |
| `stop` | Kill the wineserver for this prefix |
| `createprefix` | Create a prefix using a base Proton, then overlay Neutron DLLs (`--proton PATH`) |
| `destroyprefix` | Remove exactly the files Neutron installed (tracked-files manifest) |
| `makedefaultpfx` | (Re)create the prefix template (`--force` to regenerate) |
| `slimprefix` | Swap an older prefix's private Wine Mono (~313 MB) for the shared one (`neutron slimprefix [compatdata]`, game closed) |
| `diag` | Print resolved configuration without launching anything (`--full-env` for all vars) |

**Sync primitive auto-detection.** The launcher inspects the `wineserver` binary for
compiled-in sync support and enables the best available mode automatically — no
manual env var required:

- **NTSync** — if `wineserver` has ntsync support compiled in (kron4ek-tkg builds
  do; Valve's proton-wine does not), ntsync activates automatically when
  `/dev/ntsync` is present. `WINEFSYNC=1` is also set as a fallback.
- **fsync** — enabled via `WINEFSYNC=1` when ntsync is absent but fsync is compiled
  in (Valve proton-wine).
- **esync** — enabled via `WINEESYNC=1` when only esync is available.
- The user's externally-set values are always respected (`setdefault` is used).

**Runtime gaming optimizations.** The launcher automatically applies performance
tuning that you'd otherwise have to set manually:

- **DXVK async** — `DXVK_ASYNC=1` enabled by default for stutter-free shader compilation.
- **Shipped `dxvk.conf`** — auto-loaded from the package's `files/` directory with
  async shaders, state cache, and sane defaults. Override with `DXVK_CONFIG_FILE`.
- **AMD GPU hints** — `RADV_PERFTEST=gpl,nggc,sam` for graphics pipeline library,
  NGG culling, and Smart Access Memory on RADV.
- **GameMode integration** — auto-detects [Feral GameMode](https://github.com/FeralInteractive/gamemode)
  and wraps the game process with `gamemoderun` for CPU governor and nice priority
  optimization. Controlled via `NEUTRON_GAMEMODE=auto|1|0`.
- **MangoHud passthrough** — set `MANGOHUD=1` in Steam launch options and it just
  works. The launcher sets `MANGOHUD_DLSYM=1` for proper hooking.

**Prefix initialization on first launch.** When a game runs for the first time in a
fresh prefix (no `system.reg` present), `neutron` automatically:

1. Creates a default prefix template by running `wineboot --init` once (cached for
   future launches — subsequent prefixes clone from it via symlinks + reflink copies).
2. Clones the template into the game's prefix with a unique MachineGuid.
3. Overlays DXVK DLLs (`d3d9.dll`, `d3d10*.dll`, `d3d11.dll`, `dxgi.dll`) and
   VKD3D-Proton DLLs (`d3d12.dll`, `d3d12core.dll`) into the prefix, tracked by a
   manifest so `destroyprefix` can cleanly remove them.
4. Installs Steam client DLLs, NVIDIA nvngx/DLSS DLLs, and VR client DLLs as needed.
5. Sets up DOS drives, OpenVR paths, and the `.update-timestamp` suppressor.

This means DXVK and VKD3D-Proton are active from the very first game launch with no
manual setup step.

**Shared Wine Mono and Gecko.** The packager unpacks the Mono and Gecko versions the
build's Wine asks for (read from its `appwiz.cpl`) into `files/share/wine/{mono,gecko}`,
the layout Proton uses, caching the tarballs under `~/.cache/mythix-build/wine-addons`.
Every prefix loads them from there, so the template and each new prefix no longer
carry their own 313 MB of Mono, and HTML views (mshtml) work. Prefixes made before
this keep their private copy until `slimprefix` (diag points them out);
`NEUTRON_SHARED_ADDONS=0` at package time skips the step.

**WINEDLLOVERRIDES — forcing native over builtin.** The launcher sets:

- Graphics DLL overrides (`d3d9=n,b`, `d3d10core=n,b`, `d3d11=n,b`, `dxgi=n,b`,
  `d3d8=n,b`, `d3d12=n,b`, `d3d12core=n,b`) — ensures DXVK and VKD3D-Proton DLLs
  take priority over Wine builtins.
- Steam bridge override (`lsteamclient=n,b`).

**Steam client bridge (builds with `STEAM_BRIDGE=ge` in `build-info`).** These
builds ship an `lsteamclient` built with the same Wine. A launch goes through
Proton's `steam.exe` helper, which registers the Steam client for the game, only
when both of these hold:

- `SteamGameId` (or `SteamAppId`) is a real Steam app id (all digits).
- The Steam client is running.

Other launches go straight to the game, for example the Mythix Launcher's hex
ids for non-Steam games, or any launch while Steam is closed.
`NEUTRON_USE_STEAM_SHIM=1` forces `steam.exe` and `=0` turns it off. Steam's
`steamclient{,64}.dll` are copied into the prefix only for `steam.exe` launches.

**DualShock 4 / DualSense.** On 11.19+ builds, xinput carries GE's Sony stack.
By default a Sony pad on hidraw is also an XInput controller
(`PROTON_SONY_AUTO_XINPUT=1`, GE-Proton's own default). That slot steps aside
when a game reads the pad natively or when Steam Input owns it.

For games with native PlayStation support, set `MYTHIX_DS4_GLYPHS=1`. The pad
then never shows up in `XInputGetState`, so the game reads it over HID and
shows PlayStation glyphs. `XInputSetState` still rumbles it. The Mythix
Launcher sets it for Cyberpunk 2077, RDR2, Elden Ring and The Witcher 3.
`neutron diag` shows the active mode.

On 10.17 (from 10.17-3) and 11.11 (from 11.11-3), xinput has no GE Sony stack. hidraw is on by
default, as in Proton. A hidraw pad stays plain HID, and xinput opens it in
slot 0 when no other XInput pad is there.
`MYTHIX_DS4_GLYPHS=1` works the same way as on 11.19.

#### Patch System

neutron-builder includes a full patch system (`neutron-patcher.sh`) that applies
patch groups to the Wine source between fetch and configure. For GE-Proton's
gaming patches, use `--source ge-proton` instead — it runs GE's own patch script
automatically. The patch system below is for your own custom patches.

`patches/` ships with these groups:

- `mythix-ds4`: Mythix DualShock 4 support in winebus (hidraw haptics and LED).
- `mythix-ds4-xinput`: Luna's xinput DS4 work for the Neutron 11.0 line, on
  Valve's stock xinput. The 11.19 profile carries its own xinput patch instead.
- `mythix-ds4-10`: both DS4 layers for the proton_10.0 tree (mythix-10.17):
  the winebus patch rebased, and Luna's xinput work ported to 10.0's xinput.
- `mythix-ds4-11.11`: both DS4 layers for the mythix-11.11 tree: the winebus
  patch rebased, and the 11.0-line xinput patch as is.
- `custom/`: an empty template.

Drop your own `.patch` files into `custom/` (or any new subdirectory) and the
patcher auto-discovers them.

**Usage** — apply everything discovered:

```bash
neutron-builder --patches all
```

Apply only the custom group:

```bash
neutron-builder --patches custom
```

Skip patching:

```bash
neutron-builder --patches none
```

Interactive fzf multi-picker:

```bash
neutron-builder
```

**Adding patches:** Place `.patch` files in `patches/custom/` or create
additional subdirectories under `patches/`. Each directory with `.patch` files
is treated as a patch group. Add an optional `group.conf` for metadata:

```ini
description="My custom patches for game X"
priority=50
sources=
conflicts=
requires=
```

A `series` file (one filename per line) controls application order. Without it,
patches are applied in sorted filename order (`0001-*.patch` convention).

See `patches/custom/README.md` for full documentation on group.conf fields,
naming conventions, and examples.

The patcher creates a git checkpoint before applying, so you can revert with
`git checkout neutron-pre-patch-<timestamp>` in the Wine source directory.

#### Steam Component Bootstrap

For profile builds with `PROFILE_STEAM_BRIDGE=ge` (all current profiles) the
bridge is **built in-tree** from GE's own `lsteamclient`/`steam_helper` sources
during source prep, ABI-matched to the Wine being built — nothing is
downloaded. See `mythix-neutron_builder/profiles/README.md`.

For non-profile builds (plain `--source kron4ek-tkg` etc.), neutron-builder
auto-bootstraps proprietary Steam components during packaging as a fallback.
It searches local Proton installs (Hotfix, Experimental, 9.0, 8.0, and any
`Proton*` directory) across all Steam library roots. If no local Proton is found,
it **downloads from [Kron4ek/proton-archive](https://github.com/Kron4ek/proton-archive)**
(defaults to proton-10.0-4) — a last resort, since those binaries are
ABI-matched to Proton's own Wine, not the one being packaged.

**Components bootstrapped:**

| Component | Files | Purpose |
|-----------|-------|---------|
| `lsteamclient` | `.dll` (PE) + `.so` (Unix bridge), 32+64-bit | Steam API bridge — without it, Steamworks games hang at startup |
| `steam_helper.exe` | 32+64-bit | Steam overlay helper / steamwebhelper bridge |
| `steam.exe` | 32+64-bit | Steam client stub expected by some games |
| `gameoverlayrenderer.so` | 32+64-bit | In-game Steam overlay (Shift+Tab) |
| `steamclient.dll` | 32+64-bit | Steam client library |

Additional Steam library paths can be provided via the `STEAM_LIBRARY_PATHS`
environment variable (newline-separated).

#### NTSync Support

NTSync is a Linux kernel synchronization mechanism (introduced in kernel 6.14) that
dramatically reduces CPU overhead for Wine's thread synchronization. For builds using
kron4ek-tkg Wine, ntsync support is compiled in automatically — **no configure flag
is needed**. The `Containerfile.neutron` fetches the `ntsync.h` kernel header and
places it where Wine's configure scripts can find it. If `ntsync.h` is present at
build time, Wine's configure detects it and includes ntsync support. The `neutron`
launcher then activates it at runtime when `/dev/ntsync` exists.

For Valve's proton-wine fork, ntsync is not compiled in (Valve manages that
separately in their official builds); fsync is used instead.

#### neutron-customization.cfg

Copy `neutron-customization.cfg` and pass it with `--cfg` to tune the build for your
machine. Key knobs:

| Setting | Default | Description |
|---------|---------|-------------|
| `CC_64` / `CXX_64` | `x86_64-linux-gnu-gcc/g++` | Native (ELF side) compilers for 64-bit |
| `CC_32` / `CXX_32` | `i686-linux-gnu-gcc/g++` | Native compilers for 32-bit |
| `MINGW_CC_64` / `MINGW_CXX_64` | `x86_64-w64-mingw32-gcc/g++` | MinGW cross-compiler for 64-bit PE DLLs |
| `MINGW_CC_32` / `MINGW_CXX_32` | `i686-w64-mingw32-gcc/g++` | MinGW cross-compiler for 32-bit PE DLLs |
| `JOBS` | `$(nproc)` | Parallel build jobs |
| `_configure_args` | (array) | Configure flags applied to both 32-bit and 64-bit runs |
| `_configure_args32` | (array) | Configure flags for the 32-bit build only |
| `_configure_args64` | (array) | Configure flags for the 64-bit build only |
| `CFLAGS` / `CXXFLAGS` | `-O3 -march=native -mtune=native` | Compiler optimization flags (native side) |
| `CROSSCFLAGS` / `CROSSCXXFLAGS` | `-O3 -march=native -mtune=native` | Compiler flags for MinGW PE modules |

The default `CFLAGS`/`CROSSCFLAGS` use `-O3 -march=native -mtune=native`. This
gives a meaningful performance boost for Wine's hot paths over the default `-O2`,
but the resulting binaries are tuned for your CPU and **should not be copied to a machine
with a different CPU family**. Remove `-march=native -mtune=native` if you need a
portable build.

`_configure_args`, `_configure_args32`, and `_configure_args64` must be Bash arrays.
`neutron-build-core.sh` re-sources the cfg file to expand them at configure time.

#### GTA IV — Real-World Test Case

GTA IV on Steam works correctly with a neutron-built kron4ek-tkg 11.5 Wine package.
It is a useful reference case because it exercises several things simultaneously:

- **lsteamclient** — GTA IV's launcher calls SteamAPI. Without lsteamclient, the
  game hangs at a black screen. The auto-bootstrap step picks it up from Proton
  Experimental.
- **OpenVR disabled** — GTA IV bundles `openvr_api.dll`. Without the
  `openvr_api_dxvk=disabled;vrclient_x64=disabled;vrclient=disabled` overrides, Wine
  tries to load the VR client and hits an assertion crash at startup.
- **DXVK in prefix** — GTA IV uses D3D9. The first-launch prefix initialization
  installs DXVK automatically, so there is no manual `setup_dxvk.sh` step.
- **Host-native launch** — the `toolmanifest.vdf` omits `require_tool_appid`, so
  Steam runs the package directly without the SLR Sniper container. This is what
  makes ntsync and direct Vulkan driver access work correctly.

#### Installing to Steam

After a successful build, copy the package (single command — paste the whole block):

```bash
cp -r ~/.local/share/mythix-neutron_builder/buildz/install/<name> ~/.steam/steam/compatibilitytools.d/
```

Or use `neutron-install --deploy <path>` (see below) to copy and set permissions in
one step.

Restart Steam, then go to a game's Properties → Compatibility → select your build.

---

### 🔧 proton-builder — mythix-proton_builder

Builds **GE-Proton** or **proton-tkg** using their own upstream build systems —
"delegated builds." Unlike neutron-builder (which compiles Wine, DXVK, and VKD3D from
source), proton-builder clones the upstream project and runs *their* build scripts
inside containers. The result is identical to what the upstream maintainer ships, but
compiled locally on your machine.

Both GE-Proton and proton-tkg bring their own container environments (Podman or
Docker), so the only hard dependencies are `git`, `curl`, and a container engine.

Interactive menu (ge, tkg, list, clean):

```bash
proton-builder
```

Build latest GE-Proton:

```bash
proton-builder --source ge
```

Build proton-tkg:

```bash
proton-builder --source tkg
```

Show completed builds:

```bash
proton-builder --list
```

Remove source checkouts & intermediates:

```bash
proton-builder --clean
```

Preview GE-Proton build steps:

```bash
proton-builder --dry-run --source ge
```

#### Build Sources

| Key | Source | Notes |
|-----|--------|-------|
| `ge` | [GE-Proton](https://github.com/GloriousEggroll/proton-ge-custom) | GloriousEggroll's Proton fork — `configure.sh` + `make dist` inside the `umu-sdk` container |
| `tkg` | [proton-tkg](https://github.com/Frogging-Family/wine-tkg-git) | Frogging-Family's proton-tkg — `proton-tkg.sh` with its own Valve SDK container |

#### How It Works

**GE-Proton:** Clones `proton-ge-custom`, checks out the latest release tag,
runs `./configure.sh --container-engine=<engine> --build-name=<name>` followed by
`make dist`. The build happens inside the `ghcr.io/open-wine-components/umu-sdk:latest`
container. Output is copied to the install directory.

**proton-tkg:** Clones `wine-tkg-git`, enters the `proton-tkg/` subdirectory, and
runs `./proton-tkg.sh`. TKG handles its own container setup via the Valve SDK. The
`proton-tkg.cfg` configuration file can be edited before the build starts.

#### CLI Reference

| Flag | Description |
|------|-------------|
| `--source ge` | Build GE-Proton from source |
| `--source tkg` | Build proton-tkg from source |
| `--build-name NAME` | Override the build name (default: auto from upstream tag) |
| `--jobs N` | Parallel build jobs (default: `nproc`) |
| `--container-engine ENG` | Force `podman` or `docker` (default: auto-detect) |
| `--list` | List completed Proton builds |
| `--clean` | Remove source checkouts and build intermediates |
| `--dry-run` | Show what would happen without building |

Build output lands in `~/.local/share/mythix-proton_builder/buildz/install/`. Deploy
with `proton-install --deploy <path>` or the interactive `proton-install` menu.

---

### 🚀 neutron-install — mythix-neutron-install

A full CLI package manager for Neutron builds. Installs, deploys to Steam, sets up
as system Wine, switches active versions, and manages installed Neutron packages —
all with fzf pickers and numbered fallbacks.

Interactive menu (7 actions):

```bash
neutron-install
```

Install from builder output / dir / tarball:

```bash
neutron-install --install
```

Install a specific package path:

```bash
neutron-install --install <path>
```

Deploy to Steam compatibilitytools.d:

```bash
neutron-install --deploy
```

Deploy a specific package:

```bash
neutron-install --deploy <path>
```

Install as system Wine (symlinks to `~/.local/bin`):

```bash
neutron-install --system-wine
```

List managed installs with metadata:

```bash
neutron-install --list
```

Remove one or more installs:

```bash
neutron-install --remove <name>
```

Disk usage, version, architecture details:

```bash
neutron-install --info <name>
```

#### Features

| Action | Description |
|--------|-------------|
| **Install** (`--install [PATH]`) | Install from neutron-builder output, a directory, or a tarball |
| **Deploy** (`--deploy [PATH]`) | Copy to `~/.steam/*/compatibilitytools.d/` for Steam |
| **System Wine** (`--system-wine [NAME]`) | Symlink Wine binaries + `neutron` launcher to `~/.local/bin/` |
| **List** (`--list`) | Show all managed installs with version, date, active status |
| **Remove** (`--remove NAME`) | Remove installs and clean up symlinks |
| **Info** (`--info NAME`) | Disk usage, Wine version, source, contents breakdown |

Extra flags: `--compat-dir DIR` overrides the compatibilitytools.d path,
`--bin-dir DIR` overrides the symlink directory, `--dry-run` prints planned actions.

**Managed installs** go to `~/.local/share/mythix-neutron-installs/<name>/` with
`.mythix-meta` metadata. Symlinks include all Wine binaries (`wine`, `wine64`,
`wineserver`, `wineboot`, `winecfg`, etc.) plus the `neutron` Python launcher.

---

### 🚀 proton-install — mythix-proton-install

Download pre-built Proton releases and deploy locally-built Proton packages into
Steam's `compatibilitytools.d/`. Handles GE-Proton downloads, any GitHub release
tarball URL, and deploying proton-builder output — all in one step.

Interactive menu:

```bash
proton-install
```

List installed compatibility tools:

```bash
proton-install --list
```

Download + install latest GE-Proton:

```bash
proton-install --install-ge
```

(`--ge` is a short alias for `--install-ge`.)

Download + install from any URL:

```bash
proton-install --install-url URL
```

Deploy a locally-built package:

```bash
proton-install --deploy PATH
```

Remove an installed tool:

```bash
proton-install --remove NAME
```

Use a non-default compatibilitytools.d:

```bash
proton-install --compat-dir DIR
```

Show planned actions without executing:

```bash
proton-install --dry-run
```

#### What It Does

`proton-install` manages the `~/.steam/*/compatibilitytools.d/` directory so you do
not have to manually `cp -r` and `chmod` packages yourself. It:

- Auto-discovers Steam's `compatibilitytools.d` across common Steam installation
  paths (standard `~/.steam/steam`, Debian/Ubuntu `~/.steam/debian-installation`,
  Flatpak, etc.).
- Downloads GE-Proton releases from the official GitHub releases page.
- Accepts any direct download URL for other community Proton builds.
- Deploys locally-built Proton packages (from proton-builder) via `--deploy PATH`:
  copies the package directory into `compatibilitytools.d/` and sets correct
  permissions.
- Lists currently installed compatibility tools with name and path.
- Removes a named tool and its directory.

#### CLI Reference

| Flag | Description |
|------|-------------|
| `--install-ge` / `--ge` | Download and install the latest GE-Proton release |
| `--install-url URL` | Download and install a Proton release from a direct URL (tar.gz / tar.xz / tar.zst) |
| `--deploy PATH` | Deploy a locally-built Proton package (proton-builder output, any compatible directory) into compatibilitytools.d |
| `--list` | List installed compatibility tools |
| `--remove NAME` | Remove a named compatibility tool |
| `--compat-dir DIR` | Override the auto-discovered compatibilitytools.d path |
| `--dry-run` | Print planned actions without executing anything |

#### After Changes

Always restart Steam after installing, deploying, or removing a compatibility tool
(single command — paste the whole block):

```bash
steam -shutdown && steam
```

The new tool will appear (or disappear) under a game's Properties → Compatibility.

---

### 🔀 wine-proton_hybrid — mythix-wine-proton_hybrid_builder

Merges any Wine build directly over an existing Proton install, preserving Proton's
DXVK, VKD3D-Proton, Steam overlay DLLs, and Python launcher. Run your custom Wine
inside Proton's infrastructure — get the best of both worlds.

Interactive wizard:

```bash
wine-proton_hybrid
```

Full non-interactive run (single command — paste the whole block):

```bash
wine-proton_hybrid --wine-src ~/builds/wine-staging-10.5 --proton-src ~/.steam/steam/compatibilitytools.d/GE-Proton10-32 --name my-hybrid --install-mode steam
```

Remove a previously installed hybrid:

```bash
wine-proton_hybrid --uninstall --name my-hybrid
```

#### CLI Reference

| Flag | Description |
|------|-------------|
| `--wine-src DIR` | Path to the custom Wine build directory |
| `--proton-src DIR` | Path to the Proton/GE-Proton source |
| `--name NAME` | Tool name (default: `wine-proton_mythix`) |
| `--protonfixes-dir DIR` | Path to protonfixes source (umu-protonfixes, etc.) |
| `--install-mode MODE` | `steam` \| `steam-pick` \| `custom` |
| `--install-dir DIR` | Parent directory for custom installs |
| `--dry-run` | Show commands without executing |
| `--verbose` | Print every command before running |
| `--debug` | Dump Proton lib/wine layout after install |
| `--uninstall` | Remove a previously installed hybrid |

#### Standalone Launcher Environment Variables

The hybrid installs a standalone launcher script. Control it with:

| Variable | Description |
|----------|-------------|
| `MYTHIX_PREFIX` | Exact prefix path (default: `~/.wine-proton-pfx`) |
| `WINE_USE_START` | Set to `1` for launcher-wrapped games (e.g., GTA IV) |
| `PROTON_LOG` | Set to `1` for verbose Wine debug log in `/tmp/` |
| `DXVK_HUD` | Set to `1` for DXVK overlay |
| `WINEARCH` | `win64` (default) or `win32` |

---

### 🔀 wine-neutron_hybrid — mythix-wine-neutron_hybrid_builder

Merges any Wine build directly over an existing **Neutron** package base, producing a
single hybrid tool that can be registered with Steam as a compatibility tool or used
standalone via `./neutron run <game.exe>`. Same concept as wine-proton_hybrid but
targeting Neutron packages instead of Proton installs.

Interactive wizard:

```bash
wine-neutron_hybrid
```

Full non-interactive run (single command — paste the whole block):

```bash
wine-neutron_hybrid --wine-src ~/builds/wine-staging-10.5 --neutron-src ~/.steam/steam/compatibilitytools.d/mythix-neutron-9.0 --name my-hybrid --install-mode steam
```

Remove a previously installed hybrid:

```bash
wine-neutron_hybrid --uninstall --name my-hybrid
```

#### CLI Reference

| Flag | Description |
|------|-------------|
| `--wine-src DIR` | Path to the custom Wine build directory |
| `--neutron-src DIR` | Path to the Neutron package directory |
| `--name NAME` | Tool name (default: `wine-neutron_mythix`) |
| `--protonfixes-dir DIR` | Path to protonfixes source (umu-protonfixes, etc.) |
| `--install-mode MODE` | `steam` \| `steam-pick` \| `custom` |
| `--install-dir DIR` | Parent directory for custom installs |
| `--dry-run` | Show commands without executing |
| `--verbose` | Print every command before running |
| `--debug` | Dump Neutron lib/wine layout after install |
| `--uninstall` | Remove a previously installed hybrid |

#### Standalone Launcher Environment Variables

The hybrid installs a standalone launcher script. Control it with:

| Variable | Description |
|----------|-------------|
| `MYTHIX_PREFIX` | Exact prefix path (default: `~/.wine-neutron-pfx`) |
| `WINE_USE_START` | Set to `1` for launcher-wrapped games (e.g., GTA IV) |
| `PROTON_LOG` | Set to `1` for verbose Wine debug log in `/tmp/` |
