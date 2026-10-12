# mythix-build — lay of the land (2026-10-06)

Survey of `~/mythix-build` on bean2442 at commit `3f45d01` + uncommitted WIP, before the overhaul.

## Repo state

- `origin` = github.com/mythic244442/mythix-build; `upstream` = blu2442/looni-build. `.git/config` has a duplicate `[branch "main"]` block with a stale `merge = refs/heads/rebrand/mythix-build`.
- Local `main` is **2 commits behind origin** (README wording tweak, plus a one-line removal in `neutron-package.sh` that's already in the local working tree).
- **Uncommitted WIP** (about 550 lines changed):
  - `neutron-build-core.sh` / `neutron-builder.sh`: moving from the classic wine64 + wine32 two-tree build to a **unified WoW64 tree** (`--enable-archs=i386,x86_64`) plus a separate `wine-i386-unix` tree for the 32-bit unix .so files; SDL turned back on for bleeding-edge.
  - `neutron.py`: +393/−78 lines (81 KB → 96 KB).
  - `black-screen-investigation.md` (untracked): 11.14 black-screen regression notes.
- Tag `v1.0.0` only (the looni tags v1.2–v1.5 sit in packed-refs from the old remote).

## Size and shape (~33k lines)

| Component | Files | Lines | Notes |
|---|---|---|---|
| neutron_builder | 13 | ~9.4k | `neutron-builder.sh` alone is 4,887 lines / 244 KB |
| neutron.py (launcher) | 1 | 2,245 | Proton-style single-file verb launcher |
| wine_builder | 10 | ~4.6k | |
| hybrid builders (×2) | 2 | ~3.5k | **89% identical** to each other |
| installers (neutron/proton) | 2 | ~1.9k | |
| proton_builder (delegated GE/TKG) | 1 | 563 | |
| winetoolz | 21 | ~5.4k | zenity GUI, v2.1 |
| Python frontend | 12 | ~1.5k | Textual TUI + Tk GUI + Click CLI |
| tests | 7 | ~0.9k | Python frontend only |

## How it fits together

- `mythix-build.sh` (fzf menu) and the `mythix` Python CLI/TUI/GUI both just launch 9 standalone shell tools.
- Each tool is self-contained: it finds its siblings through `SCRIPT_DIR` and gets installed into its own `PREFIX/lib/mythix-<tool>/` dir by a hand-written Makefile. Build data goes to `~/.local/share/mythix-*`.
- **neutron-builder** flow: pick source (8 Wine sources) → fetch → patch → build-core (configure/compile) → DXVK/VKD3D (release download or meson build) → `neutron-package.sh` (Steam compat-tool layout + `neutron` launcher + default_pfx).
- **mythix-wine** source = Valve bleeding-edge/proton_10.0 + a TkG diff (extracted live from Kron4ek wine-tkg vs vanilla) + Staging + GE + custom patches, re-merged on every build.

## Findings

### Architecture (the big one)

1. **The mythix-wine patch stack is rebuilt from moving upstreams on every build, then repaired by ~85 inline regex/Python fixups.** It's top-level code in `neutron-builder.sh` lines 2076–4327, with ad-hoc numbering (9h000, 9h00, 9h0, two "Fix 11"s), embedded C structs and IDL, Python heredocs, and a `.mythix-base-stash` of 30+ files to restore when staging breaks them.
   - Fixups can't be toggled one at a time or listed.
   - TkG, Staging, GE and the container image aren't pinned or recorded per build.
   - So builds aren't reproducible or bisectable. That's exactly the wall the black-screen investigation hit ("comment out fixes 22–27 by line number and rebuild").
2. **Duplication everywhere.**
   - Hybrid builders: 89% identical.
   - build-cores: about 60% shared.
   - `_output_common.sh`: copied twice and already drifting (one copy still says looni-build).
   - The wolf banner is pasted into every tool, twice in `mythix-build.sh`.
   - Colour vars disagree: `C_CYN`/`C_MAG` are swapped between proton-builder and neutron-builder.
   - `neutron-builder.sh` resolves `_LIB_DIR` twice.
3. **No shared shell library.** Every tool re-implements colours, logging, path resolution, dependency checks, container detection and fzf pickers.
4. **Two frontends with two tool catalogues.** The bash menu and Python `core/tools.py` each hardcode the 9 tools, their paths and descriptions.

### Bugs found

- **winetoolz crashes**: `local` outside a function under `set -euo pipefail` exits the module immediately:
  - `dll_override_manager.sh`: View/Preset/Add, lines 117/124/168, before the later `set +e`
  - `env_flags.sh`: 163/194/213/266
  - `about.sh`: 124/126
  - Same in `neutron-patcher.sh:212` (the numbered fallback menu).
  - `log_viewer`/`wine_tools` hit it too but survive because of an earlier `set +e`.
  - Verified with bash.
- `helper.sh:33`: misplaced shellcheck directive breaks parsing (shellcheck can't analyse the rest of the file).
- Makefile `py-dev` prints `${C_B}`, an undefined make variable. `install-proton` never creates `PROTON_B_LIBDIR`, but uninstall/discovery expect it.
- Test suite: 72 pass, 1 fails because the `wcwidth` dev dependency isn't declared.

### Metadata and hygiene

- License conflict: `LICENSE` = GPL-2.0, `pyproject.toml` = MIT.
- `neutron.py` cites a `NOTICE` file for Proton attribution, but there isn't one.
- Four different self-URLs: blu2442/mythix-build-system, mythix-org/mythix-build, mythic244442/mythix-build, blu2442/mythix-neutron_builder.
- `v1.0.0` is hardcoded in about 15 places, plus versioned filenames (`*-v1.0.0.sh`).
- Leftover `looni` references in 7 files (some are an intentional `LOONI_ROOT` fallback).
- `textual>=0.80,<2.0` pins to 1.0.0; current is 8.x.
- No CI, CHANGELOG or CONTRIBUTING. The README is 1,410 lines in one file.
- shellcheck: 18 errors (listed above), about 120 warnings; the shell code is otherwise pretty clean. ruff: 91 issues, 42 of them in neutron.py.

## Mythix Wine flavours: preservation notes (2026-10-06)

Luna's direction: Mythix Wine stays "all patches stacked" by design; the other sources cover single patch sets. **Preserve the 10.17 esync/fsync build at all costs.** Add an 11.14 flavour with the black screen fixed (preferred over latest bleeding-edge, because the fixups were written for 11.14).

**Installed 10.17 package:** `~/.steam/steam/compatibilitytools.d/Mythix-Neutron-10.17-1`
- Version file stamped 2026-08-30. The Wine binaries' mtimes are also 08-30, but `builds.log` only shows 10.17 builds on 08-13.
- Its source tree is gone: `~/.local/share/mythix-neutron_builder/src` now holds only `proton-wine-experimental`. **The package is the only exact copy.**

**10.17 recipe (recovered from upstream git):**

| Layer | Pin | Status |
|---|---|---|
| Base | ValveSoftware/wine `proton_10.0` @ `b8fdff8` | Branch has had no commits since 2026-01-19 (same hash as GE-Neutron-8.0-15311-gb8fdff8e1f8) |
| TkG | Kron4ek/wine-tkg `e022fa13cf01228d0ef926545a24f2d53e463159` ("Add 10.17 with esync/fsync"), diffed against vanilla wine-10.17 | On the **`fsync` branch**, frozen since 2025-11-01; not on master |
| Staging | `v10.20` | Final 10.x tag, effectively frozen |
| GE | proton-ge-custom master as of the build | **Only moving input.** Either 08-13 (≈`ce9e5f7`/`a8c99ce`) or 08-30; to be confirmed |
| Build mode | Classic multilib (wine64 + wine32), esync/fsync | — |

**Risks to 10.17 in the current tree:**
- The uncommitted WoW64 WIP turns on the unified `--enable-archs` build for *every* source, including proton_10.0.
- The fixups are shared between the 10.0 and bleeding-edge paths.
- The GE layer floats.
- The container is `ubuntu:24.04` with no digest pin.

**11.14 inputs:**
- Valve **rebases `bleeding-edge`**. The July base `91e9e8fbf62074ade996b167010dd27bf6a90d98` (2026-07-16; the base 11.11-1 worked on) is no longer on the branch, but GitHub still serves it by full SHA. Mirror it before it gets garbage-collected.
- Kron4ek tags: `11.11` = `fdc0a8a`, `11.14` = `7e421cd`.
- GE as of 2026-08-01 ≈ `59fd918`.
- 11.14 was built classic multilib too; the WoW64 WIP came later, alongside the Sept proton-wine-experimental builds.

**Installed builds live in `/stuff/compatibilitytools.d`** (access granted 2026-10-06).

10.17:
- Backups already exist: `Mythix-Neutron-10.17-1/`, `… copy/`, `Mythix-Neutron-10.17-1.zip` (Sep 23; made about 10 minutes before the Sep 23 `neutron` launcher tweak, so the zip has the older launcher).
- `mythix-neutron-10.17-build.log` is the **first** 10.17 build: a container build on Aug 13 UTC, named "TkG Staging Esync Fsync".
  - It confirms base `b8fdff8`, TkG `e022fa13`, staging `v10.20`.
  - GE: 121 applied / 225 skipped. Every fixup that fired is listed.
- The installed 10.17-1's `ntdll.so` says `wine-10.17.r0.gf686957b (Mythix Wine)`, so it comes from the **second** build that day (after the rebrand step was added). That build's log wasn't saved.
- GE for the installed build is `f8e25ab` or `2008775`. The difference is a batch of DualSense haptic patches (proton-ds5-haptic 0130+), plus NtGdiDdDDIQueryAdapterInfo and a protonprep change. None of the haptic strings appear in the installed `winepulse.so`.

11.11-1 (Jul 20, bleeding-edge base):
- Built **classic multilib**: full i386-unix including import libs and a 32-bit loader.
- `bin/` has only `wine`; on the Wine 11 base the 64-bit loader is named `wine`, so there's no `wine64`.
- `winegstreamer.so` was hand-replaced Aug 15.
- 11.14-1 from the black-screen notes is no longer present.

Neutron-11.0-21199 (Sep 12, proton-wine-experimental): already the WoW64 layout (`wine64` copies in i386-unix, per the WIP).

**Mythix-Neutron-11.14-1 found** (`/stuff/compatibilitytools.d/Mythix-Neutron-11.14-1`):
- Built Aug 2. Old packaging: no `version` file, a 73 KB launcher, no bundled dxvk/vkd3d dirs.
- `ntdll.so` reports `wine-11.14.r0.g3e0623e0 ( TkG Staging NTsync )`; 11.11-1 reports `wine-11.11.r0.g4d000a90 ( TkG Staging NTsync )`.
- **The loader binaries are byte-identical to 11.11-1** (md5 of `bin/wine`, the x86_64 loader and the preloaders).
- **But the x86_64-unix loader layout differs:**
  - 11.11 ships `wine`, `wine-preloader`, `wine64`, `wine64-preloader` (the last is a distinct binary, `e22fd…`).
  - 11.14 ships only `wine64` + `wine64-preloader`, and that `wine64-preloader` is the binary 11.11 calls `wine-preloader` (`60286…`).
  - `x86_64-unix/wine` and the distinct 64-preloader are missing.
- The x86_64 ntdll format strings include `%s%s/wine`, `%s-preloader`, `%s64-preloader`. The x86_64 `ntdll.so` is +32 bytes vs 11.11, consistent with Fix 27's extra strlen/strcmp code.
- This is exactly the area fixes 26 (loader64 INSTALL_LIB removal) and 27 (wine6464-preloader naming) touch.
- 11.11 likely ran 32→64 children *without* the preloader, because the doubled name fails and `preloader_exec` falls back to a direct exec. 11.14 finds `wine64-preloader` and uses it.
- 11.14 also ships `libvkd3d.a` (both arches), which 11.11 doesn't (the vkd3d swap fixups).
- **Proposed no-rebuild test:** give 11.14 the exact 11.11 x86_64-unix loader set (add `wine`, `wine-preloader`; swap in 11.11's `wine64-preloader`, keeping 11.14's as a backup), then launch Halo MCC (976730). Renders → the culprit is 26/27. Still black → move on to fix 22/vkd3d.

**Loader tests (2026-10-06):**
- Test A: 11.11's loader set copied into 11.14 → still black.
- Test B: no 64-bit preloader at all → still black.
- **The loader and preloader (fixes 26/27) are cleared.**
- The exit-1 / `double free or corruption` runs came from Luna's own game launcher, not from Wine. Suspects there: its `LD_LIBRARY_PATH` with Steam's `ubuntu12_64`/`ubuntu12_32`, and `gamemoderun`.

**TkG interdiff 11.11 → 11.14** (Kron4ek tag vs vanilla tag, per version):
- **`programs/explorer/desktop.c`: the default driver flips from `mac,x11,wayland` to `mac,wayland,x11`.** Confirmed in the built binaries: 11.11-1 `explorer.exe` = x11-first, 11.14-1 = wayland-first.
  - So on a Wayland session, 11.14 runs games on **winewayland** while 11.11 used XWayland. This matches the "white experimental window borders" in the black-screen notes. **Prime suspect.**
- `ntdll/unix/loader.c`: TkG 11.14 **forces WoW64 by default** (`force_wow64 = !WINEARCH || WINEARCH==wow64`) and uses `ntdll_dir/wine64` as the loader. Kron4ek reverted the WoW64 default by 11.19.
- `loader/Makefile.in` adds wine64 / wine64-preloader targets (explains the layout difference). Also EAC bridge load-order logic, a guard-page vprot tweak in `virtual.c`, and dropped rawinput/xinput2 hunks.
- Vanilla wine 11.11 and 11.14 are both x11-first, but **TkG 11.19 (latest) is still wayland-first**, so a "latest" build would carry the same suspect.
- **Test C (no rebuild):** force X11 on 11.14 (prefix registry `HKCU\Software\Wine\Drivers` Graphics=x11, then `wineserver -k`) and launch Halo.

**Decision (Luna, 2026-10-06): Wayland-first, target 11.19.** Keep the Wayland patches; X11 only for legacy. Next build: `mythix-11.19` on the latest Valve bleeding-edge.

**Findings that shape 11.19:**
- **The builder discards GE's Wayland work.**
  - Layer 4 skips every GE patch whose name matches `*wayland*`. GE master (`a3f58c5`, 2026-10-06) ships ~386 *enabled* Wayland patches: `wine-hotfixes/wine-wayland` (286), `wineland-child-rendering` (57), `em-fixups` (42), plus pending/lsteamclient.
  - They include winewayland Vulkan presentation fixes (coordinate native presenters, match swapchain candidates to activation, preserve presentation owner between swapchains). These are likely the real black-screen fix.
  - Layer 4 also `find | sort`s *all* `*.patch`, including GE's `disabled/` dirs, and ignores GE's ordering.
  - **GE's canonical, ordered application is `patches/protonprep-valve-staging.sh`**: staging with GE's exclusions, then the GE patches, onto Valve's tree.
- **Staging is applied twice.** Kron4ek's TkG tree already contains staging (e.g. `programs/winecfg/staging.c` exists in tkg-11.14/11.19, not in vanilla), then Layer 3 runs staging `--all --force` again. The ~30 "duplicate function" fixups are fallout from this.
- GE's proton script enables Wayland via compat_config `wayland` (`PROTON_ENABLE_WAYLAND`). It sets `WAYLANDDRV_PRIMARY_MONITOR`, the `WINE_WAYLAND_STEAM_OVERLAY_LAYER` overlay layer and `winewayland.drv=b`, and only does so when `WAYLAND_DISPLAY` is set. The neutron launcher should mirror this.
- TkG 11.19 does *not* force WoW64, which is compatible with classic multilib.

**Proposed mythix-11.19 stack:**
1. Valve `bleeding-edge`, pinned (`750fd011356c` as of 2026-10-03).
2. GE via GE's own `protonprep-valve-staging.sh`, pinned commit.
3. A **TkG-only** patch: Kron4ek 11.19 minus (vanilla 11.19 + staging v11.19), computed offline and committed as a pinned `.patch`.
4. Mythix custom patches.
5. Fixups, rewritten as needed.

Classic multilib. Launcher Wayland env, Wayland-default with X11 fallback. Patch stacking is rehearsed in the cloud workspace before builds run on bean2442.

**Cloud rehearsal of the 11.19 stack (2026-10-06):**
- **Valve bleeding-edge is Wine 11.0-lineage.** Commit `1c78596` (2026-09-22) is closest to vanilla wine-11.0 (≈813 files differ, versus 3,300+ for 11.11–11.19). "11.19" therefore means TkG's patchset version; the Wine core is Valve's 11.0 + Valve backports. The same was true for the old 11.11/11.14 builds.
- GE `a3f58c5` pins: wine = ValveSoftware/wine `1c78596625336a73dbfc035dbbcf0dbdd95b06eb` (on current bleeding-edge), wine-staging = `v11.0` (`6cc805e`).
- **GE's `protonprep-valve-staging.sh` wine section applies onto that base with 0 rejects.** That's the revert of e813ca57, wine-wayland (286), wineland child rendering, em-fixups, staging v11.0 with GE's exclusions, game patches, pending, proton, video rework, ds5 haptic and bluetooth, followed by autoreconf + make_requests. 515 files, +91.5k/−37k lines.
- **TkG-only 11.19** = Kron4ek `11.19` minus (wine-11.19 + staging v11.19 `--all`).
  - 65 files. After dropping noise and Kron4ek's own staging reverts (dcomp, dxgi composition swapchain, server dcomp requests), 41 files remain.
  - Real content: belauncher, EAC/BE kernelbase+ntdll+loadorder, LAA override, `wine_nt_to_unix_file_name`, wine64 loader naming, wineboot, wine.inf (ProductId, DisplayVersion/ReleaseId, CustomOverrides for ddraw/winhttp/winmm/version native-first), wayland-first `desktop.c`, winebus hidraw/input default-off, NTSync banner, OpenCL header fix, and a hardcoded "( TkG Staging NTsync )" version string.
- **Dry run of TkG-only onto the GE tree:**
  - Most EAC/BE/loader/wineboot/sechost hunks are already present (Proton has them).
  - About 11 hunks fail: configure.ac ×2 (OpenCL, version rule), kernel32 heap LAA, ntdll.spec exports, virtual.c ×2, winebus defaults, wine.inf ×3, inproc_sync banner.
  - All are small and hand-portable into a curated, clean-applying `mythix-tkg-11.19.patch`.
  - The winebus hidraw-off default is recommended to skip: it conflicts with GE/Proton DualSense hidraw.
- GE Wayland launch env, for launcher parity: `WINE_GRAPHICS_DRIVER=wayland`, `winewayland.drv=b`, `WINE_USE_EGL=1`, `WINE_DISABLE_FULLSCREEN_HACK=1`, `WINE_MOVE_HACK=1`, `WAYLANDDRV_PRIMARY_MONITOR` (auto-detected), plus a Steam overlay Vulkan layer when gameoverlayrenderer is preloaded. Only when `WAYLAND_DISPLAY` is set.
- Overhaul branch confirmed on bean2442: `overhaul` = WIP commit + merge of origin/main.

**Decision (Luna, 2026-10-06):** Mythix Wine flavours (10.17 and the new 11.14) build **classic multilib**. The WoW64 unified build is for the plain Neutron / proton-wine-experimental line.

**Plan agreed in principle:**
- Per-flavour lock profiles: `mythix-10.17` (frozen), `mythix-11.14` (fixable), and later `mythix-latest`.
- WoW64 becomes opt-in per profile.
- Fixups become toggleable per profile.
- Bisect the black screen on 11.14: fixups 22–27 first, then TkG 11.11 vs 11.14 on the same base.
- Acceptance test for 10.17: a rebuild from the lock matches the installed package's file list and sizes.

## Profile system + 11.19 pipeline (implemented 2026-10-06, branch `overhaul`)

**Usage:** `neutron-builder.sh --list-profiles` and `--profile <name> [--container]`. Docs live in `mythix-neutron_builder/profiles/README.md`.

| Profile | Pipeline | Pins | Notes |
|---|---|---|---|
| `mythix-11.19` | `ge` | GE `a3f58c5`, Valve BE `1c78596`, staging `6cc805e` (v11.0), FFmpeg `9047fa1` (8.1, GE's pin) | Curated `0001-mythix-tkg-11.19.patch` + `0002-mythix-build-compat.patch`, patch group `mythix-ds4`, static FFmpeg. Package `Mythix-Neutron-11.19-1`, Wayland-first |
| `mythix-11.11` | `legacy` | Valve `91e9e8f` (by hash), TkG `fdc0a8a`, staging `dc72282`, GE `368ca89` | Reconstructed recipe, unverified. Package `-11.11-2` |
| `mythix-10.17` | `legacy` | proton_10.0 `b8fdff8`, TkG `e022fa1`, staging `v10.20`, GE `2008775` | Frozen. Package `-10.17-2` |

**Pipelines**
- **`mythix-ge-pipeline.sh`:** pinned Valve wine → GE's `protonprep-valve-staging.sh` WINE PATCHING section, verbatim → profile patches (strict) → branding → `mythix-source.lock`.
  - Each layer is a commit.
  - The lock includes `tree_hash` (deterministic) and the FFmpeg pin. The cloud run gave `tree_hash=e8d8a72fb07f…` before DS4.
- **Legacy pipeline:** unchanged behaviour, with pin hooks.
  - Wine is fetched by hash and verified.
  - TkG, staging and GE pins are verified; GE goes into its own `proton-ge-custom-pinned` checkout.
  - Pinned builds start from a pristine tree, and a lock is written.

**Build modes:** `--build-mode classic|wow64`.
- Default: profile → its own mode; `mythix-wine` → classic; everything else → wow64 (keeps the WIP behaviour for the Neutron line).
- `install_wine` and the build-core verification are mode-aware.

**Package additions**
- `build-info`: PROFILE, BUILD_MODE, WAYLAND, SOURCE…
- `mythix-source.lock`, which includes patch-group results.
- The version file holds the profile package name, so the launcher selects build profile `mythix-neutron-11`.

**Launcher (`neutron`)**
- Mirrors GE's winewayland env when the build is Wayland-first (build-info `WAYLAND=1`), or on `NEUTRON_WAYLAND=1`, compat_config `wayland`, or `PROTON_ENABLE_WAYLAND`. Requires `WAYLAND_DISPLAY`.
- `NEUTRON_WAYLAND=0` / `nowayland` sets `WINE_GRAPHICS_DRIVER=x11`.
- `neutron diag` shows the display driver and the reason.

**Findings from the cloud compile test** (Ubuntu 24.04, classic 64-bit, GE+TkG+DS4 tree):
- `winewayland.drv` needs `XKB_VMOD_NAME_SCROLL` (libxkbcommon ≥1.7; 24.04 has 1.6). Fixed by a guarded shim in `0002`.
  - `wl_display_create_queue_with_name` is already version-guarded upstream.
- **GE's media rework removes winegstreamer.** `winedmo` *always* links FFmpeg (`-lswscale -lswresample` are hardcoded), so the tree doesn't link without FFmpeg.
  - GE ships its own FFmpeg (submodule `9047fa1`).
  - Mythix builds that commit static and PIC (`mythix-ffmpeg-build.sh`) and links it into `winedmo.so` (`--exclude-libs,ALL`), so there's no host libavcodec soname dependency.
- `wineopenxr` hard-links `-lopenxr_loader`.
  - `libopenxr-dev` was added to the Containerfile.
  - Build-core disables wineopenxr on an arch that lacks the loader.
- The GE layer's configure.ac has a harmless typo: `AC_CHECK_HEADERS([xkbcommon/xkbcommon.h, …])`.

**Other fixes made along the way**
- `neutron-patcher.sh` used to `git stash` uncommitted tree state before applying groups. That silently dropped the legacy pipeline's fixups from the build, and would have been triggered as soon as `mythix-ds4` existed. It now commits a checkpoint instead.
- Also in the patcher: the stray `local _idx`, per-group `description`/`priority` leaking between groups, and commits without a git identity.
- The container image now rebuilds automatically when `Containerfile.neutron` changes (sha256 label). New deps: `nasm`, `libopenxr-dev`, compression `-dev` libs, `zlib1g-dev:i386`.

**First real build (bean2442, 2026-10-07):** `--profile mythix-11.19 --container` finished in 46 min with zero errors.
- `tree_hash` matched the cloud tree exactly (`e8d8a72f…`).
- DS4 applied; static FFmpeg built for x86_64 and i386.
- 64-bit winedmo, wineopenxr and winewayland all linked.

**Steam client bridge (added after the first build)**
- **The packager had downloaded Proton 9.0-4's lsteamclient** because the build had none.
  - It's a different Wine, and `x86_64-unix/lsteamclient.so` was missing from that archive.
  - Valve's ntdll trampolines Steam's own `steamclient64.dll` into `lsteamclient.dll`, so a mismatched lsteamclient crashes Steam games. That is very likely the old Cyberpunk "ABI mismatch" that made the launcher stop copying steamclient DLLs.
- **Fix: `PROFILE_STEAM_BRIDGE=ge`.**
  - The pipeline runs GE's helper section of protonprep (14 lsteamclient patches; the Discord RPC helper patch is skipped via `STEAM_BRIDGE_SKIP_PATCH_DIRS`).
  - It then adds `dlls/lsteamclient` + `programs/steam_helper` to the Wine tree, so Wine builds them per arch.
  - Verified in the cloud: 64-bit and classic 32-bit trees both build `lsteamclient.dll/.so` + `steam.exe` cleanly.
  - New `tree_hash` with the bridge: `cc363c82593c…`.
- **Packager:** never downloads Proton bits for bridge builds and never overwrites build-installed files. It writes `STEAM_BRIDGE=ge` into build-info.
- **Launcher:** on `STEAM_BRIDGE=ge` builds it follows Proton's Steam model.
  - Steam's legacycompat `steamclient{,64}.dll` go into the prefix.
  - Steam launches (SteamGameId/SteamAppId set) go through the builtin `steam.exe`, which calls `steamclient_init_registry`.
  - Also sets `steam.exe=b`. `NEUTRON_USE_STEAM_SHIM=0/1` overrides.
- **Smaller fixes**
  - The build summary now counts patches from the manifest (it always showed 0).
  - Classic builds verify the `i386-unix` side; Wine 10+ has no `bin/wine64`.
  - Containerfile: `libgnutls28-dev:i386` for 32-bit schannel. It was missing in every earlier classic build.

**Classic layout fails on Valve's 11.x base (2026-10-07)**
- 11.19-1 was built classic. It failed at the first 32-bit process during prefix creation: `failed to load …/i386-windows/ntdll.dll error 4000000e` (STATUS_IMAGE_MACHINE_TYPE_MISMATCH), then `kernel32.dll c0000135`.
- Valve's loader in this tree expects the Proton layout. Proton 11's `i386-unix/` holds `wine`, `wine-preloader`, `wine64` and `wine64-preloader`, and `preloader_exec` hardcodes `i386-unix/wine64-preloader` for 64-bit re-execs.
- Luna's WoW64 WIP (unified `--enable-archs` tree + i386-unix drivers, with the wine64 copies) reproduces that layout and documents this exact c0000135 symptom. Neutron-11.0-21199, built that way, works.
- **Decision: `mythix-11.19` builds `wow64` from now on.** On Wine 11 "classic" no longer gives a `bin/wine64` anyway.
- 10.17 (Wine 10.0, proton_10.0) and the reconstructed 11.11 profile stay classic.
- No-rebuild workaround for 11.19-1: `NEUTRON_USE_WOW64=1` (sets `WINEARCH=wow64`, so 32-bit runs in-process).

## Proposed overhaul order

0. **Safety first:** commit the WoW64 WIP to a branch, pull origin, fix `.git/config`.
1. **Quick-win bug pass:** the `local` crashes, helper.sh, Makefile nits, wcwidth, license/URL/version single source of truth.
2. **Shared shell lib** (`lib/mythix-common.sh`: colours, log, paths, deps, container, pickers, banner) + a single tool manifest that both the bash menu and Python read.
3. **Reproducible patch pipeline:** a lockfile recording every upstream ref plus the container digest per build; fixups extracted into `fixups/NNN-name.sh` (or real .patch files) with a series file, per-fixup enable/disable and `--bisect-fixups`. Longer term: commit the merged result to a maintained mythix-wine fork branch instead of re-merging each build.
4. **Repo layout:** `bin/ lib/ tools/<name>/ share/ docs/`; merge the hybrid builders into one script with `--base proton|neutron`; split the README into `docs/`.
5. **Python frontend modernisation:** current Textual, tool manifest, lint/type config.
6. **CI:** shellcheck + ruff + pytest + bats smoke tests on GitHub Actions.
