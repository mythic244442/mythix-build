# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  mythix-build  •  Makefile  (subdirectory layout)                           ║
# ║  Installs / uninstalls all builder and winetoolz scripts                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage:
#   make install          — install everything to $(PREFIX)
#   make install-neutron  — install only mythix-neutron_builder
#   make install-proton   — install only mythix-proton_builder
#   make install-wine     — install only mythix-wine_builder
#   make install-hybrid   — install only mythix-wine-proton_hybrid_builder
#   make install-toolz    — install only mythix-winetoolz
#   make uninstall        — remove everything installed by this Makefile
#   make help             — show this reference
#
# Variables:
#   PREFIX=<dir>    Install root  (default: ~/.local)
#   DESTDIR=<dir>   Staging root  (default: empty — install live)
#
#   make install PREFIX=~/.local          # user install (default)
#   make install PREFIX=/usr/local        # system-wide (needs sudo)
#   make install DESTDIR=/tmp/pkg         # staged for packaging
#

# ── Install layout ────────────────────────────────────────────────────────────
PREFIX  ?= $(HOME)/.local
BINDIR  := $(PREFIX)/bin

# Each sub-project gets its own lib directory so internal SCRIPT_DIR-relative
# paths continue to work correctly after install.
NEUTRON_LIBDIR  := $(PREFIX)/lib/mythix-neutron_builder
PROTON_B_LIBDIR := $(PREFIX)/lib/mythix-proton_builder
WINE_LIBDIR     := $(PREFIX)/lib/mythix-wine_builder
HYBRID_LIBDIR   := $(PREFIX)/lib/mythix-wine-proton_hybrid_builder
NHYBRID_LIBDIR  := $(PREFIX)/lib/mythix-wine-neutron_hybrid_builder
TOOLZ_LIBDIR    := $(PREFIX)/lib/mythix-winetoolz
NEUTRON_I_LIBDIR := $(PREFIX)/lib/mythix-neutron-install
PROTON_I_LIBDIR  := $(PREFIX)/lib/mythix-proton-install

CFGDIR  := $(HOME)/.config/mythix-build
DESTDIR ?=

# ── .bashrc management ───────────────────────────────────────────────────
BASHRC          := $(HOME)/.bashrc
MARKER_PATH_B   := \# ── mythix-build PATH ──
MARKER_PATH_E   := \# ── end mythix-build PATH ──
MARKER_WINE_B   := \# ── mythix-build wine-default ──
MARKER_WINE_E   := \# ── end mythix-build wine-default ──

# ── Source roots ──────────────────────────────────────────────────────────────
ROOT   := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))
LAUNCHER := $(ROOT)mythix-build.sh
NEUTRON   := $(ROOT)mythix-neutron_builder
PROTON_B  := $(ROOT)mythix-proton_builder
WINE      := $(ROOT)mythix-wine_builder
HYBRID    := $(ROOT)mythix-wine-proton_hybrid_builder
NHYBRID   := $(ROOT)mythix-wine-neutron_hybrid_builder
TOOLZ     := $(ROOT)mythix-winetoolz
NEUTRON_I := $(ROOT)mythix-neutron-install
PROTON_I  := $(ROOT)mythix-proton-install

# ── File lists ────────────────────────────────────────────────────────────────

# neutron_builder: launcher + engine scripts
NEUTRON_BIN  := neutron-builder.sh
NEUTRON_LIBS := \
    _output_common.sh \
    neutron-build-core.sh \
    neutron-dxvk-build.sh \
    neutron-vkd3d-build.sh \
    neutron-package.sh \
    neutron-patcher.sh \
    neutron.py \
    dxvk.conf \
    vkd3d-proton.conf \
    spinner.sh \
    ntsync.h \
    deps-neutron-tkg \
    Containerfile.neutron
NEUTRON_CFG  := neutron-customization.cfg

# proton_builder: single delegated-build script (wraps GE-Proton / TKG)
PROTON_B_BIN  := proton-builder.sh

# wine_builder: launcher + engine scripts
WINE_BIN  := wine-builder.sh
WINE_LIBS := \
    _output_common.sh \
    wine-build-core.sh \
    build-32.sh \
    build-64.sh \
    helper.sh \
    install-from-build.sh \
    wine-tkg-patcher.sh \
    deps-tkg
WINE_CFG  := customization.cfg

# hybrid installers: launcher only
HYBRID_BIN  := wine-proton_hybrid-v1.0.0.sh
NHYBRID_BIN := wine-neutron_hybrid-v1.0.0.sh

# neutron-install: single script
NEUTRON_I_BIN := neutron-install.sh

# proton-install: single script
PROTON_I_BIN := proton-install.sh

# winetoolz: launcher + all modules
TOOLZ_BIN     := wine_toolz.sh
TOOLZ_MODULES := \
    modules/winetoolz-lib.sh \
    modules/shared_lib/about.sh \
    modules/shared_lib/app_launcher.sh \
    modules/shared_lib/directx_installer-local.sh \
    modules/shared_lib/dll_installer.sh \
    modules/shared_lib/dll_override_manager.sh \
    modules/shared_lib/dxvk_setup-gui.sh \
    modules/shared_lib/env_flags.sh \
    modules/shared_lib/install_components-x86_64.sh \
    modules/shared_lib/install_nvapi.sh \
    modules/shared_lib/log_viewer.sh \
    modules/shared_lib/prefix_diagnostics.sh \
    modules/shared_lib/prefix_manager.sh \
    modules/shared_lib/runtime_manager.sh \
    modules/shared_lib/runtimes_installer.sh \
    modules/shared_lib/setup_vkd3d_proton-gui.sh \
    modules/shared_lib/vcruntime_installer-gui.sh \
    modules/shared_lib/wine_tools.sh \
    modules/shared_lib/wine_install_manager.sh \
    modules/shared_lib/winetoolz-prefix-maker.sh

# ── Phony targets ─────────────────────────────────────────────────────────────
.PHONY: all install install-neutron install-proton install-wine install-hybrid install-neutron-hybrid install-toolz \
        install-launcher install-neutron-install install-proton-install uninstall help _dirs _setup-path \
        py-dev py-test py-tui py-doctor py-clean

all: help

# ── install ───────────────────────────────────────────────────────────────────
install: _dirs install-launcher install-neutron install-proton install-wine install-hybrid install-neutron-hybrid install-toolz install-neutron-install install-proton-install _setup-path
	@printf "\n\033[1;32m ✓  mythix-build installed to %s\033[0m\n\n" "$(DESTDIR)$(PREFIX)"
	@printf "  mythix-build        → $(DESTDIR)$(BINDIR)/mythix-build\n"
	@printf "  neutron-builder    → $(DESTDIR)$(BINDIR)/neutron-builder\n"
	@printf "  neutron-install    → $(DESTDIR)$(BINDIR)/neutron-install\n"
	@printf "  proton-builder     → $(DESTDIR)$(BINDIR)/proton-builder\n"
	@printf "  proton-install     → $(DESTDIR)$(BINDIR)/proton-install\n"
	@printf "  wine-builder       → $(DESTDIR)$(BINDIR)/wine-builder\n"
	@printf "  wine_toolz         → $(DESTDIR)$(BINDIR)/wine_toolz\n"
	@printf "  wine-proton_hybrid  → $(DESTDIR)$(BINDIR)/wine-proton_hybrid\n"
	@printf "  wine-neutron_hybrid → $(DESTDIR)$(BINDIR)/wine-neutron_hybrid\n"
	@printf "  config             → $(DESTDIR)$(CFGDIR)/\n\n"
	@printf "  Make sure \033[1m$(PREFIX)/bin\033[0m is in your PATH.\n\n"

_dirs:
	install -d "$(DESTDIR)$(BINDIR)"
	install -d "$(DESTDIR)$(NEUTRON_I_LIBDIR)"
	install -d "$(DESTDIR)$(PROTON_I_LIBDIR)"
	install -d "$(DESTDIR)$(NEUTRON_LIBDIR)"
	install -d "$(DESTDIR)$(NEUTRON_LIBDIR)/patches"
	install -d "$(DESTDIR)$(WINE_LIBDIR)"
	install -d "$(DESTDIR)$(WINE_LIBDIR)/patches"
	install -d "$(DESTDIR)$(HYBRID_LIBDIR)"
	install -d "$(DESTDIR)$(HYBRID_LIBDIR)/buildz"
	install -d "$(DESTDIR)$(NHYBRID_LIBDIR)"
	install -d "$(DESTDIR)$(NHYBRID_LIBDIR)/buildz"
	install -d "$(DESTDIR)$(TOOLZ_LIBDIR)/modules/shared_lib"
	install -d "$(DESTDIR)$(CFGDIR)"

# ── mythix-neutron_builder ──────────────────────────────────────────────────────
install-neutron: _dirs
	@printf "\033[1;36m── mythix-neutron_builder\033[0m\n"
	install -m 755 "$(NEUTRON)/$(NEUTRON_BIN)" \
	    "$(DESTDIR)$(BINDIR)/neutron-builder"
	@printf "  \033[1;32m+\033[0m $(DESTDIR)$(BINDIR)/neutron-builder\n"
	@for f in $(NEUTRON_LIBS); do \
	    src="$(NEUTRON)/$$f"; \
	    [ -f "$$src" ] || { printf "  \033[2mskip (not found): $$f\033[0m\n"; continue; }; \
	    install -m 755 "$$src" "$(DESTDIR)$(NEUTRON_LIBDIR)/$$f"; \
	    printf "  \033[1;32m+\033[0m $(DESTDIR)$(NEUTRON_LIBDIR)/$$f\n"; \
	done
	@if [ -d "$(NEUTRON)/patches" ]; then \
	    rm -rf "$(DESTDIR)$(NEUTRON_LIBDIR)/patches"; \
	    cp -a "$(NEUTRON)/patches" "$(DESTDIR)$(NEUTRON_LIBDIR)/patches"; \
	    printf "  \033[1;32m+\033[0m $(DESTDIR)$(NEUTRON_LIBDIR)/patches/ (%s groups)\n" \
	        "$$(find "$(DESTDIR)$(NEUTRON_LIBDIR)/patches" -mindepth 1 -maxdepth 1 -type d | wc -l)"; \
	fi
	@src="$(NEUTRON)/$(NEUTRON_CFG)"; dest="$(DESTDIR)$(CFGDIR)/$(NEUTRON_CFG)"; \
	[ -f "$$src" ] || exit 0; \
	if [ -f "$$dest" ]; then \
	    printf "  \033[2m~ keep existing: $$dest\033[0m\n"; \
	else \
	    install -m 644 "$$src" "$$dest"; \
	    printf "  \033[1;32m+\033[0m $$dest\n"; \
	fi

# ── mythix-proton_builder ──────────────────────────────────────────────────────
install-proton: _dirs
	@printf "\033[1;36m── mythix-proton_builder\033[0m\n"
	@if [ -f "$(PROTON_B)/$(PROTON_B_BIN)" ]; then \
	    install -m 755 "$(PROTON_B)/$(PROTON_B_BIN)" "$(DESTDIR)$(BINDIR)/proton-builder"; \
	    printf "  \033[1;32m+\033[0m $(DESTDIR)$(BINDIR)/proton-builder\n"; \
	else \
	    printf "  \033[2mskip (not found): $(PROTON_B)/$(PROTON_B_BIN)\033[0m\n"; \
	fi

# ── mythix-wine_builder ────────────────────────────────────────────────────────
install-wine: _dirs
	@printf "\033[1;36m── mythix-wine_builder\033[0m\n"
	install -m 755 "$(WINE)/$(WINE_BIN)" \
	    "$(DESTDIR)$(BINDIR)/wine-builder"
	@printf "  \033[1;32m+\033[0m $(DESTDIR)$(BINDIR)/wine-builder\n"
	@for f in $(WINE_LIBS); do \
	    src="$(WINE)/$$f"; \
	    [ -f "$$src" ] || { printf "  \033[2mskip (not found): $$f\033[0m\n"; continue; }; \
	    install -m 755 "$$src" "$(DESTDIR)$(WINE_LIBDIR)/$$f"; \
	    printf "  \033[1;32m+\033[0m $(DESTDIR)$(WINE_LIBDIR)/$$f\n"; \
	done
	@src="$(WINE)/$(WINE_CFG)"; dest="$(DESTDIR)$(CFGDIR)/$(WINE_CFG)"; \
	[ -f "$$src" ] || exit 0; \
	if [ -f "$$dest" ]; then \
	    printf "  \033[2m~ keep existing: $$dest\033[0m\n"; \
	else \
	    install -m 644 "$$src" "$$dest"; \
	    printf "  \033[1;32m+\033[0m $$dest\n"; \
	fi

# ── mythix-neutron-install ────────────────────────────────────────────────────
install-neutron-install: _dirs
	@printf "\033[1;36m── mythix-neutron-install\033[0m\n"
	install -m 755 "$(NEUTRON_I)/$(NEUTRON_I_BIN)" \
	    "$(DESTDIR)$(BINDIR)/neutron-install"
	@printf "  \033[1;32m+\033[0m $(DESTDIR)$(BINDIR)/neutron-install\n"
	install -m 755 "$(NEUTRON_I)/$(NEUTRON_I_BIN)" \
	    "$(DESTDIR)$(NEUTRON_I_LIBDIR)/$(NEUTRON_I_BIN)"
	@printf "  \033[1;32m+\033[0m $(DESTDIR)$(NEUTRON_I_LIBDIR)/$(NEUTRON_I_BIN)\n"

# ── mythix-proton-install ─────────────────────────────────────────────────────
install-proton-install: _dirs
	@printf "\033[1;36m── mythix-proton-install\033[0m\n"
	install -m 755 "$(PROTON_I)/$(PROTON_I_BIN)" \
	    "$(DESTDIR)$(BINDIR)/proton-install"
	@printf "  \033[1;32m+\033[0m $(DESTDIR)$(BINDIR)/proton-install\n"
	install -m 755 "$(PROTON_I)/$(PROTON_I_BIN)" \
	    "$(DESTDIR)$(PROTON_I_LIBDIR)/$(PROTON_I_BIN)"
	@printf "  \033[1;32m+\033[0m $(DESTDIR)$(PROTON_I_LIBDIR)/$(PROTON_I_BIN)\n"

# ── mythix-build launcher ─────────────────────────────────────────────────────
install-launcher: _dirs
	@printf "\033[1;36m── mythix-build launcher\033[0m\n"
	install -m 755 "$(LAUNCHER)" \
	    "$(DESTDIR)$(BINDIR)/mythix-build"
	@printf "  \033[1;32m+\033[0m $(DESTDIR)$(BINDIR)/mythix-build\n"

# ── mythix-wine-proton_hybrid_builder ─────────────────────────────────────────
install-hybrid: _dirs
	@printf "\033[1;36m── mythix-wine-proton_hybrid_builder\033[0m\n"
	@if [ -f "$(HYBRID)/$(HYBRID_BIN)" ]; then \
	    install -m 755 "$(HYBRID)/$(HYBRID_BIN)" "$(DESTDIR)$(BINDIR)/wine-proton_hybrid"; \
	    printf "  \033[1;32m+\033[0m $(DESTDIR)$(BINDIR)/wine-proton_hybrid\n"; \
	else \
	    printf "  \033[2mskip (not found): $(HYBRID)/$(HYBRID_BIN)\033[0m\n"; \
	fi

# ── mythix-wine-neutron_hybrid_builder ────────────────────────────────────────
install-neutron-hybrid: _dirs
	@printf "\033[1;36m── mythix-wine-neutron_hybrid_builder\033[0m\n"
	@if [ -f "$(NHYBRID)/$(NHYBRID_BIN)" ]; then \
	    install -m 755 "$(NHYBRID)/$(NHYBRID_BIN)" "$(DESTDIR)$(BINDIR)/wine-neutron_hybrid"; \
	    printf "  \033[1;32m+\033[0m $(DESTDIR)$(BINDIR)/wine-neutron_hybrid\n"; \
	else \
	    printf "  \033[2mskip (not found): $(NHYBRID)/$(NHYBRID_BIN)\033[0m\n"; \
	fi

# ── mythix-winetoolz ───────────────────────────────────────────────────────────
install-toolz: _dirs
	@printf "\033[1;36m── mythix-winetoolz\033[0m\n"
	install -m 755 "$(TOOLZ)/$(TOOLZ_BIN)" \
	    "$(DESTDIR)$(BINDIR)/wine_toolz"
	@printf "  \033[1;32m+\033[0m $(DESTDIR)$(BINDIR)/wine_toolz\n"
	@for f in $(TOOLZ_MODULES); do \
	    src="$(TOOLZ)/$$f"; \
	    [ -f "$$src" ] || { printf "  \033[2mskip (not found): $$f\033[0m\n"; continue; }; \
	    install -m 755 "$$src" "$(DESTDIR)$(TOOLZ_LIBDIR)/$$f"; \
	    printf "  \033[1;32m+\033[0m $(DESTDIR)$(TOOLZ_LIBDIR)/$$f\n"; \
	done
	@printf '#!/usr/bin/env bash\n_d="$$(cd "$$(dirname "$$(readlink -f "$${BASH_SOURCE[0]}")")" && pwd)"\nexec bash "$${_d}/../lib/mythix-winetoolz/modules/shared_lib/wine_install_manager.sh" "$$@"\n' \
	    > "$(DESTDIR)$(BINDIR)/wine_install_mgr"
	@chmod 755 "$(DESTDIR)$(BINDIR)/wine_install_mgr"
	@printf "  \033[1;32m+\033[0m $(DESTDIR)$(BINDIR)/wine_install_mgr\n"

# ── .bashrc PATH setup (skipped during staged/packaged installs) ─────────────
_setup-path:
	@if [ -n "$(DESTDIR)" ]; then exit 0; fi; \
	if [ -f "$(BASHRC)" ] && grep -qF '$(MARKER_PATH_B)' "$(BASHRC)"; then \
	    printf "  \033[2m~/.bashrc: mythix-build PATH block already present — skipped\033[0m\n"; \
	else \
	    { printf '\n$(MARKER_PATH_B)\n'; \
	      printf 'export PATH="%s/bin:$$PATH"\n' "$(PREFIX)"; \
	      printf '$(MARKER_PATH_E)\n'; \
	    } >> "$(BASHRC)"; \
	    printf "  \033[1;32m+\033[0m ~/.bashrc: added mythix-build PATH block\n"; \
	    printf "    \033[2mRun:  source ~/.bashrc   (or open a new terminal)\033[0m\n"; \
	fi

# ── uninstall ─────────────────────────────────────────────────────────────────
uninstall:
	@printf "\033[1;33mRemoving mythix-build from %s ...\033[0m\n" "$(DESTDIR)$(PREFIX)"
	@for cmd in mythix-build neutron-builder neutron-install proton-builder proton-install wine-builder wine_toolz wine_install_mgr wine-proton_hybrid wine-neutron_hybrid; do \
	    f="$(DESTDIR)$(BINDIR)/$$cmd"; \
	    [ -f "$$f" ] && { rm -f "$$f"; printf "  \033[1;31m-\033[0m $$f\n"; } || true; \
	done
	@for d in "$(DESTDIR)$(NEUTRON_LIBDIR)" \
	          "$(DESTDIR)$(NEUTRON_I_LIBDIR)" \
	          "$(DESTDIR)$(PROTON_B_LIBDIR)" \
	          "$(DESTDIR)$(WINE_LIBDIR)" \
	          "$(DESTDIR)$(HYBRID_LIBDIR)" \
	          "$(DESTDIR)$(NHYBRID_LIBDIR)" \
	          "$(DESTDIR)$(TOOLZ_LIBDIR)" \
	          "$(DESTDIR)$(PROTON_I_LIBDIR)"; do \
	    [ -d "$$d" ] && { rm -rf "$$d"; printf "  \033[1;31m-\033[0m $$d/\n"; } || true; \
	done
	@printf "\n\033[1;32m ✓  Uninstall complete.\033[0m\n"
	@printf "    Config in \033[1m$(DESTDIR)$(CFGDIR)\033[0m left in place — remove manually if needed.\n\n"
	@if [ -n "$(DESTDIR)" ]; then exit 0; fi; \
	_has_path=false; _has_wine=false; \
	if [ -f "$(BASHRC)" ] && grep -qF '$(MARKER_PATH_B)' "$(BASHRC)"; then _has_path=true; fi; \
	if [ -f "$(BASHRC)" ] && grep -qF '$(MARKER_WINE_B)' "$(BASHRC)"; then _has_wine=true; fi; \
	if [ "$$_has_path" = "true" ] || [ "$$_has_wine" = "true" ]; then \
	    printf "\033[1;33m  mythix-build entries found in ~/.bashrc:\033[0m\n"; \
	    [ "$$_has_path" = "true" ] && printf "    • mythix-build PATH block\n"; \
	    [ "$$_has_wine" = "true" ] && printf "    • Wine default block\n"; \
	    printf "\n  Remove these entries? [y/N] "; \
	    read -r _ans; \
	    case "$$_ans" in \
	        [yY]|[yY][eE][sS]) \
	            sed -i '\,^$(MARKER_PATH_B)$$,, \,^$(MARKER_PATH_E)$$, d' "$(BASHRC)" 2>/dev/null || true; \
	            sed -i '\,^$(MARKER_WINE_B)$$,, \,^$(MARKER_WINE_E)$$, d' "$(BASHRC)" 2>/dev/null || true; \
	            printf "  \033[1;31m-\033[0m ~/.bashrc: mythix-build entries removed\n"; \
	            printf "    \033[2mRun:  source ~/.bashrc   (or open a new terminal)\033[0m\n\n"; \
	            ;; \
	        *) printf "  \033[2m~/.bashrc: entries left in place\033[0m\n\n" ;; \
	    esac; \
	fi

# ── Python TUI frontend (mythix-build Python app) ─────────────────────────────
# The Python launcher wraps the shell engines with a Textual TUI + Click CLI.
# Shell scripts still do all the actual build work — py-* targets are optional.

py-dev:
	@printf "\033[1;36m── installing Python package (editable) + dev deps\033[0m\n"
	@python3 -m pip install --user --break-system-packages -e ".[dev]"
	@printf "\n  ${C_B}✓  mythix\033[0m is now available. Try: \033[1mmythix doctor\033[0m\n\n"

py-test:
	@python3 -m pytest -q

py-tui:
	@python3 -m mythix_build_system

py-doctor:
	@python3 -m mythix_build_system doctor

py-clean:
	@rm -rf build/ dist/ *.egg-info .pytest_cache/ .ruff_cache/ .mypy_cache/
	@find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	@printf "  \033[1;32m✓\033[0m Python build artefacts cleaned\n"

# ── help ──────────────────────────────────────────────────────────────────────
help:
	@printf "\n\033[1mmythix-build — Wine / Neutron / Proton builders + winetoolz\033[0m\n\n"
	@printf "\033[1mTargets:\033[0m\n"
	@printf "  \033[1;36mmake install\033[0m           Install all sub-projects + add PATH to ~/.bashrc\n"
	@printf "  \033[1;36mmake install-launcher\033[0m  mythix-build launcher only\n"
	@printf "  \033[1;36mmake install-neutron\033[0m         mythix-neutron_builder only\n"
	@printf "  \033[1;36mmake install-proton\033[0m          mythix-proton_builder only\n"
	@printf "  \033[1;36mmake install-neutron-install\033[0m mythix-neutron-install only\n"
	@printf "  \033[1;36mmake install-proton-install\033[0m  mythix-proton-install only\n"
	@printf "  \033[1;36mmake install-wine\033[0m            mythix-wine_builder only\n"
	@printf "  \033[1;36mmake install-hybrid\033[0m          mythix-wine-proton_hybrid_builder only\n"
	@printf "  \033[1;36mmake install-neutron-hybrid\033[0m  mythix-wine-neutron_hybrid_builder only\n"
	@printf "  \033[1;36mmake install-toolz\033[0m           mythix-winetoolz only\n"
	@printf "  \033[1;36mmake uninstall\033[0m         Remove all installed files (asks about ~/.bashrc)\n"
	@printf "  \033[1;36mmake help\033[0m              Show this message\n"
	@printf "\n\033[1mPython TUI frontend (optional):\033[0m\n"
	@printf "  \033[1;36mmake py-dev\033[0m            pip install -e .[dev] (editable install)\n"
	@printf "  \033[1;36mmake py-test\033[0m           pytest\n"
	@printf "  \033[1;36mmake py-tui\033[0m            open the Textual launcher\n"
	@printf "  \033[1;36mmake py-doctor\033[0m         diagnose discovery of all 9 tools\n"
	@printf "  \033[1;36mmake py-clean\033[0m          wipe Python build artefacts\n"
	@printf "\n\033[1mVariables:\033[0m\n"
	@printf "  PREFIX=<dir>    Install root  (default: $(HOME)/.local)\n"
	@printf "  DESTDIR=<dir>   Staging root  (default: empty)\n"
	@printf "\n\033[1mInstall layout:\033[0m\n"
	@printf "  $(PREFIX)/bin/\n"
	@printf "      neutron-builder  neutron-install  proton-builder  proton-install\n"
	@printf "      wine-builder  wine_toolz  wine-proton_hybrid  wine-neutron_hybrid\n"
	@printf "  $(PREFIX)/lib/mythix-neutron_builder/\n"
	@printf "      *.sh  ntsync.h  deps-neutron-tkg\n"
	@printf "  $(PREFIX)/lib/mythix-neutron_builder/patches/\n"
	@printf "      ← drop .patch/.diff here to apply before proton-wine configure\n"
	@printf "  $(PREFIX)/lib/mythix-wine-proton_hybrid_builder/buildz/\n"
	@printf "      ← hybrid builds install here when using 'local' mode\n"
	@printf "  $(PREFIX)/lib/mythix-wine_builder/\n"
	@printf "      *.sh  deps-tkg\n"
	@printf "  $(PREFIX)/lib/mythix-wine_builder/patches/\n"
	@printf "      ← drop .patch/.diff here to apply before Wine configure\n"
	@printf "  $(PREFIX)/lib/mythix-winetoolz/modules/shared_lib/\n"
	@printf "  $(HOME)/.config/mythix-build/    ← cfg files (never overwritten)\n"
	@printf "\n\033[1mRuntime dirs (created by scripts on first run):\033[0m\n"
	@printf "  <data-dir>/buildz/install/       ← finished Wine / Proton installs\n"
	@printf "  <data-dir>/buildz/build-run/     ← in-progress build trees\n"
	@printf "  <data-dir>/src/                  ← git-cloned sources\n"
	@printf "  (data-dir defaults to the lib dir; override with --dest / --src-dir)\n"
	@printf "\n\033[1mQuick start:\033[0m\n"
	@printf "  mythix-build                     # launch the main menu\n"
	@printf "  neutron-builder                  # build Neutron interactively\n"
	@printf "  proton-builder                   # build Proton interactively\n"
	@printf "  wine-builder                    # build Wine interactively\n"
	@printf "  wine_toolz                      # open winetoolz\n"
	@printf "  wine-proton_hybrid              # Proton hybrid installer\n"
	@printf "  wine-neutron_hybrid             # Neutron hybrid installer\n\n"
	@printf "\033[1m~/.bashrc management:\033[0m\n"
	@printf "  make install   adds a PATH block so mythix-build commands are available.\n"
	@printf "  wine-builder   offers to set a completed build as your default Wine\n"
	@printf "                 (adds PATH + WINEPREFIX + WINESERVER exports).\n"
	@printf "  make uninstall asks whether to remove both blocks.\n"
	@printf "  Both blocks are skipped when DESTDIR is set (packaging mode).\n\n"
