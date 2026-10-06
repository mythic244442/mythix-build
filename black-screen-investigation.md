# Mythix Wine 11.14 Black Screen Investigation

## The Problem
Games launch and create a window but render a completely black screen on Mythix-Neutron-11.14-1 builds. The same game prefix works perfectly with Mythix-Neutron-11.11-1 (renders game, loads 416 cached DXVK shaders). This confirms the issue is in the Wine binaries, not the prefix.

## What We Know For Sure
1. **DXVK loads correctly as native** — d3d11.dll, d3d9.dll, dxgi.dll all show `: native` in loaddll trace
2. **DXVK v3.0.2 initializes fully** — finds NVIDIA GTX 1660 Ti, creates swapchain (1920x1080, FIFO, 3 images), but **0 shaders ever compile** — the game never reaches its render loop
3. **The prefix is not corrupted** — swapping to 11.11-1 Wine on the same prefix renders fine
4. **It's NOT the bleeding-edge code changes** — we pinned the 11.14 build to the exact same bleeding-edge commit (91e9e8fbf62) that 11.11-1 was built from, cherry-picked all non-vulkan commits, and it STILL black-screens
5. **Binary swapping between builds doesn't work** — internal ABI dependencies crash when mixing components
6. **This is on native Wayland** — no XWayland. XWayland didn't fix it either though
7. **White experimental window borders** appear on 11.14 but not 11.11 — suggests wm integration works but client rendering is broken

## Where The Regression Must Be
Since the same bleeding-edge base produces different results, the difference is in the **build pipeline**, not the Wine source code. Specifically:

### Suspect 1: Builder Fixups 22-27 (HIGHEST PRIORITY)
The 11.11-1 build was made on Jul 19 BEFORE fixes 22-27 were added. The 11.14 build applies all of them. One or more could be breaking rendering.

**Fix 22** — vkd3d fstat→fread rewrite + vfprintf silencing in debug.c
- Rewrites `vkd3d_shader_code_from_file` to use fread instead of fstat
- **Silences ALL vkd3d debug output** by replacing `vfprintf(stderr, fmt, args)` with `(void)fmt; (void)args;`
- Location in builder: line ~3648
- NOTE: Halo MCC uses DXVK (D3D11→Vulkan), not vkd3d (D3D12→Vulkan), so this may not affect Halo directly. But if vkd3d initialization code runs anyway and crashes silently due to the vfprintf silencing, it could block the whole Wine Vulkan pipeline.

**Fix 23** — wmvcore winedmo→winegstreamer rename
- Renames function calls and DELAYIMPORTS in wmvcore
- Location in builder: line ~3634
- Low suspicion for rendering, but could cause media init failures

**Fix 24** — ir50_32/iyuv_32 reverted to bleeding-edge
- Reverts codec DLLs that TkG patches broke
- Location in builder: line ~3574
- Low suspicion

**Fix 25** — mmdevapi `should_hide_from_endpoint_collection` stub
- Adds a stub that always returns FALSE
- Location in builder: line ~3619
- Could cause audio subsystem to enumerate phantom devices and stall init

**Fix 26** — Remove INSTALL_LIB from loader64/Makefile.in
- Prevents duplicate wine64 install
- Location in builder: line ~3589
- Could affect how wine64 binary resolves at runtime

**Fix 27** — ntdll wine6464-preloader path doubling fix
- Fixes the preloader path from "wine6464-preloader" to "wine64-preloader"
- Location in builder: line ~3599
- **If this fix doesn't trigger correctly, could break process creation entirely**

### Suspect 2: TkG/Staging/GE Patch Version Differences
The TkG reference repo, Staging patches, and GE patches may have updated between the 11.11-1 build (Jul 19) and the 11.14 build (Jul 31). Different patch content could introduce regressions.

### Suspect 3: Build Environment
The build uses a Podman container. Container image updates, compiler version changes, or different library versions could produce different binaries even from the same source.

### Suspect 4: Default Prefix Differences
The 11.14 build's default_pfx is missing several items that 11.11-1 has:
- `dxvk-nvapi-layer/` directory
- `creation_sync_guard` file
- `.NET runtime` files
These are normally set up by createprefix/the packaging step. Missing DXVK-NVAPI layer config could affect Vulkan device selection.

## Binary Comparison Data
Files that differ between builds (runtime binaries only):

### x86_64-unix (native Linux .so files):
| File | 11.11-1 | 11.14-1 | Delta |
|------|---------|---------|-------|
| win32u.so | 2,202,072 | 2,205,984 | +3,912 |
| ntdll.so | 765,352 | 765,384 | +32 |
| winebus.so | 110,736 | 110,824 | +88 |
| winepulse.so | 117,944 | 117,984 | +40 |
| winex11.so | 556,664 | 556,640 | -24 |
| secur32.so | 44,760 | 53,096 | +8,336 |
| **winevulkan.so** | **921,360** | **921,360** | **0** |

### i386-unix:
| File | 11.11-1 | 11.14-1 | Delta |
|------|---------|---------|-------|
| **winevulkan.so** | **721,548** | **725,644** | **+4,096** |
| win32u.so | 2,736,968 | 2,736,648 | -320 |
| winepulse.so | 114,496 | 114,568 | +72 |

**Key finding**: x86_64 winevulkan.so is IDENTICAL between builds. i386 winevulkan.so differs by 4KB. Since Halo MCC is 64-bit and uses x86_64 winevulkan, the winevulkan thunking layer itself is probably not the issue. The 3.9KB growth in x86_64 win32u.so (which contains Vulkan dispatch code) is more interesting.

## Files & Paths

| Item | Path |
|------|------|
| Working build | `/stuff/compatibilitytools.d/Mythix-Neutron-11.11-1/` |
| Broken build | `/stuff/compatibilitytools.d/Mythix-Neutron-11.14-1/` |
| Builder script | `/home/blu2442/mythix-build/mythix-neutron_builder/neutron-builder.sh` |
| Wine source (after build) | `/home/blu2442/.local/share/mythix-neutron_builder/src/mythix-wine/` |
| TkG reference | `/home/blu2442/.local/share/mythix-neutron_builder/src/wine-tkg-ref/` |
| Halo game prefix | `/home/blu2442/.mythix/gamez-pfx_data/mythix-976730/pfx/` |
| Neutron launcher | `/stuff/compatibilitytools.d/Mythix-Neutron-11.14-1/neutron` |

## Investigation Plan

### Phase 1: Isolate the fixups (fastest path)
1. **Comment out ALL of fixes 22-27** in neutron-builder.sh (lines ~3574-3716)
2. Keep the bleeding-edge pin + cherry-picks as-is
3. Rebuild and test
4. If it renders → re-enable fixups one at a time to find the culprit
5. If still black → fixups aren't the cause, move to Phase 2

### Phase 2: Compare patch application
1. Check git log of `wine-tkg-ref` to see if TkG patches updated between Jul 19 and Jul 31
2. Compare the Staging/GE patch sets applied in each build (check builder log timestamps)
3. Look at the actual patched source in `mythix-wine/` for differences in win32u Vulkan dispatch

### Phase 3: Runtime debugging
1. Run the broken build with `WINEDEBUG=+vulkan` to trace every Vulkan call
2. Compare Vulkan call sequence between 11.11-1 and 11.14-1 launches
3. Check if DXVK's `vkCreateSwapchainKHR` succeeds but `vkAcquireNextImageKHR` never gets called
4. Use `VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation` with layers from `/media/blu2442/xfs_sd/game_stuff/vulkan_layers/1.4.335.0/x86_64/`
5. Run with `DXVK_LOG_LEVEL=debug` to see full DXVK internal state

### Phase 4: Win32u deep dive
The 3.9KB size difference in win32u.so is significant. win32u handles:
- Window management (surface creation, compositing)
- Vulkan WSI (window system integration) — surface creation, swapchain presentation
- Display mode changes

The `NtUserChangeDisplaySettings returned -2` error seen in 11.14 logs (DISP_CHANGE_BADMODE) during explorer init could be related. Compare the Vulkan WSI code path in win32u between builds:
- `dlls/win32u/vulkan.c` — Vulkan surface/swapchain creation
- `dlls/win32u/sysparams.c` — display settings

### Key Question to Answer
**Does DXVK's `vkQueuePresentKHR` ever get called?** If the swapchain is created but presentation never happens, the issue is between DXVK submitting frames and Wine's Vulkan WSI delivering them to the Wayland compositor. That points to win32u.so's Vulkan dispatch or the Wayland driver's surface handling.

## How to Test
```bash
# Launch Halo MCC (Steam app 976730) with the broken build:
cd /stuff/compatibilitytools.d/Mythix-Neutron-11.14-1

# Full Vulkan debug:
WINEDEBUG=+vulkan DXVK_LOG_LEVEL=debug ./files/bin/wine64 \
  "/home/blu2442/.mythix/gamez-pfx_data/mythix-976730/pfx/drive_c/Program Files (x86)/Steam/steamapps/common/Halo The Master Chief Collection/mcclauncher.exe" \
  2>&1 | tee /tmp/vulkan-debug.log

# Or via the Neutron launcher:
WINEDEBUG=+vulkan DXVK_LOG_LEVEL=debug python3 ./neutron \
  waitforexitandrun \
  "/home/blu2442/.mythix/gamez-pfx_data/mythix-976730/pfx/drive_c/Program Files (x86)/Steam/steamapps/common/Halo The Master Chief Collection/mcclauncher.exe" \
  2>&1 | tee /tmp/vulkan-debug.log
```

## Summary
The black screen is NOT caused by Wine source code changes (we proved this by building from the same commit). It's caused by something in the build pipeline — most likely the new fixups 22-27 that were added after the working 11.11-1 build. Start by disabling those fixups and rebuilding. If that doesn't fix it, compare the TkG/Staging/GE patch versions between builds.
