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
| `mythix-11.19` | `ge` | classic | `Mythix-Neutron-11.19-1` | Valve bleeding-edge + GE (incl. Wayland) + curated TkG 11.19 + DS4. Wayland-first. |
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
| `PROFILE_PIPELINE` | `ge` \| `legacy` | Which source pipeline prepares the tree (see below) |
| `PROFILE_BUILD_MODE` | `classic` \| `wow64` | `classic` = 64-bit tree + 32-bit tree (`bin/wine64`). `wow64` = one unified tree |
| `PROFILE_PACKAGE_NAME` | e.g. `Mythix-Neutron-11.19-1` | Package dir + version tag. The launcher picks its build profile and prefix schema from it |
| `PROFILE_VERSION_LABEL` | e.g. `11.19` | Goes into `wine --version` (`wine-11.19-mythix.<base>`) |
| `PROFILE_WAYLAND` | `0` \| `1` | `1`: the `neutron` launcher defaults to the native Wayland driver on Wayland sessions |
| `PROFILE_PATCH_GROUPS` | `none` \| `all` \| `a,b` | Neutron patch groups (`patches/<group>/`) applied after the pipeline. **Strict**: a failure stops the build |
| `PROFILE_FFMPEG` | `none` \| `static` | `static`: build FFmpeg at `PIN_FFMPEG_COMMIT` and link it into `winedmo.so` |

Pins for the **ge** pipeline:

| Variable | Default |
|---|---|
| `PIN_GE_REPO` / `PIN_GE_COMMIT` | required |
| `PIN_WINE_REPO` / `PIN_WINE_COMMIT` | GE's `wine` submodule pin |
| `PIN_STAGING_REPO` / `PIN_STAGING_COMMIT` | GE's `wine-staging` submodule pin |
| `PIN_FFMPEG_REPO` / `PIN_FFMPEG_COMMIT` | GE's `ffmpeg` submodule pin |

Pins for the **legacy** pipeline:

| Variable | Meaning |
|---|---|
| `LEGACY_WINE_BASE` | `proton_10.0` \| `bleeding-edge` |
| `PIN_WINE_REPO` / `PIN_WINE_COMMIT` | Valve wine base commit (fetched by hash if it's no longer on a branch) |
| `PIN_TKG_COMMIT` | Kron4ek/wine-tkg commit to extract the TkG layer from |
| `PIN_STAGING_REF` | wine-staging tag or commit |
| `PIN_GE_COMMIT` | proton-ge-custom commit (kept in its own `proton-ge-custom-pinned` checkout) |

## Pipelines

### `ge` — `mythix-ge-pipeline.sh`

Builds Mythix Wine on GE-Proton's tested patch stack:

1. Valve wine at the pin, plus wine-staging and GE at their pins.
2. GE's `protonprep-valve-staging.sh` "WINE PATCHING" section, run verbatim. This
   gives staging with GE's exclusions, game fixes, Wayland, the media rework and
   wineopenxr. Any failed hunk stops the build (exit 2).
3. The profile's `patches/*.patch`, applied strictly with `git apply`.
4. Version branding: `wine-<label>-mythix.<base>  ( Mythix Wine )`.
5. Source lock: `<build-run>/mythix-source.lock`.

Each layer is a commit (`mythix: …`) in `<src>/mythix-ge/wine`, so
`git log` / `git diff` show exactly what every layer did. Re-running starts from a
clean checkout of the pins, so rebuilds are idempotent.

You can run it standalone to prepare and inspect a tree without building:

```bash
./mythix-ge-pipeline.sh --profile-dir profiles/mythix-11.19 --work-dir /tmp/mx --log-dir /tmp/mx/logs
```

### `legacy` — the original mythix-wine layer pipeline

This is the 5-layer pipeline in `neutron-builder.sh`:

- TkG diff extraction
- staging `--all`
- GE patches
- the long list of post-patch fixups

Its behaviour is unchanged; a profile only injects pins. Pin failures are fatal,
and a pinned build starts from a pristine tree. It exists so 10.17 (and 11.11)
can always be rebuilt the way they were made.

## Source locks and build-info

Every profile build copies these into the package:

- `mythix-source.lock` records the commits, script and patch hashes, and FFmpeg
  build, plus each patch group's result (`patch_group_<group>=<patch> sha256=… result=…`).
- `build-info` holds `PROFILE`, `BUILD_MODE`, `WAYLAND`, `SOURCE`, … The `neutron`
  launcher reads it (`neutron diag` shows it).

To check what an installed build is made of:

```bash
cat /path/to/compatibilitytools.d/Mythix-Neutron-11.19-1/mythix-source.lock
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
