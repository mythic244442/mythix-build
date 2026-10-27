# Mythix Wine build profiles

A **profile** is a pinned, reproducible recipe for one Mythix Wine flavour.
Every upstream input (Valve wine, GE, wine-staging, TkG, FFmpeg) is pinned to an
exact commit, and every build writes a **source lock** recording what went in.
That lets a build be rebuilt months later, after Valve has rewritten
bleeding-edge and GE has moved on.

```bash
./neutron-builder.sh --list-profiles
./neutron-builder.sh --profile mythix-11.19 --container
./neutron-builder.sh --profile mythix-10.17 --container      # rebuild the frozen 10.17
```

A profile sets these on its own:

- `--source mythix-wine`
- the package name
- the build mode
- the patch groups

Explicit flags still win over the profile: `--name`, `--patches` and `--build-mode`.

## Shipped profiles

| Profile | Pipeline | Mode | Package | What it is |
|---|---|---|---|---|
| `mythix-11.19` | `patch` | wow64 | `Mythix-Neutron-11.19-4` | Valve bleeding-edge + GE (incl. Wayland) + curated TkG 11.19 + DS4. Wayland-first. |
| `mythix-11.11` | `legacy` | classic | `Mythix-Neutron-11.11-2` | Safety net. A *reconstructed* recipe of the last X11-first bleeding-edge build. |
| `mythix-10.17` | `legacy` | classic | `Mythix-Neutron-10.17-2` | **Frozen.** The esync/fsync build on Valve proton_10.0. Never edit it. |

Rebuilds of an existing build get a new revision number (`-2`, `-3`, …). Installed
packages in `compatibilitytools.d` are never overwritten by a profile build.

## Layout

```
profiles/<name>/
├── profile.conf          # sourced by neutron-builder.sh (bash assignments only)
└── patches/              # ge pipeline only: curated layers, applied in name order
    ├── 0001-….patch
    └── 0002-….patch
```

## profile.conf

| Variable | Values | Meaning |
|---|---|---|
| `PROFILE_DESC` | text | One line shown by `--list-profiles` |
| `PROFILE_PIPELINE` | `patch` \| `legacy` | Which source pipeline prepares the tree (see below) |
| `PROFILE_BUILD_MODE` | `classic` \| `wow64` | `classic` = 64-bit tree + 32-bit tree (Wine 10.x bases, the 11.11 base). `wow64` = one unified `--enable-archs` tree + i386-unix drivers, Valve's Proton layout. Newer Valve loaders need `wow64`: the Neutron 11.0 base 66ee546 (2026-09-11) and the 11.19 pin do, the 11.11 pin (2026-07-16) doesn't. The builder refuses `classic` for such a tree |
| `PROFILE_PACKAGE_NAME` | e.g. `Mythix-Neutron-11.19-1` | Package dir + version tag. The launcher picks its build profile and prefix schema from it |
| `PROFILE_VERSION_LABEL` | e.g. `11.19` | Goes into `wine --version` (`wine-11.19-mythix.<base>`) |
| `PROFILE_WAYLAND` | `0` \| `1` | `1`: the `neutron` launcher defaults to the native Wayland driver on Wayland sessions |
| `PROFILE_PATCH_GROUPS` | `none` \| `all` \| `a,b` | Neutron patch groups (`patches/<group>/`) applied after the pipeline. **Strict**: a failure stops the build |
| `PROFILE_FFMPEG` | `none` \| `static` | `static`: build FFmpeg at `PIN_FFMPEG_COMMIT` and link it into `winedmo.so` |
| `PROFILE_STEAM_BRIDGE` | `none` \| `ge` | `ge`: build GE's `lsteamclient` + `steam.exe` in-tree with this Wine (see below) |
| `STEAM_BRIDGE_SKIP_PATCH_DIRS` | GE-relative dirs | GE helper patch dirs to leave out (11.19 skips `patches/discordrpc/helpers`) |

Pins for the **ge** pipeline:

| Variable | Default |
|---|---|
| `PIN_GE_REPO` / `PIN_GE_COMMIT` | required |
| `PIN_WINE_REPO` / `PIN_WINE_COMMIT` | GE's `wine` submodule pin |
| `PIN_STAGING_REPO` / `PIN_STAGING_COMMIT` | GE's `wine-staging` submodule pin |
| `PIN_FFMPEG_REPO` / `PIN_FFMPEG_COMMIT` | GE's `ffmpeg` submodule pin |
| `PIN_STEAM_BRIDGE_COMMIT` | `PIN_GE_COMMIT` (GE commit the Steam bridge is built from) |

Pins for the **legacy** pipeline:

| Variable | Meaning |
|---|---|
| `LEGACY_WINE_BASE` | `proton_10.0` \| `bleeding-edge` |
| `PIN_WINE_REPO` / `PIN_WINE_COMMIT` | Valve wine base commit (fetched by hash if it's no longer on a branch) |
| `PIN_TKG_COMMIT` | Kron4ek/wine-tkg commit to extract the TkG layer from |
| `PIN_STAGING_REF` | wine-staging tag or commit |
| `PIN_GE_COMMIT` | proton-ge-custom commit (kept in its own `proton-ge-custom-pinned` checkout) |
| `PIN_STEAM_BRIDGE_COMMIT` | GE commit the Steam bridge is built from (default `PIN_GE_COMMIT`; see below) |

## Pipelines

### `patch` — `mythix-patch-pipeline.sh`

Builds Mythix Wine on GE-Proton's tested patch stack:

1. Valve wine at the pin, plus wine-staging and GE at their pins.
2. GE's `protonprep-valve-staging.sh` "WINE PATCHING" section, run verbatim. This
   gives staging with GE's exclusions, game fixes, Wayland, the media rework and
   wineopenxr. Any failed hunk stops the build (exit 2).
3. With `PROFILE_STEAM_BRIDGE=ge`: the Steam client bridge (see below).
4. The profile's `patches/*.patch`, applied strictly with `git apply`.
5. Version branding: `wine-<label>-mythix.<base>  ( Mythix Wine )`.
6. Source lock: `<build-run>/mythix-source.lock`.

Each layer is a commit (`mythix: …`) in `<src>/mythix-patch/wine`, so
`git log` / `git diff` show exactly what every layer did. Re-running starts from a
clean checkout of the pins, so rebuilds are idempotent.

You can run it standalone to prepare and inspect a tree without building:

```bash
./mythix-patch-pipeline.sh --profile-dir profiles/mythix-11.19 --work-dir /tmp/mx --log-dir /tmp/mx/logs
```

### `legacy` — the original mythix-wine layer pipeline

This is the 5-layer pipeline in `neutron-builder.sh`:

- TkG diff extraction
- staging `--all`
- GE patches
- with `PROFILE_STEAM_BRIDGE=ge`: the Steam client bridge (see below), from
  the pinned GE checkout — built in-tree, so the packager never downloads
  Proton bits for the package
- the long list of post-patch fixups

Its behaviour is unchanged; a profile only injects pins. Pin failures are fatal,
and a pinned build starts from a pristine tree. It exists so 10.17 (and 11.11)
can always be rebuilt the way they were made.

### The Steam client bridge (`PROFILE_STEAM_BRIDGE=ge`)

Steam games talk to the Linux Steam client through `lsteamclient`. Valve's
ntdll redirects Steam's own `steamclient64.dll` into `lsteamclient.dll`, so
lsteamclient has to be built for *this exact Wine*. A copy taken from some other
Proton crashes Steam games (the old Cyberpunk "ABI mismatch").

Both pipelines share one implementation (`mythix-steam-bridge.sh`). With the
bridge on, the pipeline:

1. Runs GE's helper section of `protonprep-valve-staging.sh` (GE's lsteamclient
   patches) on GE's `lsteamclient/` and `steam_helper/`.
2. Adds them to the Wine tree as `dlls/lsteamclient` and `programs/steam_helper`.

Wine's own build then makes `lsteamclient.dll/.so` and `steam.exe` for every
arch. The packager never downloads Proton bits for such a build.

For the **legacy** pipeline the sources come from the pinned
`proton-ge-custom-pinned` checkout (Layer 4b, right after the GE patch layer);
the patch pipeline uses its own GE work-dir checkout.

GE's lsteamclient tracks Valve's newest Wine, so a GE commit's bridge only
builds on the Wine it was written for. A profile on an older base sets
`PIN_STEAM_BRIDGE_COMMIT` to the last GE commit whose lsteamclient matches it;
the bridge is then built from its own checkout (`proton-ge-custom-bridge`)
while the GE patch layer stays on `PIN_GE_COMMIT`. The source lock records it
as `bridge_ge_commit`. mythix-10.17 pins GE-Proton10-34 this way: newer GE
calls `ntdll_get_dos_file_name`/`ntdll_get_unix_file_name`, which only exist
from Wine 11.0 on.

The package's `build-info` gets `STEAM_BRIDGE=ge`. The `neutron` launcher then
follows Proton's Steam model for launches of a real Steam app (`SteamGameId` is
all digits) while the Steam client is running:

- It launches the game through the builtin `steam.exe`, which registers the
  Steam client for the game.
- It copies Steam's `legacycompat` `steamclient{,64}.dll` into the prefix.

Every other launch goes straight to the game, like a build without the bridge.
That covers the Mythix Launcher's hex ids for non-Steam games and any launch
while Steam is closed. `NEUTRON_USE_STEAM_SHIM=1` forces `steam.exe` and `=0`
turns it off; `neutron diag` shows the decision.

## DualShock 4 / DualSense (mythix-11.19)

Three layers handle a Sony pad:

- **winebus**, patch group `mythix-ds4`: hidraw haptics become native DS4
  rumble, and native DS4 output reports (lightbar) pass through.
- **xinput**, GE's Sony stack: with `PROTON_SONY_AUTO_XINPUT=1` a hidraw DS4 /
  DualSense is also an XInput controller. That slot steps aside when a game
  reads the pad natively or Steam Input owns it. GE-Proton sets this by default,
  and so does the `neutron` launcher on builds whose xinput has the stack.
- **xinput**, `patches/0003-mythix-xinput-ds4-native.patch`: Luna's
  `MYTHIX_DS4_GLYPHS=1` switch. The pad never shows up in `XInputGetState`, so
  games with native PlayStation support read it over HID and show PlayStation
  glyphs. xinput still opens the pad, so `XInputSetState` rumbles it
  (Cyberpunk 2077 drives vibration that way). The Mythix Launcher sets the
  switch for Cyberpunk 2077, RDR2, Elden Ring and The Witcher 3.

The Neutron 11.0 line (Valve's stock xinput) keeps Luna's original xinput
change, with its Sony direct path, in the patch group `mythix-ds4-xinput`.

## DualShock 4 / DualSense (mythix-10.17, mythix-11.11)

The patch group `mythix-ds4-10` carries both layers for the proton_10.0 tree:

- **winebus**: the `mythix-ds4` patch rebased onto this tree, plus hidraw on
  by default (`DisableHidraw=0`, Valve's default). The TkG 10.17 layer carries
  mainline Wine's `1`, so hidraw was off: SDL handed games an Xbox-style copy
  of the pad, and nothing reached the raw DS4.
- **xinput**: Luna's Sony direct path and `MYTHIX_DS4_GLYPHS=1`, ported to
  proton_10.0's xinput. That xinput reads pads on an update thread, so the
  port keeps the behaviour, not the hunks. With no XInput pad in slot 0, the
  hidraw pad opens there. Its reports are read in the pad's own layout, and
  rumble goes through winebus' haptics reports, over USB or Bluetooth. A Steam
  Input virtual pad that claims the slot replaces it.

`mythix-ds4-11.11` does the same for the mythix-11.11 tree (Valve
bleeding-edge): the winebus patch rebased (one hunk re-anchored) with the same
`DisableHidraw=0` fix, since TkG 11.11 carries mainline's `1` as well. Valve's
11.0-line xinput is already the one `mythix-ds4-xinput` targets, so that patch
goes in as is.

## Source locks and build-info

Every profile build copies these into the package:

- `mythix-source.lock` records the commits, script and patch hashes, and FFmpeg
  build, plus each patch group's result (`patch_group_<group>=<patch> sha256=… result=…`).
- `build-info` holds `PROFILE`, `BUILD_MODE`, `WAYLAND`, `SOURCE`, … The `neutron`
  launcher reads it (`neutron diag` shows it).

To check what an installed build is made of:

```bash
cat /path/to/compatibilitytools.d/Mythix-Neutron-11.19-4/mythix-source.lock
```

## Bumping a ge profile to a newer GE

The pins and the curated patches move together. Make a **new** profile (or a new
package revision) instead of editing a shipped one:

1. Copy the profile: `cp -a profiles/mythix-11.19 profiles/mythix-11.2x`.
2. Set `PIN_GE_COMMIT` to the new GE commit. Leave `PIN_WINE_COMMIT` /
   `PIN_STAGING_COMMIT` on GE's own submodule pins (`git ls-tree <ge> wine wine-staging`)
   unless you have a reason. The pipeline warns when they differ.
3. Bump `PROFILE_PACKAGE_NAME` and `PROFILE_VERSION_LABEL`.
4. Run the pipeline standalone (above). Then:
   - **exit 0:** done, build it.
   - **exit 2 in step 2:** GE's own stack fails on those pins. Use GE's matching pins.
   - **exit 2 in step 3:** re-curate that profile patch. Apply it with
     `git apply --3way` on the new GE layer, resolve conflicts, keep only hunks
     that aren't already upstream, then `git diff > patches/000N-….patch`.
     Keep the provenance header at the top of the patch.
5. Build with `--allow-patch-failures` while you iterate. It lets a profile patch
   or patch group fail without stopping the build. **Never ship a build made with
   it.**

## What the curated layers contain (mythix-11.19)

- `0001-mythix-tkg-11.19.patch`: the TkG 11.19 delta minus everything already in
  Valve/GE:
  - Wayland-first driver order
  - `CustomOverrides`
  - `WINEDEBUG=-all` default
  - the user32 image base
  - MUI lookup
  - win32k forwards
  - the winecfg Staging tab
  - the Mythix banner

  TkG's hidraw/input-off default is deliberately **left out**: Mythix's DS4
  support uses hidraw.
- `0002-mythix-build-compat.patch`: guarded shims for the Ubuntu 24.04 container's
  older libraries (e.g. `XKB_VMOD_NAME_SCROLL` from libxkbcommon 1.7). Each shim is
  a no-op on newer systems.
- `0003-mythix-xinput-ds4-native.patch`: `MYTHIX_DS4_GLYPHS=1` native
  PlayStation mode on top of GE's Sony XInput stack: hidden from
  `XInputGetState`, still rumbled by `XInputSetState` (see the DualShock section).
