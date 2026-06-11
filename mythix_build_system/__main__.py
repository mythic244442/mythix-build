"""Allow ``python -m mythix_build_system`` as an alternate entry point."""

from __future__ import annotations

from mythix_build_system.cli import main

if __name__ == "__main__":
    main()
