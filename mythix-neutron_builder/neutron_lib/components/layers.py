"""Bundled DXVK / VKD3D-Proton."""

import os

from ..common import (check_translation_dll, file_exists,
                      file_is_wine_builtin_dll, log, makedirs, try_copy)
from .base import Component
from ..dist import PREFIX_ARCH_DIRS, TRANSLATION_LAYERS
from ..version import profile


# — the bundled DXVK / VKD3D-Proton (TRANSLATION_LAYERS) —
class TranslationLayers(Component):
    name = "layers"
    title = "translation layers (bundled)"

    def _wined3d(self):
        return "wined3d" in self.session.compat_config

    def _read_ours(self):
        ours = {}
        try:
            with open(self.compatdata.translation_files_file) as f:
                for line in f:
                    parts = line.rstrip("\n").split("\t")
                    if len(parts) == 3:
                        ours[parts[0]] = (int(parts[1]), int(parts[2]))
        except (OSError, ValueError):
            pass
        return ours

    def _is_ours(self, rel, ours):
        """True when the file at rel is byte-for-byte the copy Neutron placed
        (size+mtime recorded at install; try_copy preserves the source mtime).
        A user-replaced DLL differs and is preserved."""
        if rel not in ours:
            return False
        try:
            st = os.stat(os.path.join(self.compatdata.prefix, rel))
        except OSError:
            return False
        return (st.st_size, int(st.st_mtime)) == ours[rel]

    def install(self, track_file):
        log("installing bundled graphics runtime DLLs...")
        n, cd = self.neutron, self.compatdata
        installed = []
        ours = self._read_ours()

        def install(src, dst_dir, dll):
            rel = dst_dir + "/" + dll
            dst = os.path.join(cd.prefix, rel)
            expect = "x64" if dst_dir.endswith("system32") else "x86"
            problem = check_translation_dll(src, expect)
            if problem:
                log(f"WARNING: skipping bundled {os.path.relpath(src, n.dir)}: "
                    f"{problem} — prefix keeps its current {dll}")
                return
            # Replace Wine builtins and our own earlier copies; anything else
            # is a user-installed native DLL (winetricks, manual) — keep it.
            if file_exists(dst, follow_symlinks=False) and \
                    not file_is_wine_builtin_dll(dst) and \
                    not self._is_ours(rel, ours):
                log(f"preserving user-native graphics DLL: {rel}")
                return
            makedirs(os.path.join(cd.prefix, dst_dir))
            try_copy(src, rel, prefix=cd.prefix, track_file=track_file)
            try:
                st = os.stat(dst)
                ours[rel] = (st.st_size, int(st.st_mtime))
            except OSError:
                pass
            installed.append(dll)

        # WineD3D is an explicit request to use Wine's OpenGL Direct3D path,
        # so a layer marked wined3d_off (DXVK) isn't placed where it would
        # override it — and the Wine builtins go back over copies Neutron
        # itself installed earlier (user-installed natives are left alone).
        wined3d = self._wined3d()
        for layer in TRANSLATION_LAYERS:
            for arch, dst_dir in PREFIX_ARCH_DIRS:
                if not (wined3d and layer.wined3d_off):
                    for dll, src in n.layer_dlls(layer, arch):
                        install(src, dst_dir, dll + ".dll")
                    continue
                for dll in layer.dlls:
                    rel = f"{dst_dir}/{dll}.dll"
                    dst = os.path.join(cd.prefix, rel)
                    builtin = os.path.join(n.default_pfx_dir, rel)
                    if self._is_ours(rel, ours) and \
                            file_exists(builtin, follow_symlinks=True):
                        log(f"restoring Wine builtin {rel} (wined3d)")
                        os.remove(dst)
                        cd._pfx_copy(builtin, dst)
                        ours.pop(rel, None)

        try:
            with open(cd.translation_files_file, "w") as f:
                for rel, (size, mtime) in sorted(ours.items()):
                    f.write(f"{rel}\t{size}\t{mtime}\n")
        except OSError:
            pass
        if installed:
            log("installed bundled DXVK/VKD3D-Proton runtime DLLs")

    def overrides(self):
        # Only for DLLs we actually ship, in the profile's style ("n" =
        # native-only like Proton, no silent fallback).
        style = profile()["d3d_override"]
        wined3d = self._wined3d()
        return {dll: style
                for layer in TRANSLATION_LAYERS
                if not (wined3d and layer.wined3d_off)
                for dll, _ in self.neutron.layer_dlls(layer, "x64")}

    def diag(self, kv):
        n = self.neutron
        found = False
        for layer in TRANSLATION_LAYERS:
            for arch, _ in PREFIX_ARCH_DIRS:
                d = n.layer_dir(layer, arch)
                if not d:
                    continue
                found = True
                sub = os.path.basename(d)
                for dll in sorted(os.listdir(d)):
                    if not dll.lower().endswith(".dll"):
                        continue
                    if dll.lower()[:-4] not in layer.dlls:
                        # Wine's own libvkd3d placeholders and the like
                        kv(f"{layer.name} {sub}/{dll}",
                           "skipped (not in manifest, never installed)")
                        continue
                    problem = check_translation_dll(os.path.join(d, dll), arch)
                    kv(f"{layer.name} {sub}/{dll}",
                       "ok" if problem is None else f"BAD — {problem}")
        if not found:
            kv("(none)", "no bundled DXVK/VKD3D-Proton dirs under files/lib/wine")
        kv("overrides style", profile()["d3d_override"]
           + (" (wined3d: DXVK overrides off)" if self._wined3d() else ""))
